import Foundation

// MARK: - Multimodal Content

/// Message content: either a plain string or an array of content parts (text + images).
/// Encodes as `"string"` or `[{"type":"text","text":"..."},{"type":"image_url",...}]`.
enum MessageContent: Codable, Equatable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
        } else {
            self = .text("")
        }
    }

    /// Extract text content (for display, logging, etc.)
    var textValue: String {
        switch self {
        case .text(let s): return s
        case .parts(let parts):
            return parts.compactMap { $0.text }.joined(separator: "\n")
        }
    }

    /// Whether this content contains image data.
    var hasImage: Bool {
        switch self {
        case .text: return false
        case .parts(let parts): return parts.contains { $0.type == "image_url" }
        }
    }

    /// Return a copy with image parts stripped, replaced by a text note.
    var withoutImages: MessageContent {
        switch self {
        case .text: return self
        case .parts(let parts):
            var textParts = parts.filter { $0.type != "image_url" }
            if parts.contains(where: { $0.type == "image_url" }) {
                textParts.append(.text("[Image was here — already processed]"))
            }
            if textParts.count == 1, let t = textParts.first?.text {
                return .text(t)
            }
            return .parts(textParts)
        }
    }
}

struct ContentPart: Codable, Equatable {
    let type: String // "text", "image_url", or "file"
    let text: String?
    let imageUrl: ImageURLContent?
    let file: FileContent?

    enum CodingKeys: String, CodingKey {
        case type, text, file
        case imageUrl = "image_url"
    }

    static func text(_ text: String) -> ContentPart {
        ContentPart(type: "text", text: text, imageUrl: nil, file: nil)
    }

    static func imageUrl(_ url: String, detail: String = "low") -> ContentPart {
        ContentPart(type: "image_url", text: nil, imageUrl: ImageURLContent(url: url, detail: detail), file: nil)
    }

    static func file(data: String, filename: String) -> ContentPart {
        ContentPart(type: "file", text: nil, imageUrl: nil, file: FileContent(fileData: data, filename: filename))
    }
}

struct FileContent: Codable, Equatable {
    let fileData: String
    let filename: String

    enum CodingKeys: String, CodingKey {
        case fileData = "file_data"
        case filename
    }
}

struct ImageURLContent: Codable, Equatable {
    let url: String
    let detail: String?

    init(url: String, detail: String? = "low") {
        self.url = url
        self.detail = detail
    }
}

// MARK: - Message Types

struct AgentMessage: Codable {
    let role: AgentRole
    let content: MessageContent?
    let toolCalls: [AgentToolCall]?
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    /// Convenience init with a plain string (most common case).
    init(role: AgentRole, content: String?, toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content.map { .text($0) }
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Init with multimodal content parts.
    init(role: AgentRole, contentParts: [ContentPart], toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = .parts(contentParts)
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }

    /// Init with MessageContent directly.
    init(role: AgentRole, messageContent: MessageContent?, toolCalls: [AgentToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = messageContent
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

enum AgentRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

struct AgentToolCall: Codable {
    let id: String
    let type: String
    let function: AgentFunctionCall

    init(id: String, type: String = "function", function: AgentFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

struct AgentFunctionCall: Codable {
    let name: String
    let arguments: String
}

// MARK: - API Request/Response

struct AgentChatRequest: Codable {
    let messages: [AgentMessage]
    let tools: [ToolDefinition]
    let promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case messages
        case tools
        case promptCacheKey = "prompt_cache_key"
    }
}

struct AgentChatResponse: Codable {
    let message: AgentMessage
    let usage: AgentUsage?
}

struct AgentUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let cachedPromptTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
    }
}

// MARK: - Tool Definition (OpenAI function tool format)

struct ToolDefinition: Codable {
    let type: String
    let function: FunctionDefinition

    init(name: String, description: String, parameters: [String: Any]) {
        self.type = "function"
        self.function = FunctionDefinition(
            name: name,
            description: description,
            parameters: AnyCodable(parameters)
        )
    }
}

struct FunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: AnyCodable
}

/// Type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case is NSNull:
            try container.encodeNil()
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

// MARK: - Stream Items (unified timeline)

enum StreamItem: Identifiable {
    case userMessage(id: String = UUID().uuidString, text: String)
    case step(StepItem)
    case agentReply(id: String = UUID().uuidString, text: String)

    var id: String {
        switch self {
        case .userMessage(let id, _): return id
        case .step(let item): return item.id
        case .agentReply(let id, _): return id
        }
    }
}

// MARK: - Step Tracking

enum StepStatus: String {
    case pending
    case running
    case done
    case failed
    case cancelled
}

struct StepItem: Identifiable {
    let id: String
    var title: String
    var status: StepStatus
    var detail: String?
    var toolCallId: String?
}

// MARK: - User Interaction

struct PendingQuestion {
    let message: String
    let type: QuestionType
    let options: [String]?

    enum QuestionType: String {
        case confirmation
        case clarification
        case selection
    }
}
