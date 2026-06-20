import Combine
import Foundation

@MainActor
final class NuraDeviceManager: NSObject, ObservableObject {

    @Published var phase: ConnectionPhase = .idle
    @Published var logs: [String] = []
    @Published var transportType: TransportType

    let state = NuraDeviceState()

    private var transport: NuraTransport
    private var nuraKey: [UInt8] = defaultNuraKey
    private var session: NuraSession?
    private var gaiaCommandBusy = false

    init(transportType: TransportType = .ble) {
        self.transportType = transportType
        #if os(macOS)
        if transportType == .classic {
            self.transport = ClassicBTTransport()
        } else {
            self.transport = BLETransport()
        }
        #else
        self.transport = BLETransport()
        #endif
        super.init()
        self.transport.delegate = self
    }

    func switchTransport(to type: TransportType) {
        guard type != transportType else { return }
        disconnect()
        transportType = type
        #if os(macOS)
        if type == .classic {
            transport = ClassicBTTransport()
        } else {
            transport = BLETransport()
        }
        #else
        transport = BLETransport()
        #endif
        transport.delegate = self
    }

    // MARK: - Connection

    func connect() {
        guard phase.isIdle else { return }
        session = nil
        gaiaCommandBusy = false
        state.reset()
        phase = .scanning
        addLog("Scanning for nuraphone...")
        transport.scan()
    }

    func disconnect() {
        transport.stopScan()
        transport.disconnect()
        session = nil
        gaiaCommandBusy = false
        state.reset()
        phase = .idle
        addLog("Disconnected")
    }

    // MARK: - ANC

