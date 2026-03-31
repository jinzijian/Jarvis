import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "WebFetchTool")

final class WebFetchTool: AgentTool {
    let name = "webfetch"
    let description = "Fetch a web page and return its content as plain text (HTML tags stripped). Timeout: 15 seconds."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "url": [
                "type": "string",
                "description": "The URL to fetch"
            ]
        ],
        "required": ["url"]
    ]

    private let maxOutputLength = 10_000
    private let timeoutSeconds: TimeInterval = 15

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let urlString = args["url"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'url' parameter")
        }

        logger.info("WebFetch starting for URL: \(urlString)")

        guard let url = URL(string: urlString) else {
            logger.warning("WebFetch invalid URL: \(urlString)")
            return "Error: Invalid URL: \(urlString)"
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            logger.error("WebFetch failed for \(urlString): \(error.localizedDescription)")
            return "Error: Failed to fetch URL: \(error.localizedDescription)"
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("WebFetch invalid response for \(urlString)")
            return "Error: Invalid response"
        }

        logger.info("WebFetch HTTP \(httpResponse.statusCode) for \(urlString)")

        guard (200...299).contains(httpResponse.statusCode) else {
            logger.warning("WebFetch non-success status \(httpResponse.statusCode) for \(urlString)")
            return "Error: HTTP \(httpResponse.statusCode)"
        }

        guard var text = String(data: data, encoding: .utf8) else {
            return "Error: Failed to decode response as text"
        }

        text = stripHTML(text)
        text = collapseWhitespace(text)

        if text.count > maxOutputLength {
            text = String(text.prefix(maxOutputLength)) + "\n... (truncated)"
        }

        logger.info("WebFetch completed for \(urlString), \(text.count) characters")
        return text
    }

    private func stripHTML(_ html: String) -> String {
        // Remove script and style blocks
        var result = html
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<head[^>]*>[\\s\\S]*?</head>"
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        // Remove remaining HTML tags
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
            result = tagRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        return result
    }

    private func collapseWhitespace(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
