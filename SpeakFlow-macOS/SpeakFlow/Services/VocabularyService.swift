import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "VocabularyService")

struct VocabularyCandidate: Codable {
    let original: String
    let edited: String
    let source: String // "voice_correction" or "silent_reread"
    let fullContext: String?
    let timestamp: String
}

struct VocabularyCandidatesFile: Codable {
    var pending: [VocabularyCandidate]
}

struct VocabularyEntry: Codable {
    let correct: String
    let wrong: String
}

final class VocabularyService {
    static let shared = VocabularyService()

    private let fileManager = FileManager.default
    private let speakflowDir: URL
    private let candidatesURL: URL

    /// Cached Whisper prompt fetched from cloud
    private var cachedPrompt: String?

    private init() {
        let home = fileManager.homeDirectoryForCurrentUser
        speakflowDir = home.appendingPathComponent(".speakflow")
        candidatesURL = speakflowDir.appendingPathComponent("candidates.json")

        // Ensure directory exists
        try? fileManager.createDirectory(at: speakflowDir, withIntermediateDirectories: true)
    }

    // MARK: - Candidates (local)

    func addCandidate(original: String, edited: String, source: String, fullContext: String? = nil) {
        guard original != edited else { return }

        let candidate = VocabularyCandidate(
            original: original,
            edited: edited,
            source: source,
            fullContext: fullContext,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        var file = loadCandidates()
        file.pending.append(candidate)
        saveCandidates(file)
        logger.info("Added candidate: '\(original)' → '\(edited)' [\(source)]")
    }

    func loadCandidates() -> VocabularyCandidatesFile {
        guard let data = try? Data(contentsOf: candidatesURL),
              let file = try? JSONDecoder().decode(VocabularyCandidatesFile.self, from: data) else {
            return VocabularyCandidatesFile(pending: [])
        }
        return file
    }

    func saveCandidates(_ file: VocabularyCandidatesFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: candidatesURL, options: .atomic)
    }

    func clearCandidates() {
        saveCandidates(VocabularyCandidatesFile(pending: []))
    }

    // MARK: - Vocabulary (cloud)

    /// Get the cached Whisper prompt. Call `syncVocabulary()` first to populate.
    func buildWhisperPrompt() -> String? {
        return cachedPrompt
    }

    /// Fetch vocabulary from cloud and cache the Whisper prompt.
    func syncVocabulary() async {
        do {
            let token = try await AuthService.shared.getValidToken()

            var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/vocabulary")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                logger.error("Failed to fetch vocabulary: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }

            struct VocabularyListResponse: Decodable {
                let prompt: String?
            }

            let result = try JSONDecoder().decode(VocabularyListResponse.self, from: data)
            cachedPrompt = result.prompt
            logger.info("Synced vocabulary, prompt: \(result.prompt ?? "nil")")
        } catch {
            logger.error("Failed to sync vocabulary: \(error.localizedDescription)")
        }
    }

    // MARK: - LLM Batch Processing

    /// Send pending candidates to the backend for LLM processing.
    /// Backend saves confirmed entries to DB.
    func processCandidatesBatch() async throws -> [VocabularyEntry] {
        let candidates = loadCandidates()
        guard !candidates.pending.isEmpty else { return [] }

        let token = try await AuthService.shared.getValidToken()

        var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/vocabulary/process")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(["candidates": candidates.pending])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logger.error("Vocabulary batch processing failed")
            throw ProcessingError.serverError((response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        struct BatchResponse: Decodable {
            let confirmed: [VocabularyEntry]
        }

        let result = try JSONDecoder().decode(BatchResponse.self, from: data)

        // Clear processed candidates
        clearCandidates()

        // Refresh cached prompt from cloud
        await syncVocabulary()

        logger.info("Batch processed: \(candidates.pending.count) candidates → \(result.confirmed.count) confirmed")
        return result.confirmed
    }

    /// Check if there are pending candidates to process.
    func hasPendingCandidates() -> Bool {
        let candidates = loadCandidates()
        return !candidates.pending.isEmpty
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