    func setAncState(anc: Bool, social: Bool) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        addLog("-> SetAncState anc=\(anc ? "ON" : "OFF") social=\(social ? "ON" : "OFF")")
        sendEncrypted(opcode: cmdSetAncState, params: [profileId, anc ? 0x01 : 0x00, social ? 0x01 : 0x00]) { [weak self] result in
            switch result {
            case .success:
                self?.state.anc = NuraAncState(ancEnabled: anc, passthroughEnabled: social)
                self?.addLog("<- ANC \(anc ? "ON" : "OFF"), Social \(social ? "ON" : "OFF")")
            case .failure(let e):
                self?.addLog("<- SetAncState error: \(e.localizedDescription)")
            }
        }
    }

    func setAncEnabled(_ enabled: Bool) {
        setAncState(anc: enabled, social: state.passthroughEnabled)
    }

    func setSocialMode(_ enabled: Bool) {
        setAncState(anc: state.ancEnabled, social: enabled)
    }

    func setAncLevel(_ level: Int) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        addLog("-> SetAncLevel \(level)")
        sendEncrypted(opcode: cmdSetAncLevel, params: [profileId, UInt8(level)]) { [weak self] result in
            switch result {
            case .success:
                self?.state.ancLevel = level
                self?.addLog("<- ANC level set to \(level)")
            case .failure(let e):
                self?.addLog("<- SetAncLevel error: \(e.localizedDescription)")
            }
        }
    }

    func setGlobalAncEnabled(_ enabled: Bool) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdSetGlobalAncEnabled, params: [profileId, enabled ? 0x01 : 0x00]) { [weak self] result in
            if case .success = result { self?.state.globalAncEnabled = enabled }
        }
    }

    // MARK: - Immersion

    func setImmersion(_ level: Int) {
        guard phase.isReady else {
            addLog("Not ready")
            return
        }
        addLog("-> SetKickitParams level \(level)")
        sendEncrypted(
            opcode: cmdSetKickitParams,
            params: kickitParams(for: level)
        ) { [weak self] result in
            switch result {
            case .success:
                self?.state.immersionLevel = level
                self?.addLog("<- Immersion set to \(level)")
            case .failure(let e):
                self?.addLog("<- SetKickitParams error: \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Sound mode

    func setSoundMode(_ mode: NuraPersonalisationMode) {
        guard phase.isReady else { return }
        addLog("-> SetPersonalisedMode \(mode.rawValue)")
        sendEncrypted(opcode: cmdSetPersonalisedMode, params: [mode.byte]) { [weak self] result in
            switch result {
            case .success:
                self?.state.personalisationMode = mode
                self?.addLog("<- Sound mode \(mode.rawValue)")
            case .failure(let e):
                self?.addLog("<- SetPersonalisedMode error: \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Spatial

    func setSpatialEnabled(_ enabled: Bool) {
        guard phase.isReady else { return }
        sendEncrypted(opcode: cmdSetSpatialState, params: [enabled ? 0x01 : 0x00]) { [weak self] result in
            if case .success = result { self?.state.spatialEnabled = enabled }
        }
    }

    // MARK: - Profiles

    func selectProfile(_ profileId: Int) {
        guard phase.isReady else { return }
        addLog("-> SelectProfile \(profileId)")
        sendEncrypted(opcode: cmdSelectProfile, params: [UInt8(profileId)]) { [weak self] result in
            switch result {
            case .success:
                self?.state.profileId = profileId
                self?.addLog("<- Profile selected: \(profileId)")
            case .failure(let e):
                self?.addLog("<- SelectProfile error: \(e.localizedDescription)")
            }
        }
    }

    // MARK: - Battery

    func refreshBattery() {
        guard phase.isReady else { return }
        sendEncrypted(opcode: cmdGetBatteryStatus, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let battery = NuraResponseParsers.decodeBatteryStatus(pt) {
                self?.state.battery = battery
                self?.addLog("<- Battery: \(battery.batteryPercentage)%")
            }
        }
    }

    // MARK: - Button configuration

    func setButtonConfiguration(_ config: NuraButtonConfiguration) {
        guard phase.isReady else { return }
        let bytes = config.toBytes(supportsDoubleTap: true, supportsTripleTap: false)
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdSetButtonConfigV1, params: [profileId] + bytes) { [weak self] result in
            if case .success = result { self?.state.buttons = config }
        }
    }

    // MARK: - Dial configuration

    func setDialConfiguration(_ config: NuraDialConfiguration) {
        guard phase.isReady else { return }
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdSetDialConfig, params: [profileId] + config.toBytes()) { [weak self] result in
            if case .success = result { self?.state.dial = config }
        }
    }

    // MARK: - Logging

    func addLog(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(ts)] \(msg)")
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    // MARK: - GAIA frame send

    private func sendGaiaFrame(
        cmd: UInt16,
        payload: [UInt8],
        expectedAck: UInt16,
        minResponseLen: Int = 0,
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        let frame = GaiaFrame(commandId: cmd, payload: payload)
        transport.sendFrame(frame, expectedAck: expectedAck, minResponseLen: minResponseLen, completion: completion)
    }

    // MARK: - Encrypted command

    private func sendEncrypted(
        opcode: UInt16,
        params: [UInt8],
        completion: @escaping (Result<[UInt8], Error>) -> Void
    ) {
        guard let session else {
            completion(.failure(NuraError.notReady))
            return
        }
        guard !gaiaCommandBusy else {
            completion(.failure(NuraError.busy))
            return
        }
        gaiaCommandBusy = true

        var plain: [UInt8] = [UInt8((opcode >> 8) & 0xFF), UInt8(opcode & 0xFF)]
        plain += params
        let (tag, ct) = session.encryptAppToDev(plain)

        addLog(String(format: "  enc opcode=0x%04x ctr=%d", opcode, session.encCtr - 1))

        sendGaiaFrame(
            cmd: cmdEncryptedCommand,
            payload: tag + ct,
            expectedAck: cmdEncryptedResponse | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            self.gaiaCommandBusy = false
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let payload):
                guard !payload.isEmpty else {
                    completion(.failure(NuraError.malformed("empty encrypted response")))
                    return
                }
                let status = Int(payload[0])
                guard status == 0 else {
                    completion(.failure(NuraError.status(String(format: "0x%04x", opcode), status)))
                    return
                }
                let body = Array(payload[1...])
                do {
                    let raw = try session.decryptDevToApp(body)
                    let pt = raw.count > 1 ? Array(raw[1...]) : []
                    self.addLog(String(format: "  dec opcode=0x%04x plain=%@", opcode, hexStr(Data(pt))))
                    completion(.success(pt))
                } catch {
                    completion(.failure(NuraError.crypto("tag mismatch decrypting response")))
                }
            }
        }
    }

    // MARK: - Connection & GAIA sequence

    private func runGaiaSequence() {
        addLog("GAIA: GetDeviceInfo (0x0001)")
        sendGaiaFrame(
            cmd: cmdGetDeviceInfo,
            payload: [],
            expectedAck: cmdGetDeviceInfo | gaiaAckBit
        ) { [weak self] result in
            if case .success(let p) = result {
                self?.addLog("  device info: \(hexStr(Data(p)))")
                if let info = NuraResponseParsers.decodeDeviceInfo(p) {
                    self?.state.deviceInfo = info
                    self?.addLog("  serial=\(info.serialNumber) fw=\(info.firmwareVersion)")
                }
            }
            self?.runHandshake()
        }
    }

    private func runHandshake() {
        phase = .handshaking
        addLog("GAIA: CryptoAppGenerateChallenge (0x0002)")
        sendGaiaFrame(
            cmd: cmdCryptoGenerateChallenge,
            payload: [],
            expectedAck: cmdCryptoGenerateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog("Handshake step 1 failed: \(e.localizedDescription)")
                self.phase = .failed("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoGenerateChallenge status=\(s)")
                    self.phase = .failed("Handshake status \(s)")
                    return
                }
                let challenge = Array(payload[1..<17])
                self.addLog("  challenge=\(hexStr(Data(challenge)))")
                self.continueHandshake(challenge: challenge)
            }
        }
    }

    private func continueHandshake(challenge: [UInt8]) {
        var nonce = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { nonce[i] = UInt8.random(in: 0...255) }
        addLog("  nonce=\(hexStr(Data(nonce)))")

        let j0App = makeJ0(nonce: nonce, counter: 1, deviceToApp: false)
        let (_, appGmac) = gcmWithJ0(key: nuraKey, j0: j0App, aad: challenge, plaintext: [])
        addLog("  app GMAC=\(hexStr(Data(appGmac)))")

        sendGaiaFrame(
            cmd: cmdCryptoValidateChallenge,
            payload: nonce + appGmac,
            expectedAck: cmdCryptoValidateChallenge | gaiaAckBit,
            minResponseLen: 17
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.addLog("Handshake step 2 failed: \(e.localizedDescription)")
                self.phase = .failed("Handshake failed")
            case .success(let payload):
                guard payload.count >= 17, payload[0] == 0 else {
                    let s = payload.first.map { Int($0) } ?? -1
                    self.addLog("CryptoValidate status=\(s)")
                    self.phase = .failed("Handshake status \(s)")
                    return
                }
                let devGmac = Array(payload[1..<17])
                self.addLog("  device GMAC=\(hexStr(Data(devGmac)))")
                do {
                    let j0Dev = makeJ0(nonce: nonce, counter: 1, deviceToApp: true)
                    _ = try gcmOpenJ0(key: self.nuraKey, j0: j0Dev, aad: kyleAAD, ciphertext: [], tag: devGmac)
                    self.addLog("  Device GMAC verified - session established")
                    self.session = NuraSession(key: self.nuraKey, nonce: nonce)
                    self.runStartupSequence()
                } catch {
                    self.addLog("  Device GMAC mismatch - wrong key?")
                    self.phase = .failed("Crypto: wrong key")
                }
            }
        }
    }

    // MARK: - Startup sequence (matches NuraLib's CreateSafeStartupReads)

    private func runStartupSequence() {
        addLog("Reading initial state...")
        readCurrentProfileId { [weak self] in
            self?.readProfileNames {
                self?.readAncState {
                    self?.readKickitParams {
                        self?.readBattery {
                            self?.readKickitEnabled {
                                self?.phase = .ready
                                self?.addLog("Ready")
                            }
                        }
                    }
                }
            }
        }
    }

    private func readCurrentProfileId(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetCurrentProfileId, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let id = NuraResponseParsers.decodeCurrentProfileId(pt) {
                self?.state.profileId = id
                self?.addLog("  profile = \(id)")
            }
            next()
        }
    }

    private func readProfileNames(then next: @escaping () -> Void) {
        readProfileName(id: 0) { [weak self] in
            self?.readProfileName(id: 1) {
                self?.readProfileName(id: 2) {
                    next()
                }
            }
        }
    }

    private func readProfileName(id: Int, then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetProfileName, params: [UInt8(id)]) { [weak self] result in
            if case .success(let pt) = result,
               let name = NuraResponseParsers.decodeProfileName(pt) {
                self?.state.profileNames[id] = name
                self?.addLog("  profile[\(id)] = \"\(name)\"")
            }
            next()
        }
    }

    private func readAncState(then next: @escaping () -> Void) {
        let profileId = UInt8(state.profileId ?? 0)
        sendEncrypted(opcode: cmdGetAncState, params: [profileId]) { [weak self] result in
            if case .success(let pt) = result,
               let ancState = NuraResponseParsers.decodeAncState(pt) {
                self?.state.anc = ancState
                self?.addLog("  ANC=\(ancState.ancEnabled ? "ON" : "OFF") social=\(ancState.passthroughEnabled ? "ON" : "OFF")")
            }
            next()
        }
    }

    private func readKickitParams(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetKickitParams, params: [UInt8(state.profileId ?? 0)]) { [weak self] result in
            if case .success(let pt) = result,
               let params = NuraResponseParsers.decodeClassicKickitParams(pt),
               let level = params.immersionLevel {
                self?.state.immersionLevel = level.rawValue
                self?.addLog("  immersion = \(level.rawValue)")
            }
            next()
        }
    }

    private func readBattery(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetBatteryStatus, params: []) { [weak self] result in
            if case .success(let pt) = result,
               let battery = NuraResponseParsers.decodeBatteryStatus(pt) {
                self?.state.battery = battery
                self?.addLog("  battery = \(battery.batteryPercentage)%\(battery.isCharging ? " (charging)" : "")")
            }
            next()
        }
    }

    private func readKickitEnabled(then next: @escaping () -> Void) {
        sendEncrypted(opcode: cmdGetKickitEnabled, params: [UInt8(state.profileId ?? 0)]) { [weak self] result in
            if case .success(let pt) = result,
               let enabled = NuraResponseParsers.decodeBooleanFlag(pt) {
                self?.state.kickitEnabled = enabled
                self?.addLog("  kickit enabled = \(enabled)")
            }
            next()
        }
    }
}

