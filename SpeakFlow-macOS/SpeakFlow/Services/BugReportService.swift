import Foundation
import os

private let brLogger = Logger(subsystem: "com.speakflow", category: "BugReport")

final class BugReportService {
    static let shared = BugReportService()
    private let authService = AuthService.shared

    func submitBugReport(transcription: String) async throws {
        let token = try await authService.getValidToken()

        var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/bug-report")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["transcription": transcription]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProcessingError.invalidResponse
        }

        guard httpResponse.statusCode == 201 else {
            brLogger.error("Bug report failed: status=\(httpResponse.statusCode)")
            throw ProcessingError.serverError(httpResponse.statusCode)
        }

        brLogger.info("Bug report submitted successfully")
    }
}
