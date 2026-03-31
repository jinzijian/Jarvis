import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MCPServerManager")

/// Wraps an MCP tool as an AgentTool for the ToolRegistry.
private final class MCPToolWrapper: AgentTool {
    let name: String
    let description: String
    let parameters: [String: Any]
    private let client: MCPClient
    private let originalToolName: String

    init(toolInfo: MCPToolInfo, client: MCPClient, serverName: String) {
        // Prefix with server name to avoid collisions
        self.name = "mcp_\(serverName)_\(toolInfo.name)"
        self.description = toolInfo.description ?? "MCP tool from \(serverName)"
        self.originalToolName = toolInfo.name

        if let schema = toolInfo.inputSchema?.value as? [String: Any] {
            self.parameters = schema
        } else {
            self.parameters = ["type": "object", "properties": [:] as [String: Any]]
        }

        self.client = client
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        return try await client.callTool(name: originalToolName, arguments: args)
    }
}

/// Manages multiple MCP server processes and their tools.
@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()

    @Published private(set) var servers: [String: MCPServerConfig] = [:]
    @Published private(set) var connectedServers: Set<String> = []
    @Published private(set) var connectionErrors: [String: String] = [:]

    private var clients: [String: MCPClient] = [:]
    private let configURL: URL

    /// User-visible servers (excludes built-in servers).
    var userServers: [MCPServerConfig] {
        servers.values.filter { !$0.isBuiltin }.sorted { $0.name < $1.name }
    }

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("mcp.json")
        loadConfig()
        registerBuiltinServers()
    }

    /// Register built-in MCP servers — always overwrite to ensure correct config.
    private func registerBuiltinServers() {
        let builtins = builtinServers()
        var changed = migrateLegacyConfigs()
        for config in builtins {
            servers[config.name] = config
            changed = true
            logger.info("Registered built-in MCP server: \(config.name)")
        }
        if changed {
            saveConfig()
        }
    }

    // MARK: - Server Management

    func addServer(_ config: MCPServerConfig) {
        servers[config.name] = config
        saveConfig()
    }

    func removeServer(name: String) {
        guard servers[name]?.isBuiltin != true else {
            logger.warning("Cannot remove built-in server '\(name)'")
            return
        }
        Task {
            await disconnectServer(name: name)
        }
        servers.removeValue(forKey: name)
        saveConfig()
    }

    func toggleServer(name: String, enabled: Bool) {
        guard servers[name]?.isBuiltin != true else {
            logger.warning("Cannot toggle built-in server '\(name)'")
            return
        }
        servers[name]?.enabled = enabled
        saveConfig()

        if !enabled {
            Task {
                await disconnectServer(name: name)
            }
        }
    }

    // MARK: - Connection

    nonisolated func connectServer(name: String) async throws {
        let (config, existingClient) = await MainActor.run {
            connectionErrors[name] = nil
            let existingClient = clients.removeValue(forKey: name)
            connectedServers.remove(name)
            return (servers[name], existingClient)
        }
        existingClient?.disconnect()
        guard let config else {
            throw MCPClientError.invalidResponse("Server '\(name)' not found")
        }

        do {
            let client = MCPClient(config: config)
            client.onUnexpectedExit = { [weak self, weak client] status in
                guard let client else { return }
                Task { @MainActor in
                    guard let self else { return }
                    guard self.clients[name] === client else { return }
                    self.clients.removeValue(forKey: name)
                    self.connectedServers.remove(name)
                    self.connectionErrors[name] = MCPClientError.processExited(status).localizedDescription
                }
            }
            try await client.connect()

            await MainActor.run {
                clients[name] = client
                connectedServers.insert(name)
                connectionErrors.removeValue(forKey: name)
            }

            logger.info("Connected to MCP server '\(name)' with \(client.tools.count) tools")
        } catch {
            await MainActor.run {
                connectionErrors[name] = error.localizedDescription
            }
            throw error
        }
    }

    nonisolated func disconnectServer(name: String) async {
        let client = await MainActor.run {
            let client = clients.removeValue(forKey: name)
            connectedServers.remove(name)
            connectionErrors.removeValue(forKey: name)
            return client
        }
        client?.disconnect()
    }

    /// Connect all enabled servers.
    nonisolated func connectAll() async {
        let enabledServers = await MainActor.run {
            servers.values.filter { $0.enabled }
        }

        for config in enabledServers {
            do {
                try await connectServer(name: config.name)
            } catch {
                logger.error("Failed to connect MCP server '\(config.name)': \(error.localizedDescription)")
            }
        }
    }

    func disconnectAll() {
        for name in connectedServers {
            clients[name]?.disconnect()
        }
        clients.removeAll()
        connectedServers.removeAll()
    }

    // MARK: - Tool Registration

    /// Register all connected MCP tools into a ToolRegistry.
    func registerTools(in registry: ToolRegistry) {
        var wrappers: [AgentTool] = []
        for (name, client) in clients where client.isConnected {
            for toolInfo in client.tools {
                wrappers.append(MCPToolWrapper(toolInfo: toolInfo, client: client, serverName: name))
            }
        }
        registry.replaceTools(matchingPrefix: "mcp_", with: wrappers)
    }

    /// Get tool definitions for all connected MCP servers.
    func allToolDefinitions() -> [ToolDefinition] {
        var definitions: [ToolDefinition] = []
        for (name, client) in clients where client.isConnected {
            for toolInfo in client.tools {
                let wrapper = MCPToolWrapper(toolInfo: toolInfo, client: client, serverName: name)
                definitions.append(wrapper.toolDefinition())
            }
        }
        return definitions
    }

    /// Find which server handles a given tool name.
    func clientForTool(named toolName: String) -> MCPClient? {
        // Tool names are prefixed: mcp_serverName_toolName
        let parts = toolName.split(separator: "_", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "mcp" else { return nil }
        return clients[String(parts[1])]
    }

    // MARK: - Composio

    // Composio tools are handled server-side via ComposioToolProxy, not as a local MCP server.

    // MARK: - Config Persistence

    private func loadConfig() {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        do {
            let data = try Data(contentsOf: configURL)
            let file = try JSONDecoder().decode(MCPConfigFile.self, from: data)
            // All loaded configs are user configs (isBuiltin = false by Codable default)
            servers = file.servers
            logger.info("Loaded \(self.servers.count) MCP server configs")
        } catch {
            logger.error("Failed to load MCP config: \(error.localizedDescription)")
        }
    }

    private func builtinServers() -> [MCPServerConfig] {
        [
            MCPServerConfig(
                name: "playwright",
                command: "npx",
                args: ["-y", "@playwright/mcp@latest"],
                enabled: true,
                isBuiltin: true
            ),
        ]
    }

    private func migrateLegacyConfigs() -> Bool {
        var changed = false

        // Remove playwright from user config — it's now built-in
        if servers["playwright"] != nil {
            servers.removeValue(forKey: "playwright")
            connectionErrors.removeValue(forKey: "playwright")
            changed = true
            logger.info("Migrated Playwright to built-in (removed from user config)")
        }

        if let legacyComposio = servers["composio"], isBrokenLegacyComposioConfig(legacyComposio) {
            servers.removeValue(forKey: "composio")
            connectedServers.remove("composio")
            connectionErrors.removeValue(forKey: "composio")
            changed = true
            logger.info("Removed broken legacy local Composio MCP config")
        }

        // Mark remaining stdio servers as legacy (they still work but are from old config)
        for (key, var config) in servers {
            if case .stdio = config.transport, !config.isBuiltin {
                // Keep them functional — just ensure isBuiltin is false
                config.isBuiltin = false
                servers[key] = config
            }
        }

        return changed
    }

    private func isBrokenLegacyComposioConfig(_ config: MCPServerConfig) -> Bool {
        guard case .stdio(let command, let args, let env) = config.transport else { return false }
        guard command == "npx", args == ["-y", "@composio/mcp@latest"] else { return false }
        return (env?["COMPOSIO_API_KEY"] ?? "").isEmpty
    }

    private func saveConfig() {
        // Filter out built-in servers — they are managed by the app
        let userOnly = servers.filter { !$0.value.isBuiltin }
        let file = MCPConfigFile(servers: userOnly)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: configURL, options: .atomic)
        } catch {
            logger.error("Failed to save MCP config: \(error.localizedDescription)")
        }
    }
}
