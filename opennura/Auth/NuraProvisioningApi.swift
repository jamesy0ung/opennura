import Foundation

/// Immutable snapshot of the fields the API client needs for a single call.
struct NuraApiState {
    var apiBase: String
    var uuid: String
    var accessToken: String?
    var clientKey: String?
    var authUid: String?
    var appSessionId: Int?
}

/// Result of a single backend call, including rotated auth headers.
struct AuthCallResult {
    var statusCode: Int
    var isSuccess: Bool
    var decodedBody: [String: Any?]?
    var accessToken: String?
    var clientKey: String?
    var authUid: String?
    var expiryUnixSeconds: Int64?
}

enum NuraApiError: LocalizedError {
    case transport(String)
    case backend(String, Int)
    
    var errorDescription: String? {
        switch self {
        case .transport(let s): return s
        case .backend(let s, let code): return "\(s) (HTTP \(code))"
        }
    }
}

/// Talks to the Nura backend using the same msgpack-over-multipart protocol
/// the official app uses. Ported from NuraLib's NuraAuthApiClient.
///
/// Isolated to the main actor (matching the module's default isolation); its
/// async methods suspend on the network call without blocking the UI.
final class NuraApiClient {
    private let session = URLSession.shared
    static let primaryApiBase = "https://api-p3.nuraphone.com/"
    static let legacyApiBase = "https://api-p1.nuraphone.com/"
    
    // MARK: - Endpoints
    
    func appSession(_ state: NuraApiState, appStartTimeUnixMs: Int64) async throws -> AuthCallResult {
        let payload = Self.appContextPayload(state, appStartTimeUnixMs: appStartTimeUnixMs)
        return try await send(state, endpoint: "app/session", authenticated: false, payload: payload)
    }
    
    func sendLoginEmail(_ state: NuraApiState, email: String) async throws -> AuthCallResult {
        let payload: [String: Any?] = [
            "email": email,
            "emailAddress": email,
            "uuid": state.uuid,
        ]
        return try await send(state, endpoint: "auth/login_via_email", authenticated: false, payload: payload)
    }
    
    func verifyCode(_ state: NuraApiState, email: String, code: String) async throws -> AuthCallResult {
        var payload: [String: Any?] = [
            "email": email,
            "emailAddress": email,
            "token": code,
            "code": code,
            "oneTimeCode": code,
            "uuid": state.uuid,
        ]
        if let asid = state.appSessionId {
            payload["asid"] = asid
            payload["app_session_id"] = asid
            payload["appSessionId"] = asid
        }
        return try await send(state, endpoint: "auth/login_via_email_verify", authenticated: false, payload: payload)
    }
    
    func validateToken(_ state: NuraApiState) async throws -> AuthCallResult {
        var payload: [String: Any?]? = nil
        if let asid = state.appSessionId {
            payload = ["asid": asid]
        }
        return try await send(state, endpoint: "auth/validate_token", authenticated: true, payload: payload)
    }
    
    func sessionStart(
        _ state: NuraApiState,
        serial: Int,
        firmwareVersion: Int,
        maxPacketLength: Int,
        userSessionId: Int
    ) async throws -> AuthCallResult {
        let payload: [String: Any?] = [
            "serial": serial,
            "firmware_version": firmwareVersion,
            "max_packet_length": maxPacketLength,
            "usid": userSessionId,
        ]
        let result = try await send(state, endpoint: "end_to_end/session/start", authenticated: true, payload: payload)
        if result.statusCode == 404, let alt = Self.alternateApiBase(state.apiBase) {
            var altState = state
            altState.apiBase = alt
            return try await send(altState, endpoint: "end_to_end/session/start", authenticated: true, payload: payload)
        }
        return result
    }
    
    func automatedEntry(
        _ state: NuraApiState,
        endpoint rawEndpoint: String,
        sessionId: Int,
        packets: [[String: Any?]]
    ) async throws -> AuthCallResult {
        let endpoint = Self.normalizeAutomatedEndpoint(rawEndpoint)
        var payload: [String: Any?] = ["session": sessionId]
        if !packets.isEmpty {
            payload["packets"] = packets.map { $0 as Any? } as [Any?]
        }
        let result = try await send(state, endpoint: endpoint, authenticated: true, payload: payload)
        if result.statusCode == 404, let alt = Self.alternateApiBase(state.apiBase) {
            var altState = state
            altState.apiBase = alt
            return try await send(altState, endpoint: endpoint, authenticated: true, payload: payload)
        }
        return result
    }
    
