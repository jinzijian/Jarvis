import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MemoryTool")

final class MemoryTool: AgentTool {
    let name = "memory"
    let description = """
        长期记忆，跨 session 记住用户信息。\
        action: "save" 保存记忆(需要 key + value)，\
        "get" 读取特定记忆(需要 key)，\
        "list" 列出所有记忆，\
        "delete" 删除记忆(需要 key)，\
        "search" 搜索记忆(需要 query)。\
        主动判断什么时候该记住（用户提到人名、偏好、常用信息时）。
        """

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["save", "get", "list", "delete", "search"],
                "description": "操作类型",
            ],
            "key": [
                "type": "string",
                "description": "记忆的 key（save/get/delete 时需要）",
            ],
            "value": [
                "type": "string",
                "description": "记忆的 value（save 时需要）",
            ],
            "query": [
                "type": "string",
                "description": "搜索关键词（search 时需要）",
            ],
        ],
        "required": ["action"],
    ]

    private let store: MemoryStore

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let action = args["action"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'action'")
        }

        logger.info("Memory executing action: \(action)")

        switch action {
        case "save":
            guard let key = args["key"] as? String, let value = args["value"] as? String else {
                throw AgentToolError.invalidArguments("save requires 'key' and 'value'")
            }
            store.save(key: key, value: value)
            logger.info("Memory saved: \(key)")
            return "已保存记忆: \(key) = \(value)"

        case "get":
            guard let key = args["key"] as? String else {
                throw AgentToolError.invalidArguments("get requires 'key'")
            }
            if let entry = store.get(key: key) {
                logger.info("Memory loaded: \(key)")
                return "\(entry.key): \(entry.value)"
            }
            logger.info("Memory not found: \(key)")
            return "未找到记忆: \(key)"

        case "list":
            let entries = store.list()
            logger.info("Memory list: \(entries.count) entries")
            if entries.isEmpty { return "暂无记忆" }
            return entries.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")

        case "delete":
            guard let key = args["key"] as? String else {
                throw AgentToolError.invalidArguments("delete requires 'key'")
            }
            if store.delete(key: key) {
                logger.info("Memory deleted: \(key)")
                return "已删除记忆: \(key)"
            }
            logger.warning("Memory delete failed, not found: \(key)")
            return "未找到记忆: \(key)"

        case "search":
            guard let query = args["query"] as? String else {
                throw AgentToolError.invalidArguments("search requires 'query'")
            }
            let results = store.search(query: query)
            logger.info("Memory search for '\(query)': \(results.count) results")
            if results.isEmpty { return "未找到匹配的记忆" }
            return results.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")

        default:
            logger.error("Memory unknown action: \(action)")
            throw AgentToolError.invalidArguments("Unknown action: \(action)")
        }
    }
}
