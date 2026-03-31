import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ComposioToolProxy")

/// A tool that proxies execution to the SpeakFlow backend's Composio endpoint.
/// API key never leaves the server.
final class ComposioToolProxy: AgentTool {
    let name: String
    let description: String
    let parameters: [String: Any]

    /// The original Composio tool name (without prefix).
    private let composioToolName: String

    init(name: String, composioToolName: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.composioToolName = composioToolName
        self.description = description
        self.parameters = parameters
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await ComposioService.shared.executeTool(
            toolName: composioToolName,
            arguments: args
        )
    }
}

// MARK: - ComposioService extensions for tool proxy

extension ComposioService {
    /// Fetch available tools from the backend and return them as AgentTools.
    func fetchTools() async throws -> [AgentTool] {
        let token = try await AuthService.shared.getValidToken()
        let url = URL(string: "\(Constants.apiBaseURL)/composio/tools")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("fetchTools: invalid response type")
            return []
        }
        let statusCode = http.statusCode
        logger.info("fetchTools: status=\(statusCode)")

        guard statusCode == 200 else {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "nil"
            logger.error("Failed to fetch Composio tools: HTTP \(statusCode), body=\(bodyPreview)")
            return []
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.error("fetchTools: response is not [[String:Any]]")
            return []
        }

        return items.compactMap { item -> AgentTool? in
            guard let toolName = item["name"] as? String else { return nil }
            let desc = item["description"] as? String ?? "Composio tool"
            var params = item["parameters"] as? [String: Any] ?? [
                "type": "object",
                "properties": [:] as [String: Any],
            ]
            // Sanitize schema: OpenAI rejects non-object/boolean values in schema positions
            params = Self.sanitizeSchema(params)
            return ComposioToolProxy(
                name: "composio_\(toolName)",
                composioToolName: toolName,
                description: desc,
                parameters: params
            )
        }
    }

    /// Recursively clean JSON Schema so OpenAI accepts it.
    /// NSJSONSerialization turns JSON `false` into NSNumber(0), which re-serializes as `0`
    /// instead of `false`. Strip fields that cause this issue.
    private static func sanitizeSchema(_ schema: Any) -> [String: Any] {
        guard var dict = schema as? [String: Any] else {
            return ["type": "object", "properties": [:] as [String: Any]]
        }

        // Remove additionalProperties entirely — NSJSONSerialization mangles false→0
        dict.removeValue(forKey: "additionalProperties")

        // Remove other fields OpenAI doesn't need and that could have bool/int issues
        dict.removeValue(forKey: "examples")
        dict.removeValue(forKey: "human_parameter_name")
        dict.removeValue(forKey: "human_parameter_description")

        // Recurse into "properties"
        if let props = dict["properties"] as? [String: Any] {
            var cleaned: [String: Any] = [:]
            for (k, v) in props {
                if let subDict = v as? [String: Any] {
                    cleaned[k] = sanitizeSchema(subDict) as Any
                }
            }
            dict["properties"] = cleaned
        }

        // Recurse into "items"
        if let items = dict["items"] as? [String: Any] {
            dict["items"] = sanitizeSchema(items) as Any
        } else if dict["items"] != nil && !(dict["items"] is [String: Any]) {
            dict.removeValue(forKey: "items")
        }

        // Recurse into allOf/anyOf/oneOf
        for key in ["allOf", "anyOf", "oneOf"] {
            if let arr = dict[key] as? [Any] {
                dict[key] = arr.compactMap { elem -> [String: Any]? in
                    (elem as? [String: Any]).map { sanitizeSchema($0) }
                } as Any
            }
        }

        return dict
    }

    /// Execute a Composio tool via the backend.
    func executeTool(toolName: String, arguments: [String: Any]) async throws -> String {
        let token = try await AuthService.shared.getValidToken()
        let url = URL(string: "\(Constants.apiBaseURL)/composio/execute")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "tool_name": toolName,
            "arguments": arguments,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AgentToolError.executionFailed("Composio: \(detail)")
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            return result
        }
        return String(data: data, encoding: .utf8) ?? "OK"
    }
}