    // MARK: - Core request
    
    private func send(
        _ state: NuraApiState,
        endpoint: String,
        authenticated: Bool,
        payload: [String: Any?]?
    ) async throws -> AuthCallResult {
        let base = Self.ensureTrailingSlash(state.apiBase)
        guard let baseURL = URL(string: base),
              let url = URL(string: endpoint, relativeTo: baseURL)
                else {
            throw NuraApiError.transport("Bad URL for \(endpoint)")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/msgpack", forHTTPHeaderField: "Accept")
        
        if authenticated {
            request.setValue(state.accessToken ?? "", forHTTPHeaderField: "access-token")
            request.setValue(state.clientKey ?? "", forHTTPHeaderField: "client")
            request.setValue(state.authUid ?? "", forHTTPHeaderField: "uid")
            request.setValue("Bearer", forHTTPHeaderField: "token-type")
        }
        
        if let payload, !payload.isEmpty {
            let msgpack = MessagePackLite.serializeMap(payload)
            let boundary = "nura-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"msgpack\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/msgpack\r\n\r\n".data(using: .utf8)!)
            body.append(msgpack)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
        } else {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data()
        }
        
        // Retry transient failures (network blips and 5xx) a few times with a
        // short backoff, since recovery is a multi-step exchange and a single
        // hiccup shouldn't fail the whole run.
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError {
                lastError = NuraApiError.transport(Self.friendlyMessage(for: urlError))
                if attempt < maxAttempts, Self.isRetryable(urlError) {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                    continue
                }
                throw lastError!
            } catch {
                throw NuraApiError.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw NuraApiError.transport("No HTTP response")
            }
            
            if (500...599).contains(http.statusCode), attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                continue
            }
            
            var decodedBody: [String: Any?]?
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !data.isEmpty, contentType.lowercased().contains("msgpack") {
                decodedBody = MessagePackLite.deserialize(data) as? [String: Any?]
            }
            
            return AuthCallResult(
                statusCode: http.statusCode,
                isSuccess: (200..<300).contains(http.statusCode),
                decodedBody: decodedBody,
                accessToken: http.value(forHTTPHeaderField: "access-token"),
                clientKey: http.value(forHTTPHeaderField: "client"),
                authUid: http.value(forHTTPHeaderField: "uid"),
                expiryUnixSeconds: http.value(forHTTPHeaderField: "expiry").flatMap { Int64($0) }
            )
        }
        throw lastError ?? NuraApiError.transport("Request failed")
    }
    
    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Helpers
    
    /// Turn low-level networking errors into a message
    private static func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .timedOut, .networkConnectionLost, .resourceUnavailable:
            return "Couldn't reach Nura's servers. They may be offline, or check your internet connection."
        case .notConnectedToInternet:
            return "No internet connection."
        case .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "Secure connection to Nura's servers failed."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }
    
    private static func ensureTrailingSlash(_ base: String) -> String {
        base.hasSuffix("/") ? base : base + "/"
    }
    
    private static func alternateApiBase(_ apiBase: String) -> String? {
        if apiBase.localizedCaseInsensitiveContains("api-p1") { return primaryApiBase }
        if apiBase.localizedCaseInsensitiveContains("api-p3") { return legacyApiBase }
        return nil
    }
    
    private static func normalizeAutomatedEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.lowercased().hasPrefix("end_to_end/") { return trimmed }
        return "end_to_end/\(trimmed)"
    }
    
    /// The Android app-context payload the backend expects for app/session and
    /// token validation. Copied from NuraLib with permission.
    static func appContextPayload(_ state: NuraApiState, appStartTimeUnixMs: Int64) -> [String: Any?] {
        [
            "uuid": state.uuid,
            "os": 1,
            "os_name": "android",
            "os_version": "14",
            "os_api": 34,
            "app_version": "4.5.4",
            "appVersion": "4.5.4",
            "app_build": 1410,
            "appBuild": 1410,
            "device": "samsung/SM-S918B",
            "device_info": [
                "brand": "samsung",
                "manufacturer": "samsung",
                "model": "SM-S918B",
                "device": "dm3q",
                "product": "dm3qxxx",
                "sdkInt": 34,
                "securityPatch": "2026-03-01",
            ] as [String: Any?],
            "installer": "google_play",
            "lang": "en",
            "action": "app_start_cold",
            "app_session": "app_start_cold",
            "appSession": "app_start_cold",
            "app_start_time": appStartTimeUnixMs,
            "appStartTime": appStartTimeUnixMs,
        ]
    }
}
