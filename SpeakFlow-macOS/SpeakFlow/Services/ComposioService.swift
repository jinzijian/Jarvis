import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ComposioService")

/// Client-side service for Composio OAuth integration.
/// Calls SpeakFlow backend endpoints that proxy to Composio API.
final class ComposioService {
    static let shared = ComposioService()
    private let baseURL = Constants.apiBaseURL

    private init() {}

    // MARK: - Models

    struct ComposioConnection: Decodable, Identifiable {
        let id: String
        let appName: String
        let status: String  // "ACTIVE", "INITIATED", etc.

        enum CodingKeys: String, CodingKey {
            case id
            case appName = "app_name"
            case appSlug = "app_slug"
            case app
            case name
            case status
            case connectionStatus = "connection_status"
            case state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = Self.decodeLossyString(from: container, key: .id) ?? UUID().uuidString
            appName = Self.decodeLossyString(from: container, key: .appName)
                ?? Self.decodeLossyString(from: container, key: .appSlug)
                ?? Self.decodeLossyString(from: container, key: .app)
                ?? Self.decodeLossyString(from: container, key: .name)
                ?? ""
            status = Self.decodeLossyString(from: container, key: .status)
                ?? Self.decodeLossyString(from: container, key: .connectionStatus)
                ?? Self.decodeLossyString(from: container, key: .state)
                ?? ""
        }

        var normalizedStatus: String {
            status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }

        /// Pending states can appear right after OAuth before final activation.
        var isPending: Bool {
            [
                "INITIATED",
                "PENDING",
                "IN_PROGRESS",
                "AUTH_IN_PROGRESS",
                "OAUTH_IN_PROGRESS",
                "AWAITING_AUTH",
            ].contains(normalizedStatus)
        }

        /// Explicitly inactive states from provider/back-end.
        var isInactive: Bool {
            [
                "INACTIVE",
                "DISABLED",
                "DISCONNECTED",
                "REVOKED",
                "FAILED",
                "ERROR",
                "EXPIRED",
                "DELETED",
            ].contains(normalizedStatus)
        }

        /// Treat unknown statuses as active to avoid dropping valid cloud connections on schema drift.
        var isActive: Bool { !appName.isEmpty && !isInactive }

        private static func decodeLossyString(
            from container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> String? {
            if let value = try? container.decode(String.self, forKey: key) {
                return value
            }
            if let intValue = try? container.decode(Int.self, forKey: key) {
                return String(intValue)
            }
            if let boolValue = try? container.decode(Bool.self, forKey: key) {
                return boolValue ? "true" : "false"
            }
            return nil
        }
    }

    struct ConnectResponse: Decodable {
        let redirectUrl: String?
        let alreadyConnected: Bool?

        enum CodingKeys: String, CodingKey {
            case redirectUrl = "redirect_url"
            case alreadyConnected = "already_connected"
        }
    }

    // MARK: - API

    /// Get all connected Composio integrations for the current user.
    func getConnections() async throws -> [ComposioConnection] {
        let token = try await AuthService.shared.getValidToken()
        let url = URL(string: "\(baseURL)/composio/connections")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = parseError(data: data)
            throw AuthError.serverError("Failed to fetch connections: \(detail)")
        }
        let connections = try JSONDecoder().decode([ComposioConnection].self, from: data)
        let summary = connections.map { "\($0.appName):\($0.normalizedStatus)" }.joined(separator: ", ")
        logger.info("Fetched \(connections.count) Composio connections \(summary, privacy: .public)")
        return connections
    }

    /// Initiate OAuth for a Composio app. Returns a redirect URL, or "already_connected".
    func connect(appName: String) async throws -> String {
        let token = try await AuthService.shared.getValidToken()
        let url = URL(string: "\(baseURL)/composio/connect")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["app_name": appName])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = parseError(data: data)
            throw AuthError.serverError("Failed to connect \(appName): \(detail)")
        }
        let result = try JSONDecoder().decode(ConnectResponse.self, from: data)
        if result.alreadyConnected == true {
            return "already_connected"
        }
        return result.redirectUrl ?? ""
    }

    /// Disconnect (revoke) a Composio integration.
    func disconnect(connectionId: String) async throws {
        let token = try await AuthService.shared.getValidToken()
        let url = URL(string: "\(baseURL)/composio/connections/\(connectionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = parseError(data: data)
            throw AuthError.serverError("Failed to disconnect: \(detail)")
        }
        _ = data  // success
    }

    /// Open the OAuth URL in the user's default browser.
    func openOAuth(appName: String) async throws {
        let redirectUrl = try await connect(appName: appName)
        guard let url = URL(string: redirectUrl) else {
            throw AuthError.serverError("Invalid redirect URL")
        }
        logger.info("Opening OAuth for \(appName): \(redirectUrl)")
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func parseError(data: Data) -> String {
        parseAPIError(data: data)
    }
}
