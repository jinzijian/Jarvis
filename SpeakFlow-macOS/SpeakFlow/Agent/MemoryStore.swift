import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MemoryStore")

struct MemoryEntry: Codable, Identifiable {
    var id: String { key }
    let key: String
    var value: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
    }
}

struct MemoryFile: Codable {
    var memories: [MemoryEntry]
}

final class MemoryStore {
    static let shared = MemoryStore()

    private let fileURL: URL
    private var entries: [String: MemoryEntry] = [:]
    /// All reads and writes to `entries` go through this serial queue.
    private let queue = DispatchQueue(label: "com.speakflow.memory", qos: .utility)

    /// Hard limit on total number of stored memories.
    private let maxEntries = 500
    /// Max characters per value (truncated on save).
    private let maxValueLength = 2000

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakflow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("memory.json")
        queue.sync { _loadFromDisk() }
    }

    #if DEBUG
    /// Testable initializer that uses a custom file path.
    init(fileURL: URL) {
        self.fileURL = fileURL
        queue.sync { _loadFromDisk() }
    }
    #endif

    // MARK: - CRUD (thread-safe)

    func save(key: String, value: String) {
        let truncatedValue = value.count > maxValueLength
            ? String(value.prefix(maxValueLength))
            : value
        let entry = MemoryEntry(key: key, value: truncatedValue, updatedAt: Date())
        queue.sync {
            entries[key] = entry
            // Evict oldest entries if over limit
            if entries.count > maxEntries {
                let sorted = entries.values.sorted { $0.updatedAt < $1.updatedAt }
                let toRemove = sorted.prefix(entries.count - maxEntries)
                for old in toRemove {
                    entries.removeValue(forKey: old.key)
                }
            }
        }
        // Save to disk asynchronously (reads a snapshot under the lock)
        _saveToDiskAsync()
        logger.info("Memory saved: \(key)")
    }

    func get(key: String) -> MemoryEntry? {
        queue.sync { entries[key] }
    }

    func delete(key: String) -> Bool {
        let removed = queue.sync { entries.removeValue(forKey: key) != nil }
        if removed { _saveToDiskAsync() }
        return removed
    }

    func list() -> [MemoryEntry] {
        queue.sync {
            Array(entries.values).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func search(query: String) -> [MemoryEntry] {
        let q = query.lowercased()
        return list().filter {
            $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q)
        }
    }

    /// Build a string for injection into the system prompt.
    func systemPromptSection() -> String? {
        let all = list()
        guard !all.isEmpty else { return nil }

        // Only include most recent 50
        let subset = Array(all.prefix(50))
        var lines = ["## 用户记忆\n"]
        for entry in subset {
            // Truncate long values in prompt to keep token usage reasonable
            let displayValue = entry.value.count > 200
                ? String(entry.value.prefix(200)) + "..."
                : entry.value
            lines.append("- **\(entry.key)**: \(displayValue)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// Must be called on `queue`.
    private func _loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(MemoryFile.self, from: data)
            for entry in file.memories {
                entries[entry.key] = entry
            }
            logger.info("Loaded \(self.entries.count) memories from disk")
        } catch {
            logger.error("Failed to load memory: \(error.localizedDescription)")
        }
    }

    /// Snapshot entries under the lock, then write asynchronously.
    private func _saveToDiskAsync() {
        let snapshot = queue.sync { Array(self.entries.values) }
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            let file = MemoryFile(memories: snapshot)
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to save memory: \(error.localizedDescription)")
            }
        }
    }
}
