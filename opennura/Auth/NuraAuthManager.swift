import Combine
import Foundation

@MainActor
final class NuraAuthManager: ObservableObject {

    enum AuthState: Equatable {
        case loggedOut
        case codeSent(email: String)
        case loggedIn(email: String)
        case error(String)
    }

    @Published var authState: AuthState = .loggedOut
    @Published var isLoading = false

    private let apiClient = NuraAuthApiClient()
    private let configStore: NuraConfigStore
    private(set) var config: NuraConfig

    var isLoggedIn: Bool {
        if case .loggedIn = authState { return true }
        return false
    }

    var userEmail: String? { config.auth.userEmail }

    init(configStore: NuraConfigStore) {
        self.configStore = configStore
        self.config = configStore.load()
        if config.auth.hasAuthenticatedSession, let email = config.auth.userEmail {
            authState = .loggedIn(email: email)
        }
    }

    func requestEmailCode(email: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.sendLoginEmail(state: config.auth, uuid: config.uuid, email: email)
            if result.isSuccess {
                config.auth.userEmail = email
                saveConfig()
                authState = .codeSent(email: email)
            } else {
                authState = .error("Failed to send code (HTTP \(result.statusCode))")
            }
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    func verifyCode(_ code: String) async {
        guard case .codeSent(let email) = authState else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.verifyCode(state: config.auth, uuid: config.uuid, email: email, code: code)
            if result.isSuccess {
                applyTokenRotation(result)
                saveConfig()
                authState = .loggedIn(email: email)
            } else {
                authState = .error("Invalid code (HTTP \(result.statusCode))")
            }
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    func resume() async {
        guard config.auth.hasAuthenticatedSession else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await apiClient.validateToken(state: config.auth)
            if result.isSuccess {
                applyTokenRotation(result)
                saveConfig()
                if let email = config.auth.userEmail {
                    authState = .loggedIn(email: email)
                }
            } else {
                authState = .loggedOut
            }
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    func logout() {
        config.auth = NuraAuthConfig()
        saveConfig()
        authState = .loggedOut
    }

    func deviceKeyForSerial(_ serial: String) -> [UInt8]? {
        config.deviceBySerial(serial)?.getDeviceKeyBytes()
    }

    // MARK: - Internal

    private func applyTokenRotation(_ result: AuthCallResult) {
        if let token = result.accessToken { config.auth.accessToken = token }
        if let client = result.clientKey { config.auth.clientKey = client }
        if let uid = result.authUid { config.auth.authUid = uid }
        if let expiry = result.expiryUnixSeconds { config.auth.tokenExpiryUnix = expiry }
    }

    private func saveConfig() {
        configStore.save(config)
    }
}
