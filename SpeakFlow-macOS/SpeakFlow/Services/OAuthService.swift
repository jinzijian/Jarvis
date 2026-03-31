import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "OAuth")

/// Handles Google OAuth by opening the default browser and receiving the
/// callback via the app's registered URL scheme (speakflow-callback://).
final class OAuthService: @unchecked Sendable {
    static let shared = OAuthService()

    private var _onComplete: ((Result<AuthResponse, Error>) -> Void)?
    private let completionLock = NSLock()

    /// Thread-safe access to the completion handler.
    var onComplete: ((Result<AuthResponse, Error>) -> Void)? {
        get { completionLock.withLock { _onComplete } }
        set { completionLock.withLock { _onComplete = newValue } }
    }

    /// Atomically take the completion handler (get and nil it in one operation).
    private func takeCompletion() -> ((Result<AuthResponse, Error>) -> Void)? {
        completionLock.withLock {
            let handler = _onComplete
            _onComplete = nil
            return handler
        }
    }

    private static let callbackScheme = "speakflow-callback"
    private static let redirectURI = "\(callbackScheme)://auth"

    /// Opens the default browser for Google login.
    /// After Google auth, Supabase redirects to the web callback page
    /// (`/auth/callback?source=app`), which exchanges tokens and then
    /// opens the app via the `speakflow-callback://` URL scheme.
    func startGoogleLogin(completion: @escaping (Result<AuthResponse, Error>) -> Void) {
        self.onComplete = completion

        // Redirect to the web callback page with source=app; it handles
        // token exchange and redirects back to the app via URL scheme.
        let webCallback = Constants.apiBaseURL
            .replacingOccurrences(of: "/api/v1", with: "/auth/callback?source=app")
        let redirectEncoded = webCallback.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? webCallback
        let url = URL(string: "\(Constants.apiBaseURL)/auth/google?redirect_to=\(redirectEncoded)")!

        NSWorkspace.shared.open(url)
        logger.info("Opened browser for Google login")
    }

    /// Called by AppDelegate when macOS routes a `speakflow-callback://` URL to the app.
    func handleCallbackURL(_ url: URL) {
        logger.info("Received callback URL")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Try 1: code in query params (PKCE flow) → ?code=XXX
        if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
            logger.info("Found auth code in query params")
            exchangeCode(code)
            return
        }

        // Try 2: tokens/code in fragment (implicit flow) → #access_token=XXX or #code=XXX
        if let fragment = components?.fragment, !fragment.isEmpty {
            logger.info("Found URL fragment")
            let fragmentParams = parseFragment(fragment)

            if let accessToken = fragmentParams["access_token"],
               let refreshToken = fragmentParams["refresh_token"] {
                logger.info("Extracted tokens directly from fragment")
                let expiresIn = Int(fragmentParams["expires_in"] ?? "3600") ?? 3600
                let authResponse = AuthResponse(
                    access_token: accessToken,
                    refresh_token: refreshToken,
                    token_type: "bearer",
                    expires_in: expiresIn,
                    user: UserResponse(id: "", email: fragmentParams["email"] ?? "", created_at: nil)
                )
                KeychainService.shared.saveTokens(response: authResponse)
                AuthService.shared.recordSuccessfulAuthentication()

                Task {
                    let userResponse = await fetchCurrentUser(token: accessToken)
                    DispatchQueue.main.async {
                        var finalResponse = authResponse
                        if let user = userResponse {
                            finalResponse = AuthResponse(
                                access_token: accessToken,
                                refresh_token: refreshToken,
                                token_type: "bearer",
                                expires_in: expiresIn,
                                user: user
                            )
                        }
                        self.takeCompletion()?(.success(finalResponse))
                    }
                }
                return
            }

            if let code = fragmentParams["code"] {
                logger.info("Found auth code in fragment")
                exchangeCode(code)
                return
            }
        }

        // Nothing found
        logger.error("Failed to parse callback URL")
        DispatchQueue.main.async {
            self.takeCompletion()?(.failure(AuthError.serverError("Login failed")))
        }
    }

    private func parseFragment(_ fragment: String) -> [String: String] {
        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[key] = value
            }
        }
        return params
    }

    // MARK: - API calls

    private func exchangeCode(_ code: String) {
        Task {
            do {
                let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
                let url = URL(string: "\(Constants.apiBaseURL)/auth/callback?code=\(encoded)")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    DispatchQueue.main.async {
                        self.takeCompletion()?(.failure(AuthError.serverError("Invalid server response")))
                    }
                    return
                }

                if httpResponse.statusCode == 200 {
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    KeychainService.shared.saveTokens(response: authResponse)
                    AuthService.shared.recordSuccessfulAuthentication()
                    DispatchQueue.main.async {
                        self.takeCompletion()?(.success(authResponse))
                    }
                } else {
                    let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? "Login failed"
                    DispatchQueue.main.async {
                        self.takeCompletion()?(.failure(AuthError.serverError(detail)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.takeCompletion()?(.failure(error))
                }
            }
        }
    }

    private func fetchCurrentUser(token: String) async -> UserResponse? {
        let url = URL(string: "\(Constants.apiBaseURL)/auth/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(UserResponse.self, from: data)
    }
}