// MARK: - NuraTransportDelegate

extension NuraDeviceManager: NuraTransportDelegate {
    func transportDidUpdatePhase(_ newPhase: ConnectionPhase) {
        switch newPhase {
        case .handshaking:
            phase = .handshaking
            runGaiaSequence()
        case .failed(let msg):
            session = nil
            gaiaCommandBusy = false
            phase = .failed(msg)
        case .connecting:
            phase = .connecting
        case .discovering:
            phase = .discovering
        case .scanning:
            phase = .scanning
        case .idle:
            if phase != .idle {
                session = nil
                gaiaCommandBusy = false
                phase = .idle
            }
        case .ready:
            break
        }
    }

    func transportDidReceiveIndication(_ response: GaiaResponse) {
        if let indication = HeadsetIndicationParser.parse(response) {
            handleIndication(indication)
        }

        var logLine = String(
            format: "<- event 0x%04x payload=%@",
            response.rawCommandId, hexStr(Data(response.payload))
        )
        if let desc = gaiaEventDescription(response.payload) { logLine += "  [\(desc)]" }
        addLog(logLine)
    }

    func transportDidLog(_ message: String) {
        addLog(message)
    }

    private func handleIndication(_ indication: HeadsetIndication) {
        switch indication.identifier {
        case .ancParametersChanged:
            let ancState = HeadsetIndicationParser.decodeNuraphoneAncState(indication.value)
            state.anc = ancState
        case .ancLevelChanged:
            state.ancLevel = Int(indication.value)
        case .currentProfileChanged:
            state.profileId = Int(indication.value)
        case .kickitEnabledChanged:
            state.personalisationMode = indication.value != 0 ? .personalised : .neutral
        case .kickitLevelChanged:
            state.immersionLevel = Int(indication.value)
        default:
            break
        }
    }
}
