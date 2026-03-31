import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "HeartbeatTool")

final class HeartbeatTool: AgentTool {
    let name = "heartbeat"
    let description = """
        注册定时/延迟/重复任务。到时间后推 macOS 通知或重新进入 agent loop 执行任务。\
        trigger_at: 触发时间，支持 ISO 8601 格式或相对时间如 "+10m"、"+2h"。\
        repeat_rule: null（一次性）、"daily"、"weekly"、"hourly"、"30m"（每30分钟）。\
        action: "notify"（推通知）或 "agent"（重新唤醒 agent 执行 message 中的指令）。\
        也可以用 action "list" 查看所有定时任务，"cancel" 取消任务(需要 id)。
        """

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["schedule", "list", "cancel"],
                "description": "操作类型：schedule 创建任务，list 查看任务，cancel 取消任务",
            ],
            "trigger_at": [
                "type": "string",
                "description": "触发时间。ISO 8601 (如 2026-03-09T15:00:00+08:00) 或相对时间 (+10m, +2h, +1d)",
            ],
            "repeat_rule": [
                "type": "string",
                "description": "重复规则：null=一次性, daily, weekly, hourly, 或 Xm/Xh",
            ],
            "trigger_action": [
                "type": "string",
                "enum": ["notify", "agent"],
                "description": "触发动作：notify=推通知, agent=重新唤醒 agent 执行任务",
            ],
            "message": [
                "type": "string",
                "description": "通知内容或 agent 指令",
            ],
            "id": [
                "type": "string",
                "description": "任务 ID（cancel 时需要）",
            ],
        ],
        "required": ["action"],
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let action = args["action"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'action'")
        }

        logger.info("Heartbeat executing action: \(action)")

        switch action {
        case "schedule":
            return try await scheduleEntry(args)
        case "list":
            return await listEntries()
        case "cancel":
            return try await cancelEntry(args)
        default:
            logger.error("Heartbeat unknown action: \(action)")
            throw AgentToolError.invalidArguments("Unknown action: \(action)")
        }
    }

    private func scheduleEntry(_ args: [String: Any]) async throws -> String {
        guard let triggerStr = args["trigger_at"] as? String else {
            throw AgentToolError.invalidArguments("schedule requires 'trigger_at'")
        }
        guard let message = args["message"] as? String else {
            throw AgentToolError.invalidArguments("schedule requires 'message'")
        }

        let triggerDate = try parseTriggerTime(triggerStr)
        let repeatRule = args["repeat_rule"] as? String
        let actionStr = args["trigger_action"] as? String ?? "notify"

        guard let heartbeatAction = HeartbeatAction(rawValue: actionStr) else {
            throw AgentToolError.invalidArguments("Invalid trigger_action: \(actionStr)")
        }

        let entry = HeartbeatEntry(
            id: UUID(),
            triggerAt: triggerDate,
            repeatRule: repeatRule,
            action: heartbeatAction,
            message: message,
            context: nil,
            createdAt: Date()
        )

        await MainActor.run {
            HeartbeatScheduler.shared.add(entry)
        }

        logger.info("Heartbeat scheduled: \(message) at \(triggerDate), repeat: \(repeatRule ?? "none"), action: \(actionStr)")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timeStr = formatter.string(from: triggerDate)

        var result = "已设置定时任务：\(message)\n触发时间：\(timeStr)"
        if let rule = repeatRule {
            result += "\n重复：\(rule)"
        }
        result += "\n动作：\(actionStr == "agent" ? "重新唤醒 Agent" : "推送通知")"
        result += "\nID：\(entry.id.uuidString)"
        return result
    }

    private func listEntries() async -> String {
        let entries = await MainActor.run {
            HeartbeatScheduler.shared.listAll()
        }
        if entries.isEmpty { return "暂无定时任务" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return entries.map { entry in
            var line = "- [\(entry.id.uuidString.prefix(8))] \(formatter.string(from: entry.triggerAt)) | \(entry.action.rawValue) | \(entry.message)"
            if let rule = entry.repeatRule {
                line += " (repeat: \(rule))"
            }
            return line
        }.joined(separator: "\n")
    }

    private func cancelEntry(_ args: [String: Any]) async throws -> String {
        guard let idStr = args["id"] as? String else {
            throw AgentToolError.invalidArguments("cancel requires 'id'")
        }

        // Support both full UUID and prefix match
        let entries = await MainActor.run { HeartbeatScheduler.shared.listAll() }
        guard let entry = entries.first(where: {
            $0.id.uuidString == idStr || $0.id.uuidString.hasPrefix(idStr)
        }) else {
            return "未找到任务: \(idStr)"
        }

        let removed = await MainActor.run {
            HeartbeatScheduler.shared.remove(id: entry.id)
        }
        if removed {
            logger.info("Heartbeat cancelled task: \(entry.id.uuidString)")
        } else {
            logger.warning("Heartbeat failed to cancel task: \(entry.id.uuidString)")
        }
        return removed ? "已取消任务: \(entry.message)" : "取消失败"
    }

    // MARK: - Time Parsing

    func parseTriggerTime(_ str: String) throws -> Date {
        // Relative time: +10m, +2h, +1d
        if str.hasPrefix("+") {
            let suffix = str.dropFirst()
            let calendar = Calendar.current
            let now = Date()

            if suffix.hasSuffix("m"), let mins = Int(suffix.dropLast()) {
                return calendar.date(byAdding: .minute, value: mins, to: now)!
            }
            if suffix.hasSuffix("h"), let hrs = Int(suffix.dropLast()) {
                return calendar.date(byAdding: .hour, value: hrs, to: now)!
            }
            if suffix.hasSuffix("d"), let days = Int(suffix.dropLast()) {
                return calendar.date(byAdding: .day, value: days, to: now)!
            }
            throw AgentToolError.invalidArguments("Invalid relative time: \(str). Use +Xm, +Xh, or +Xd")
        }

        // ISO 8601 with timezone (e.g. "2026-03-10T17:21:00Z" or "...+08:00")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: str) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: str) { return date }

        // Try common formats — all parsed as LOCAL time (user's timezone)
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "HH:mm"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current  // Treat as local time, not UTC

        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: str) {
                // For time-only format, set to today (or tomorrow if time has passed)
                if fmt == "HH:mm" {
                    let calendar = Calendar.current
                    let components = calendar.dateComponents([.hour, .minute], from: date)
                    var target = calendar.dateComponents([.year, .month, .day], from: Date())
                    target.hour = components.hour
                    target.minute = components.minute
                    target.timeZone = TimeZone.current
                    if let result = calendar.date(from: target) {
                        return result < Date() ? calendar.date(byAdding: .day, value: 1, to: result)! : result
                    }
                }
                return date
            }
        }

        throw AgentToolError.invalidArguments("Cannot parse time: \(str). Use ISO 8601 or relative (+10m, +2h)")
    }
}
