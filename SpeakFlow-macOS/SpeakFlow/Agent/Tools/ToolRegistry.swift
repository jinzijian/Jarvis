import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ToolRegistry")

final class ToolRegistry {
    private var tools: [String: AgentTool] = [:]

    init(agentState: AgentState) {
        let builtinTools: [AgentTool] = [
            BashTool(),
            ReadTool(),
            WriteTool(),
            EditTool(),
            GlobTool(),
            GrepTool(),
            LsTool(),
            WebFetchTool(),
            ViewFileTool(),
            ScreenshotTool(),
            BrowserTool(),
            QuestionTool(agentState: agentState),
            MemoryTool(),
            HeartbeatTool(),
        ]

        for tool in builtinTools {
            tools[tool.name] = tool
            logger.info("Registered built-in tool: \(tool.name)")
        }
        logger.info("ToolRegistry initialized with \(builtinTools.count) built-in tools")
    }

    func allDefinitions() -> [ToolDefinition] {
        tools.values.map { $0.toolDefinition() }
    }

    func execute(name: String, arguments: String) async throws -> String {
        guard let tool = tools[name] else {
            logger.error("Tool lookup failed: unknown tool '\(name)'")
            throw AgentToolError.executionFailed("Unknown tool: \(name)")
        }
        logger.info("Executing tool: \(name)")
        return try await tool.execute(arguments: arguments)
    }

    // MARK: - MCP Integration (placeholder)

    func registerTool(_ tool: AgentTool) {
        logger.info("Registering tool: \(tool.name)")
        tools[tool.name] = tool
    }

    func unregisterTool(named name: String) {
        logger.info("Unregistering tool: \(name)")
        tools.removeValue(forKey: name)
    }

    func replaceTools(matchingPrefix prefix: String, with newTools: [AgentTool]) {
        tools = tools.filter { !$0.key.hasPrefix(prefix) }
        for tool in newTools {
            tools[tool.name] = tool
        }
    }
}
