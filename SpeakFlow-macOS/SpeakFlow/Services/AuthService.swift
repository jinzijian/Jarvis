import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AuthService")

enum AuthError: LocalizedError {
    case notLoggedIn
    case invalidCredentials
    case serverError(String)
    case networkError(Error)
    case refreshFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in"
        case .invalidCredentials: return "Invalid email or password"
        case .serverError(let msg): return msg
        case .networkError(let err): return err.localizedDescription
        case .refreshFailed(let err): return "Token refresh failed: \(err?.localizedDescription ?? "unknown")"
        }
    }
}

extension Notification.Name {
    static let authSessionExpired = Notification.Name("authSessionExpired")
}

final class AuthService {
    static let shared = AuthService()
    private let keychain = KeychainService.shared
    private let baseURL = Constants.apiBaseURL
    private let stateLock = NSLock()

    /// Serializes token refresh to prevent concurrent refresh attempts
    /// (Supabase refresh tokens are single-use)
    private var refreshTask: Task<AuthResponse, Error>?
    /// Prevents firing the expired notification more than once per session
    private var didNotifyExpired = false

    private init() {}

    func login(email: String, password: String) async throws -> AuthResponse {
        logger.info("Login attempt for email: \(email)")
        let url = URL(string: "\(baseURL)/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(email: email, password: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.serverError("Invalid server response")
        }

        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            keychain.saveTokens(response: authResponse)
            recordSuccessfulAuthentication()
            logger.info("Login successful")
            return authResponse
        } else {
            let detail = parseError(data: data)
            if httpResponse.statusCode == 401 {
                logger.error("Login failed: invalid credentials")
                throw AuthError.invalidCredentials
            }
            logger.error("Login failed: \(detail)")
            throw AuthError.serverError(detail)
        }
    }

    func refresh() async throws -> AuthResponse {
        // Coalesce concurrent refresh calls into a single request
        // to avoid consuming the single-use refresh token multiple times.
        let task = refreshTaskOrCreate { [self] in
            defer { clearRefreshTask() }
            guard let refreshToken = keychain.refreshToken else {
                throw AuthError.notLoggedIn
            }

            let url = URL(string: "\(baseURL)/auth/refresh")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(RefreshRequest(refresh_token: refreshToken))

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.serverError("Invalid server response")
            }

            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                keychain.saveTokens(response: authResponse)
                recordSuccessfulAuthentication()
                logger.info("Token refreshed successfully")
                return authResponse
            } else if httpResponse.statusCode == 401 {
                // Distinguish permanent vs transient 401
                let bodyString = String(data: data, encoding: .utf8)?.lowercased() ?? ""
                let permanentSignals = ["invalid_grant", "token_revoked", "invalid refresh token", "refresh token not found", "expired refresh token", "invalid or expired"]
                let isPermanent = permanentSignals.contains(where: { bodyString.contains($0) })

                if isPermanent {
                    keychain.deleteAll()
                    notifySessionExpired()
                    logger.error("Permanent refresh failure, logged out")
                    throw AuthError.notLoggedIn
                } else {
                    logger.warning("Transient refresh 401, not logging out")
                    throw AuthError.refreshFailed(underlying: AuthError.serverError("401: \(bodyString.prefix(200))"))
                }
            } else {
                let detail = parseError(data: data)
                throw AuthError.serverError("Token refresh failed: \(detail)")
            }
        }
        return try await task.value
    }

    func getValidToken() async throws -> String {
        // In open-source mode, no auth is required.
        // Return existing token if available, otherwise return a dummy.
        if let accessToken = keychain.accessToken {
            return accessToken
        }
        return "local-no-auth"
    }

    func redeemInviteCode(_ code: String) async throws -> String {
        let token = try await getValidToken()
        let url = URL(string: "\(baseURL)/stripe/redeem")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.serverError("Invalid server response")
        }

        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String {
                return message
            }
            return "Subscription activated!"
        } else {
            let detail = parseError(data: data)
            throw AuthError.serverError(detail)
        }
    }

    func fetchSubscription() async throws -> SubscriptionStatus {
        let token = try await getValidToken()
        let url = URL(string: "\(baseURL)/stripe/subscription")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 200 {
            return try JSONDecoder().decode(SubscriptionStatus.self, from: data)
        }

        // On 401, try refreshing token once and retry
        if statusCode == 401 {
            logger.warning("Subscription endpoint returned 401, retrying after refresh")
            let refreshedResponse = try await refresh()
            var retryRequest = URLRequest(url: url)
            retryRequest.setValue("Bearer \(refreshedResponse.access_token)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard (retryResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw AuthError.serverError(parseError(data: retryData))
            }
            return try JSONDecoder().decode(SubscriptionStatus.self, from: retryData)
        }

        throw AuthError.serverError(parseError(data: data))
    }

    func fetchUsageStats() async throws -> UsageStats {
        let token = try await getValidToken()
        let url = URL(string: "\(baseURL)/usage")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.serverError(parseError(data: data))
        }
        return try JSONDecoder().decode(UsageStats.self, from: data)
    }

    func fetchPortalURL() async throws -> String {
        let token = try await getValidToken()
        let url = URL(string: "\(baseURL)/stripe/portal")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.serverError(parseError(data: data))
        }
        return try JSONDecoder().decode(PortalSession.self, from: data).portal_url
    }

    func createCheckoutSession(plan: String) async throws -> String {
        let token = try await getValidToken()
        let url = URL(string: "\(baseURL)/stripe/checkout")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["plan": plan])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.serverError(parseError(data: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkoutURL = json["checkout_url"] as? String else {
            throw AuthError.serverError("Invalid checkout response")
        }
        return checkoutURL
    }

    func logout() {
        logger.info("Logging out")
        let accessToken = keychain.accessToken
        keychain.deleteAll()
        resetExpiredNotification()

        guard let accessToken else { return }

        Task {
            let url = URL(string: "\(baseURL)/auth/logout")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func notifySessionExpired() {
        guard markSessionExpiredIfNeeded() else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .authSessionExpired, object: nil)
        }
    }

    func recordSuccessfulAuthentication() {
        resetExpiredNotification()
    }

    private func parseError(data: Data) -> String {
        parseAPIError(data: data)
    }

    private func refreshTaskOrCreate(
        operation: @escaping @Sendable () async throws -> AuthResponse
    ) -> Task<AuthResponse, Error> {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let existing = refreshTask {
            return existing
        }

        let task = Task(operation: operation)
        refreshTask = task
        return task
    }

    private func clearRefreshTask() {
        stateLock.lock()
        refreshTask = nil
        stateLock.unlock()
    }

    private func resetExpiredNotification() {
        stateLock.lock()
        didNotifyExpired = false
        stateLock.unlock()
    }

    private func markSessionExpiredIfNeeded() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !didNotifyExpired else { return false }
        didNotifyExpired = true
        return true
    }
}
