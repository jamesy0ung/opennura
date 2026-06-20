import Foundation

struct AuthCallResult {
    var statusCode: Int
    var isSuccess: Bool
    var decodedBody: [String: Any?]?
    var accessToken: String?
    var clientKey: String?
    var authUid: String?
    var expiryUnixSeconds: Int64?
}

actor NuraAuthApiClient {
    private let session = URLSession.shared
    private static let primaryApiBase = "https://api-p3.nuraphone.com/"
    private static let legacyApiBase = "https://api-p1.nuraphone.com/"

    func sendLoginEmail(state: NuraAuthConfig, uuid: String, email: String) async throws -> AuthCallResult {
        let payload: [String: Any?] = [
            "email": email,
            "emailAddress": email,
            "uuid": uuid,
        ]
        return try await send(apiBase: Self.primaryApiBase, endpoint: "auth/login_via_email", authenticated: false, authConfig: state, payload: payload)
    }

    func verifyCode(state: NuraAuthConfig, uuid: String, email: String, code: String, appSessionId: Int? = nil) async throws -> AuthCallResult {
        var payload: [String: Any?] = [
            "email": email,
            "emailAddress": email,
            "token": code,
            "code": code,
            "oneTimeCode": code,
            "uuid": uuid,
        ]
        if let asid = appSessionId {
            payload["asid"] = asid
            payload["app_session_id"] = asid
            payload["appSessionId"] = asid
        }
        return try await send(apiBase: Self.primaryApiBase, endpoint: "auth/login_via_email_verify", authenticated: false, authConfig: state, payload: payload)
    }

    func validateToken(state: NuraAuthConfig) async throws -> AuthCallResult {
        return try await send(apiBase: Self.primaryApiBase, endpoint: "auth/validate_token", authenticated: true, authConfig: state, payload: nil)
    }

    func sessionStart(state: NuraAuthConfig, serial: Int, firmwareVersion: Int, maxPacketLength: Int, userSessionId: Int) async throws -> AuthCallResult {
        let payload: [String: Any?] = [
            "serial": serial,
            "firmware_version": firmwareVersion,
            "max_packet_length": maxPacketLength,
            "usid": userSessionId,
        ]
        let result = try await send(apiBase: Self.primaryApiBase, endpoint: "end_to_end/session/start", authenticated: true, authConfig: state, payload: payload)
        if result.statusCode == 404 {
            return try await send(apiBase: Self.legacyApiBase, endpoint: "end_to_end/session/start", authenticated: true, authConfig: state, payload: payload)
        }
        return result
    }

    func callAuthenticatedEndpoint(state: NuraAuthConfig, endpoint: String, payload: [String: Any?]?) async throws -> AuthCallResult {
        return try await send(apiBase: Self.primaryApiBase, endpoint: endpoint, authenticated: true, authConfig: state, payload: payload)
    }

    // MARK: - Internal

    private func send(
        apiBase: String,
        endpoint: String,
        authenticated: Bool,
        authConfig: NuraAuthConfig,
        payload: [String: Any?]?
    ) async throws -> AuthCallResult {
        let url = URL(string: apiBase)!.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/msgpack", forHTTPHeaderField: "Accept")

        if authenticated {
            request.setValue(authConfig.accessToken ?? "", forHTTPHeaderField: "access-token")
            request.setValue(authConfig.clientKey ?? "", forHTTPHeaderField: "client")
            request.setValue(authConfig.authUid ?? "", forHTTPHeaderField: "uid")
            request.setValue("Bearer", forHTTPHeaderField: "token-type")
        }

        if let payload, !payload.isEmpty {
            let msgpackData = MessagePackLite.serializeMap(payload)
            let boundary = UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"msgpack\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/msgpack\r\n\r\n".data(using: .utf8)!)
            body.append(msgpackData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            request.httpBody = body
        } else {
            request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data()
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        var decodedBody: [String: Any?]?
        if !data.isEmpty,
           httpResponse.value(forHTTPHeaderField: "Content-Type")?.contains("msgpack") == true {
            decodedBody = MessagePackLite.deserialize(data) as? [String: Any?]
        }

        let rotatedAccessToken = httpResponse.value(forHTTPHeaderField: "access-token")
        let rotatedClient = httpResponse.value(forHTTPHeaderField: "client")
        let rotatedUid = httpResponse.value(forHTTPHeaderField: "uid")
        let rotatedExpiry = httpResponse.value(forHTTPHeaderField: "expiry")

        return AuthCallResult(
            statusCode: httpResponse.statusCode,
            isSuccess: (200..<300).contains(httpResponse.statusCode),
            decodedBody: decodedBody,
            accessToken: rotatedAccessToken,
            clientKey: rotatedClient,
            authUid: rotatedUid,
            expiryUnixSeconds: rotatedExpiry.flatMap { Int64($0) }
        )
    }
}
