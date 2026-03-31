import Foundation

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var parameters: [String: Any] { get }
    func execute(arguments: String) async throws -> String
    func toolDefinition() -> ToolDefinition
}

extension AgentTool {
    func toolDefinition() -> ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }

    /// Parse JSON arguments string into a dictionary.
    func parseArguments(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentToolError.invalidArguments("Failed to parse arguments JSON")
        }
        return dict
    }
}

enum AgentToolError: LocalizedError {
    case invalidArguments(String)
    case executionFailed(String)
    case timeout
    case securityBlocked(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        case .timeout: return "Tool execution timed out"
        case .securityBlocked(let msg): return "Security blocked: \(msg)"
        }
    }
}
