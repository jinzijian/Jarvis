import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AgentHistory")

struct AgentHistoryEntry: Codable, Identifiable {
    let id: UUID
    let command: String
    let result: String?
    let status: String  // "done", "error", "cancelled"
    let steps: [AgentHistoryStep]
    let elapsedTime: TimeInterval
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, command, result, status, steps
        case elapsedTime = "elapsed_time"
        case createdAt = "created_at"
    }
}

struct AgentHistoryStep: Codable {
    let title: String
    let status: String
    let detail: String?
}

final class AgentHistory {
    static let shared = AgentHistory()

    private let fileURL: URL
    private var entries: [AgentHistoryEntry] = []
    private let maxEntries = 100

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("agent_history.json")
        loadFromDisk()
    }

    func add(command: String, result: String?, status: String, steps: [StepItem], elapsedTime: TimeInterval) {
        let historySteps = steps.map { step in
            AgentHistoryStep(title: step.title, status: step.status.rawValue, detail: step.detail)
        }

        let entry = AgentHistoryEntry(
            id: UUID(),
            command: command,
            result: result,
            status: status,
            steps: historySteps,
            elapsedTime: elapsedTime,
            createdAt: Date()
        )

        entries.insert(entry, at: 0)

        // Keep only recent entries
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        saveToDisk()
    }

    func list(limit: Int = 20) -> [AgentHistoryEntry] {
        Array(entries.prefix(limit))
    }

    func clear() {
        entries.removeAll()
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([AgentHistoryEntry].self, from: data)
            logger.info("Loaded \(self.entries.count) history entries")
        } catch {
            logger.error("Failed to load agent history: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save agent history: \(error.localizedDescription)")
        }
    }
}
