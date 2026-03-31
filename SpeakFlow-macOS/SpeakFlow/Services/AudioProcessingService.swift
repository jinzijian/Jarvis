import Foundation
import os

private let apLogger = Logger(subsystem: "com.speakflow", category: "AudioProcessing")

enum ProcessingError: LocalizedError {
    case unauthorized
    case noSubscription
    case rateLimited(retryAfter: Int)
    case dailyLimitExceeded
    case serverError(Int)
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Session expired. Please sign in again."
        case .noSubscription: return "Active subscription required."
        case .rateLimited(let sec): return "Too many requests. Retry in \(sec)s."
        case .dailyLimitExceeded: return "Daily usage limit reached."
        case .serverError(let code): return "Server error (\(code))"
        case .invalidResponse: return "Invalid server response"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

struct StreamingResult {
    let result: String
    let transcription: String?
}

final class AudioProcessingService {
    private let authService = AuthService.shared

    /// Send audio to the backend with streaming enabled.
    /// Calls `onToken` for each text chunk as it arrives.
    /// Returns the full accumulated result and Whisper transcription (from metadata).
    func processStreaming(
        fileURL: URL,
        language: String? = nil,
        contextText: String? = nil,
        contextImage: Data? = nil,
        useReasoning: Bool = false,
        vocabularyPrompt: String? = nil,
        onToken: @escaping (String) async -> Void
    ) async throws -> StreamingResult {
        let token = try await authService.getValidToken()

        let boundary = UUID().uuidString
        var request = URLRequest(url: buildURL(stream: true, language: language))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        apLogger.error("fileURL=\(fileURL.path, privacy: .public) audioData=\(audioData.count, privacy: .public) bytes filename=\(filename, privacy: .public)")

        var body = Data()

        // Audio part
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Context text part (optional)
        if let contextText = contextText {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"context_text\"\r\n\r\n")
            body.append(contextText)
            body.append("\r\n")
        }

        // Reasoning flag (optional)
        if useReasoning {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"reasoning_effort\"\r\n\r\n")
            body.append("medium")
            body.append("\r\n")
        }

        // Vocabulary prompt (optional)
        if let vocabPrompt = vocabularyPrompt {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"vocabulary_prompt\"\r\n\r\n")
            body.append(vocabPrompt)
            body.append("\r\n")
        }

        // Context image part (optional)
        if let imageData = contextImage {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"context_image\"; filename=\"screenshot.png\"\r\n")
            body.append("Content-Type: image/png\r\n\r\n")
            body.append(imageData)
            body.append("\r\n")
        }

        body.append("--\(boundary)--\r\n")
        request.httpBody = body
        apLogger.error("Request body=\(body.count, privacy: .public) bytes URL=\(request.url?.absoluteString ?? "nil", privacy: .public)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessingError.invalidResponse
        }

        apLogger.error("Response status=\(httpResponse.statusCode, privacy: .public)")

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            bytes.task.cancel()
            let newToken = try await authService.refresh().access_token
            request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await retryStreaming(request: request, onToken: { text in await onToken(text) })
        case 403:
            let bodyText = try await readErrorBody(from: bytes)
            apLogger.error("403 body: \(bodyText, privacy: .public)")
            if isSubscriptionDeniedMessage(bodyText) {
                throw ProcessingError.noSubscription
            }
            throw ProcessingError.serverError(403)
        case 429:
            let bodyText = try await readErrorBody(from: bytes)
            if bodyText.contains("Daily") || bodyText.contains("daily") {
                throw ProcessingError.dailyLimitExceeded
            }
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw ProcessingError.rateLimited(retryAfter: retryAfter)
        default:
            let bodyText = try await readErrorBody(from: bytes)
            apLogger.error("Error \(httpResponse.statusCode, privacy: .public) body: \(bodyText, privacy: .public)")
            throw ProcessingError.serverError(httpResponse.statusCode)
        }

        var accumulated = ""
        var transcription: String?
        for try await line in bytes.lines {
            switch SSEParser.parse(line: line) {
            case .token(let text):
                accumulated += text
                await onToken(text)
            case .metadata(let meta):
                transcription = meta.transcription
            case .done:
                break
            case .skip:
                continue
            }
        }

        return StreamingResult(result: accumulated, transcription: transcription)
    }

    private func retryStreaming(
        request: URLRequest,
        onToken: @escaping (String) async -> Void
    ) async throws -> StreamingResult {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProcessingError.unauthorized
        }

        var accumulated = ""
        var transcription: String?
        for try await line in bytes.lines {
            switch SSEParser.parse(line: line) {
            case .token(let text):
                accumulated += text
                await onToken(text)
            case .metadata(let meta):
                transcription = meta.transcription
            case .done:
                break
            case .skip:
                continue
            }
        }
        return StreamingResult(result: accumulated, transcription: transcription)
    }

    private func buildURL(stream: Bool, language: String?) -> URL {
        var components = URLComponents(string: "\(Constants.apiBaseURL)/process")!
        var items: [URLQueryItem] = []
        if stream { items.append(.init(name: "stream", value: "true")) }
        if let lang = language { items.append(.init(name: "language", value: lang)) }
        if !items.isEmpty { components.queryItems = items }
        return components.url!
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var bodyText = ""
        for try await line in bytes.lines {
            bodyText += line
        }
        return bodyText
    }

    private func isSubscriptionDeniedMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        let indicators = [
            "active subscription required",
            "subscription required",
            "no active subscription",
            "no subscription",
            "subscription not found",
            "subscription inactive",
            "subscription expired",
        ]
        return indicators.contains { lower.contains($0) }
    }
}

// MARK: - Data helper
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
