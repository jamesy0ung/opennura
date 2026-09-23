import Combine
import Foundation

/// Drives backend-assisted provisioning to recover a nuraphone's long-lived
/// per-device key (app_enc.key) and persist it into the device config.
///
/// The flow mirrors NuraLib (Windows):
///   app/session -> auth/login_via_email(+verify) -> auth/validate_token
///   -> end_to_end/session/start -> relay GAIA packets over Bluetooth
///   -> end_to_end/session/start_1..N -> app_enc.key
///
/// The Bluetooth relay itself is provided by the caller as an async closure so
/// this type stays independent of the transport.
@MainActor
final class NuraProvisioningManager: ObservableObject {
    
    enum AuthStep: Equatable {
        case loggedOut
        case codeSent(email: String)
        case loggedIn(email: String)
    }
    
    enum ProvisioningError: LocalizedError {
        case notAuthenticated
        case missingUserSession
        case malformedSessionStart
        case missingSessionId
        case noDeviceKeyReturned
        case backend(String)
        
        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in to a Nura account."
            case .missingUserSession: return "Backend did not return a user session id."
            case .malformedSessionStart: return "Backend session-start response was not understood."
            case .missingSessionId: return "Backend session-start response had no session id."
            case .noDeviceKeyReturned: return "Provisioning finished without returning a device key."
            case .backend(let s): return s
            }
        }
    }
    
    /// A minimal view of a GAIA response, enough to package relay results.
    struct RelayResponse {
        let vendorId: UInt16
        let rawCommandId: UInt16
        let payload: [UInt8]
    }
    
    typealias FrameSender = (UInt16, [UInt8]) async throws -> RelayResponse
    
    @Published private(set) var authStep: AuthStep = .loggedOut
    @Published var status: String = ""
    @Published var isBusy = false
    
    private let api = NuraApiClient()
    private let configStore: NuraConfigStore
    private var config: NuraConfig
    
    // Ephemeral session runtime (not persisted).
    private var appSessionId: Int?
    private var userSessionId: Int?
    private var appEncKey: String?
    
    init() {
        let configStore = NuraConfigStore()
        self.configStore = configStore
        var loaded = configStore.load()
        _ = loaded.ensureUuid()
        self.config = loaded
        configStore.save(loaded) // persist uuid if newly generated
        if let auth = loaded.auth, auth.hasAuthenticatedSession, let email = auth.userEmail {
            authStep = .loggedIn(email: email)
        }
    }
    
    var isLoggedIn: Bool {
        if case .loggedIn = authStep { return true }
        return false
    }
    
    var userEmail: String? { config.auth?.userEmail }
    
    // MARK: - Auth
    
    func requestEmailCode(_ email: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true; status = "Sending code..."
        defer { isBusy = false }
        do {
            let result = try await api.sendLoginEmail(apiState(), email: trimmed)
            try checkSuccess(result, context: "Requesting login code")
            var auth = config.auth ?? NuraAuthConfig()
            auth.userEmail = trimmed
            config.auth = auth
            persistTokens(from: result)
            save()
            authStep = .codeSent(email: trimmed)
            status = "Code sent to \(trimmed)"
        } catch {
            status = "Error: \(error.localizedDescription)"
            throw error
        }
    }
    
    func verifyEmailCode(_ code: String) async throws {
        let email: String
        switch authStep {
        case .codeSent(let e): email = e
        case .loggedIn(let e): email = e
        default: email = config.auth?.userEmail ?? ""
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !email.isEmpty else { return }
        isBusy = true; status = "Verifying code..."
        defer { isBusy = false }
        do {
            try await ensureAppSession()
            let result = try await api.verifyCode(apiState(), email: email, code: trimmed)
            try checkSuccess(result, context: "Verifying login code")
            persistTokens(from: result, fallbackAuthUid: email)
            applyRuntime(result.decodedBody)
            save()
            authStep = .loggedIn(email: email)
            status = "Signed in as \(email)"
        } catch {
            status = "Error: \(error.localizedDescription)"
            throw error
        }
    }
    
    func logout() {
        var auth = NuraAuthConfig()
        auth.userEmail = config.auth?.userEmail
        config.auth = auth
        appSessionId = nil
        userSessionId = nil
        appEncKey = nil
        save()
        if let email = auth.userEmail {
            authStep = .codeSent(email: email) // let them re-enter a fresh code
        } else {
            authStep = .loggedOut
        }
        status = "Signed out"
    }
    
    // MARK: - Provisioning
    
    /// Runs the full recovery and returns the base64 device key (also saved to config).
    @discardableResult
    func recoverDeviceKey(
        serial: Int,
        firmwareVersion: Int,
        maxPacketLength: Int,
        sendFrame: FrameSender
    ) async throws -> String {
        isBusy = true
        defer { isBusy = false }
        appEncKey = nil
        
        guard config.auth?.hasAuthenticatedSession == true else {
            throw ProvisioningError.notAuthenticated
        }
        
        status = "Preparing session..."
        let usid = try await ensureProvisioningReady()
        
        status = "Requesting session/start..."
        let startResult = try await api.sessionStart(
            apiState(),
            serial: serial,
            firmwareVersion: firmwareVersion,
            maxPacketLength: maxPacketLength,
            userSessionId: usid
        )
        try checkSuccess(startResult, context: "session/start")
        persistTokens(from: startResult)
        applyRuntime(startResult.decodedBody)
        
        guard var details = NuraSessionStartResponseParser.parse(startResult.decodedBody ?? [:]) else {
            throw ProvisioningError.malformedSessionStart
        }
        guard var sessionId = details.sessionId else {
            throw ProvisioningError.missingSessionId
        }
        
        while true {
            if let fe = details.finalEvent { status = "Relaying \(fe)..." } else { status = "Relaying packets..." }
            let packets = try await executeLocalActions(details, sendFrame: sendFrame)
            
            guard let finalEvent = details.finalEvent, !finalEvent.isEmpty else { break }
            
            status = "Continuing \(finalEvent)..."
            let cont = try await api.automatedEntry(
                apiState(),
                endpoint: finalEvent,
                sessionId: sessionId,
                packets: packets
            )
            try checkSuccess(cont, context: finalEvent)
            persistTokens(from: cont)
            applyRuntime(cont.decodedBody)
            
            guard let next = NuraSessionStartResponseParser.parse(cont.decodedBody ?? [:]) else { break }
            details = next
            sessionId = next.sessionId ?? sessionId
        }
        
        // Persist rotated auth tokens once, now that the run succeeded.
        save()
        
        guard let key = appEncKey,
              let data = Data(base64Encoded: key), data.count == 16 else {
            throw ProvisioningError.noDeviceKeyReturned
        }
        status = "Device key recovered."
        return key
    }
    
    // MARK: - Relay of local (Bluetooth) actions
    
    private func executeLocalActions(
        _ details: NuraSessionStartDetails,
        sendFrame: FrameSender
    ) async throws -> [[String: Any?]] {
        var out: [[String: Any?]] = []
        
        // Type "u": server-issued frames relayed verbatim.
        for packet in details.packets {
            guard let bytes = packet.payloadBytes, !bytes.isEmpty,
                  let (cmd, payload) = decodeBootstrapFrame(bytes) else { continue }
            let response = try await sendFrame(cmd, payload)
            out.append([
                "e": false,
                "a": false,
                "b": relayResponseData(response),
                "m": false,
            ])
        }
        
        // Type "r": server-encrypted GAIA run packets.
        for packet in details.runPackets {
            guard let bytes = packet.payloadBytes, !bytes.isEmpty else { continue }
            let cmd = Self.runCommandId(flagA: packet.flagA, flagM: packet.flagM)
            let response = try await sendFrame(cmd, bytes)
            let masked = response.rawCommandId & 0x1FFF
            let payloadExcludingStatus = response.payload.count <= 1 ? [] : Array(response.payload[1...])
            out.append([
                "e": true,
                "a": Self.authenticatedResponseCommandIds.contains(masked),
                "b": payloadExcludingStatus,
                "m": Self.bulkResponseCommandIds.contains(masked),
            ])
        }
        
        return out
    }
    
    /// Reconstructs vendor(2)+rawCommandId(2)+payload, matching NuraLib's GaiaResponse.Data.
    private func relayResponseData(_ response: RelayResponse) -> [UInt8] {
        var data: [UInt8] = [
            UInt8((response.vendorId >> 8) & 0xFF), UInt8(response.vendorId & 0xFF),
            UInt8((response.rawCommandId >> 8) & 0xFF), UInt8(response.rawCommandId & 0xFF),
        ]
        data += response.payload
        return data
    }
    
    /// Converts a bootstrap packet (either a full 0xFF GAIA frame or bare
    /// vendor+command+payload) into a (commandId, payload) pair for BLE.
    private func decodeBootstrapFrame(_ bytes: [UInt8]) -> (UInt16, [UInt8])? {
        if bytes.count >= 8, bytes[0] == 0xFF {
            let flags = bytes[2]
            let usesLengthExtension = (flags & 0x02) != 0
            let commandOffset = usesLengthExtension ? 7 : 6
            let payloadOffset = usesLengthExtension ? 9 : 8
            guard bytes.count >= payloadOffset else { return nil }
            let cmd = (UInt16(bytes[commandOffset]) << 8) | UInt16(bytes[commandOffset + 1])
            let payload = bytes.count > payloadOffset ? Array(bytes[payloadOffset...]) : []
            return (cmd, payload)
        }
        guard bytes.count >= 4 else { return nil }
        let vendor = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard vendor == gaiaVendor else { return nil }
        let cmd = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
        let payload = bytes.count > 4 ? Array(bytes[4...]) : []
        return (cmd, payload)
    }
    
    private static func runCommandId(flagA: Bool, flagM: Bool) -> UInt16 {
        switch (flagA, flagM) {
        case (false, false): return 0x0009
        case (false, true): return 0x1009
        case (true, false): return 0x0008
        case (true, true): return 0x1008
        }
    }
    
    private static let authenticatedResponseCommandIds: Set<UInt16> = [
        0x0006, 0x1006, 0x000A, 0x100A, 0x0013, 0x1013,
        0x0008, 0x1008, 0x000F, 0x100F, 0x000C, 0x100C,
    ]
    
    private static let bulkResponseCommandIds: Set<UInt16> = [
        0x1006, 0x100A, 0x1013, 0x1007, 0x100B, 0x1014,
        0x1008, 0x100F, 0x100C, 0x1009, 0x1010, 0x100D,
    ]
    
    // MARK: - Session bootstrap
    
    private func ensureAppSession() async throws {
        if appSessionId != nil { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let result = try await api.appSession(apiState(), appStartTimeUnixMs: nowMs)
        try checkSuccess(result, context: "app/session")
        applyRuntime(result.decodedBody)
    }
    
    private func ensureProvisioningReady() async throws -> Int {
        try await ensureAppSession()
        let result = try await api.validateToken(apiState())
        try checkSuccess(result, context: "validate_token")
        persistTokens(from: result)
        applyRuntime(result.decodedBody)
        save()
        guard let usid = userSessionId else {
            throw ProvisioningError.missingUserSession
        }
        return usid
    }
    
    // MARK: - State plumbing
    
    private func apiState() -> NuraApiState {
        NuraApiState(
            apiBase: config.resolvedApiBase,
            uuid: config.uuid ?? config.ensureUuid(),
            accessToken: config.auth?.accessToken,
            clientKey: config.auth?.clientKey,
            authUid: config.auth?.authUid,
            appSessionId: appSessionId
        )
    }
    
    private func applyRuntime(_ body: [String: Any?]?) {
        let snap = NuraAuthResponseParser.extract(body)
        if let v = snap.appSessionId { appSessionId = v }
        if let v = snap.userSessionId { userSessionId = v }
        if let v = snap.appEncKey, !v.isEmpty { appEncKey = v }
    }
    
    private func persistTokens(from result: AuthCallResult, fallbackAuthUid: String? = nil) {
        var auth = config.auth ?? NuraAuthConfig()
        if let t = result.accessToken, !t.isEmpty { auth.accessToken = t }
        if let c = result.clientKey, !c.isEmpty { auth.clientKey = c }
        if let u = result.authUid, !u.isEmpty { auth.authUid = u }
        else if let fb = fallbackAuthUid, auth.authUid == nil { auth.authUid = fb }
        if let e = result.expiryUnixSeconds { auth.tokenExpiryUnix = e }
        config.auth = auth
    }
    
    private func checkSuccess(_ result: AuthCallResult, context: String) throws {
        if result.isSuccess, !backendReportedFailure(result.decodedBody) { return }
        if backendReportedFailure(result.decodedBody) {
            throw ProvisioningError.backend("\(context) rejected by backend.")
        }
        throw ProvisioningError.backend("\(context) failed (HTTP \(result.statusCode)).")
    }
    
    private func backendReportedFailure(_ body: [String: Any?]?) -> Bool {
        guard let body else { return false }
        if let success = NuraMsg.boolValue(NuraMsg.value(body, "s")) { return !success }
        return false
    }
    
    private func save() {
        configStore.save(config)
    }
    
    /// Re-reads devices from disk, updates the key for `serial`, and saves.
    func saveDeviceKey(
        _ base64Key: String,
        serial: Int,
        firmwareVersion: Int,
        maxPacketLength: Int,
        friendlyName: String,
        deviceType: String
    ) {
        var latest = configStore.load()
        _ = latest.ensureUuid()
        latest.auth = config.auth
        latest.apiBase = config.apiBase
        latest.uuid = config.uuid
        
        let serialString = String(serial)
        let isoNow = ISO8601DateFormatter().string(from: Date())
        if var existing = latest.deviceBySerial(serialString) {
            existing.deviceKey = base64Key
            existing.firmwareVersion = firmwareVersion
            existing.maxPacketLengthHint = maxPacketLength
            existing.lastProvisionedUtc = isoNow
            existing.friendlyName = friendlyName
            existing.type = deviceType
            latest.upsertDevice(existing)
        } else {
            let entry = NuraDeviceConfigEntry(
                type: deviceType,
                deviceSerial: serialString,
                friendlyName: friendlyName,
                firmwareVersion: firmwareVersion,
                maxPacketLengthHint: maxPacketLength,
                lastProvisionedUtc: isoNow,
                deviceKey: base64Key
            )
            latest.upsertDevice(entry)
        }
        config = latest
        configStore.save(latest)
    }
}
