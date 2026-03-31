import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AgentAPIClient")

enum AgentAPIError: LocalizedError {
    case unauthorized
    case noSubscription
    case rateLimited(retryAfter: Int)
    case serverError(Int, String?)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired. Please sign in again."
        case .noSubscription: return "Active subscription required."
        case .rateLimited(let sec): return "Too many requests. Retry in \(sec)s."
        case .serverError(let code, let detail): return detail ?? "Server error (\(code))"
        case .invalidResponse: return "Invalid server response"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

final class AgentAPIClient {
    private let authService = AuthService.shared
    private let endpoint = Constants.apiBaseURL + "/agent/chat"

    func chat(
        messages: [AgentMessage],
        tools: [ToolDefinition],
        promptCacheKey: String? = nil
    ) async throws -> AgentChatResponse {
        logger.info("API chat request starting with \(messages.count) messages and \(tools.count) tools")
        let token = try await authService.getValidToken()
        let request = try buildRequest(
            token: token,
            messages: messages,
            tools: tools,
            promptCacheKey: promptCacheKey
        )

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("API response is not HTTPURLResponse")
            throw AgentAPIError.invalidResponse
        }

        logger.info("API response HTTP status: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            logger.info("API request completed successfully")
            return try decodeResponse(data)

        case 401:
            logger.warning("API returned 401, attempting token refresh")
            // Retry with refreshed token
            let newToken = try await authService.refresh().access_token
            let retryRequest = try buildRequest(
                token: newToken,
                messages: messages,
                tools: tools,
                promptCacheKey: promptCacheKey
            )
            let (retryData, retryResponse) = try await performRequest(retryRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                logger.error("API token refresh retry failed, unauthorized")
                throw AgentAPIError.unauthorized
            }
            logger.info("API request succeeded after token refresh")
            return try decodeResponse(retryData)

        case 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("subscription") || body.contains("Subscription") {
                logger.error("API returned 403: no active subscription")
                throw AgentAPIError.noSubscription
            }
            logger.error("API returned 403: forbidden")
            throw AgentAPIError.serverError(403, nil)

        case 429:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("Daily") || body.contains("daily") {
                logger.warning("API rate limited: daily limit reached")
                throw AgentAPIError.rateLimited(retryAfter: 86400)
            }
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            logger.warning("API rate limited, retry after \(retryAfter)s")
            throw AgentAPIError.rateLimited(retryAfter: retryAfter)

        default:
            // Extract detail from FastAPI error response
            let detail: String? = {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = json["detail"] as? String else { return nil }
                return d
            }()
            logger.error("API server error \(httpResponse.statusCode): \(detail ?? "no detail")")
            throw AgentAPIError.serverError(httpResponse.statusCode, detail)
        }
    }

    private func buildRequest(
        token: String,
        messages: [AgentMessage],
        tools: [ToolDefinition],
        promptCacheKey: String?
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw AgentAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AgentChatRequest(
            messages: messages,
            tools: tools,
            promptCacheKey: promptCacheKey
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            logger.error("API network error: \(error.localizedDescription)")
            throw AgentAPIError.networkError(error)
        }
    }

    private func decodeResponse(_ data: Data) throws -> AgentChatResponse {
        do {
            return try JSONDecoder().decode(AgentChatResponse.self, from: data)
        } catch {
            logger.error("API response decode failed: \(error.localizedDescription)")
            throw AgentAPIError.invalidResponse
        }
    }
}
