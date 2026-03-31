import Foundation

// MARK: - JSON-RPC Protocol

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - MCP Protocol Types

struct MCPServerInfo: Codable {
    let name: String
    let version: String?
}

struct MCPInitializeResult: Decodable {
    let protocolVersion: String?
    let serverInfo: MCPServerInfo?
    let capabilities: MCPCapabilities?
}

struct MCPCapabilities: Decodable {
    let tools: MCPToolsCapability?
}

struct MCPToolsCapability: Decodable {
    let listChanged: Bool?
}

struct MCPToolInfo: Decodable {
    let name: String
    let description: String?
    let inputSchema: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }
}

struct MCPToolsListResult: Decodable {
    let tools: [MCPToolInfo]
}

struct MCPToolCallResult: Decodable {
    let content: [MCPContent]
    let isError: Bool?
}

struct MCPContent: Decodable {
    let type: String
    let text: String?
}

// MARK: - MCP Transport

enum MCPTransport: Equatable {
    case stdio(command: String, args: [String], env: [String: String]?)
    case sse(url: String, headers: [String: String]?)

    var displayDescription: String {
        switch self {
        case .stdio(let command, let args, _):
            return "stdio(\(command) \(args.joined(separator: " ")))"
        case .sse(let url, _):
            return "sse(\(url))"
        }
    }
}

extension MCPTransport: Codable {
    private enum TransportType: String, Codable {
        case stdio, sse
    }

    private enum CodingKeys: String, CodingKey {
        case type, command, args, env, url, headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let type = try container.decodeIfPresent(TransportType.self, forKey: .type) {
            switch type {
            case .stdio:
                let command = try container.decode(String.self, forKey: .command)
                let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
                let env = try container.decodeIfPresent([String: String].self, forKey: .env)
                self = .stdio(command: command, args: args, env: env)
            case .sse:
                let url = try container.decode(String.self, forKey: .url)
                let headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
                self = .sse(url: url, headers: headers)
            }
        } else {
            // Legacy format: no "type" key, has "command" and "args" at top level
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            let env = try container.decodeIfPresent([String: String].self, forKey: .env)
            self = .stdio(command: command, args: args, env: env)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let command, let args, let env):
            try container.encode(TransportType.stdio, forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encodeIfPresent(env, forKey: .env)
        case .sse(let url, let headers):
            try container.encode(TransportType.sse, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
        }
    }
}

// MARK: - MCP Server Configuration

struct MCPServerConfig: Identifiable {
    var id: String { name }
    let name: String
    var transport: MCPTransport
    var enabled: Bool
    var isBuiltin: Bool

    init(name: String, transport: MCPTransport, enabled: Bool = true, isBuiltin: Bool = false) {
        self.name = name
        self.transport = transport
        self.enabled = enabled
        self.isBuiltin = isBuiltin
    }

    /// Legacy convenience initializer for stdio servers.
    init(name: String, command: String, args: [String], env: [String: String]? = nil, enabled: Bool = true, isBuiltin: Bool = false) {
        self.name = name
        self.transport = .stdio(command: command, args: args, env: env)
        self.enabled = enabled
        self.isBuiltin = isBuiltin
    }

    // Convenience accessors for stdio transport (backward compat)
    var command: String? {
        if case .stdio(let command, _, _) = transport { return command }
        return nil
    }

    var args: [String]? {
        if case .stdio(_, let args, _) = transport { return args }
        return nil
    }

    var env: [String: String]? {
        if case .stdio(_, _, let env) = transport { return env }
        if case .sse(_, let headers) = transport { return headers }
        return nil
    }

    var urlString: String? {
        if case .sse(let url, _) = transport { return url }
        return nil
    }
}

extension MCPServerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, transport, enabled, isBuiltin
        // Legacy keys
        case command, args, env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // isBuiltin is never persisted — defaults to false when loaded from disk
        isBuiltin = false

        if let transport = try container.decodeIfPresent(MCPTransport.self, forKey: .transport) {
            self.transport = transport
        } else {
            // Legacy format: command/args/env at top level
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            let env = try container.decodeIfPresent([String: String].self, forKey: .env)
            self.transport = .stdio(command: command, args: args, env: env)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(transport, forKey: .transport)
        try container.encode(enabled, forKey: .enabled)
        // isBuiltin is intentionally NOT persisted
    }
}

struct MCPConfigFile: Codable {
    var servers: [String: MCPServerConfig]
}
