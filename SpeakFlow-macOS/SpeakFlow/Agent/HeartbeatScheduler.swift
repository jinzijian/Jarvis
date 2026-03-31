import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "Heartbeat")

enum HeartbeatAction: String, Codable {
    case notify  // Push macOS notification
    case agent   // Re-enter agent loop with message as command
}

struct HeartbeatEntry: Codable, Identifiable {
    let id: UUID
    let triggerAt: Date
    let repeatRule: String?  // nil = one-shot, "daily", "weekly", or cron
    let action: HeartbeatAction
    let message: String
    let context: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case triggerAt = "trigger_at"
        case repeatRule = "repeat_rule"
        case action, message, context
        case createdAt = "created_at"
    }
}

struct HeartbeatFile: Codable {
    var entries: [HeartbeatEntry]
}

@MainActor
final class HeartbeatScheduler: ObservableObject {
    static let shared = HeartbeatScheduler()

    @Published private(set) var entries: [HeartbeatEntry] = []

    private let fileURL: URL
    private var timer: Timer?

    /// Callback invoked when a heartbeat with `.agent` action fires.
    /// AppState sets this to call `runAgent(command:)`.
    var onAgentTrigger: ((String) -> Void)?

    /// Callback invoked when a heartbeat with `.notify` action fires.
    /// AppState sets this to show the reminder in the Agent overlay.
    var onNotifyTrigger: ((String) -> Void)?

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("heartbeats.json")
        loadFromDisk()
    }

    #if DEBUG
    /// Testable initializer that uses a custom file path.
    init(fileURL: URL) {
        self.fileURL = fileURL
        loadFromDisk()
    }
    #endif

    func start() {
        requestNotificationPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndFire()
            }
        }
        // Also check immediately
        checkAndFire()
        logger.info("HeartbeatScheduler started with \(self.entries.count) entries")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Entry Management

    func add(_ entry: HeartbeatEntry) {
        entries.append(entry)
        saveToDisk()
        logger.info("Heartbeat added: \(entry.message) at \(entry.triggerAt)")
    }

    func remove(id: UUID) -> Bool {
        let count = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != count {
            saveToDisk()
            return true
        }
        return false
    }

    func listAll() -> [HeartbeatEntry] {
        entries.sorted { $0.triggerAt < $1.triggerAt }
    }

    // MARK: - Check & Fire

    private func checkAndFire() {
        let now = Date()
        var toRemove: [UUID] = []
        var toAdd: [HeartbeatEntry] = []

        for entry in entries where entry.triggerAt <= now {
            fire(entry)

            if let nextDate = nextScheduledDate(for: entry, after: now) {
                // Reschedule with new trigger time
                let updated = HeartbeatEntry(
                    id: entry.id,
                    triggerAt: nextDate,
                    repeatRule: entry.repeatRule,
                    action: entry.action,
                    message: entry.message,
                    context: entry.context,
                    createdAt: entry.createdAt
                )
                toRemove.append(entry.id)
                toAdd.append(updated)
            } else {
                // One-shot, remove
                toRemove.append(entry.id)
            }
        }

        if !toRemove.isEmpty || !toAdd.isEmpty {
            entries.removeAll { toRemove.contains($0.id) }
            entries.append(contentsOf: toAdd)
            saveToDisk()
        }
    }

    private func nextScheduledDate(for entry: HeartbeatEntry, after now: Date) -> Date? {
        guard let rule = entry.repeatRule else { return nil }
        guard var nextDate = nextTriggerDate(from: entry.triggerAt, rule: rule) else { return nil }

        var guardIterations = 0
        while nextDate <= now && guardIterations < 1024 {
            guard let advancedDate = nextTriggerDate(from: nextDate, rule: rule) else {
                return nil
            }
            nextDate = advancedDate
            guardIterations += 1
        }

        return nextDate > now ? nextDate : nil
    }

    private func fire(_ entry: HeartbeatEntry) {
        logger.info("Heartbeat fired: \(entry.action.rawValue) – \(entry.message)")

        switch entry.action {
        case .notify:
            if let handler = onNotifyTrigger {
                handler(entry.message)
            } else {
                // Fallback to system notification if no overlay handler is set
                sendNotification(title: "SpeakFlow", body: entry.message)
            }
        case .agent:
            onAgentTrigger?(entry.message)
        }
    }

    // MARK: - Repeat Rule

    private func nextTriggerDate(from date: Date, rule: String) -> Date? {
        let calendar = Calendar.current
        switch rule.lowercased() {
        case "daily":
            return calendar.date(byAdding: .day, value: 1, to: date)
        case "weekly":
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case "hourly":
            return calendar.date(byAdding: .hour, value: 1, to: date)
        default:
            // Try parsing as "Xm" (minutes) or "Xh" (hours)
            if rule.hasSuffix("m"), let mins = Int(rule.dropLast()) {
                return calendar.date(byAdding: .minute, value: mins, to: date)
            }
            if rule.hasSuffix("h"), let hrs = Int(rule.dropLast()) {
                return calendar.date(byAdding: .hour, value: hrs, to: date)
            }
            logger.warning("Unknown repeat rule: \(rule), treating as one-shot")
            return nil
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            } else {
                logger.info("Notification permission granted: \(granted)")
            }
        }
    }

    /// Public fallback used when an agent heartbeat fires but user is already in a session.
    func sendNotificationFallback(title: String, body: String) {
        sendNotification(title: title, body: body)
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Fire immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(HeartbeatFile.self, from: data)
            entries = file.entries
            logger.info("Loaded \(self.entries.count) heartbeats from disk")
        } catch {
            logger.error("Failed to load heartbeats: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        let file = HeartbeatFile(entries: entries)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save heartbeats: \(error.localizedDescription)")
        }
    }
}
