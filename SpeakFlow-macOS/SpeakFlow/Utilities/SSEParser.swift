import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "SSEParser")

enum SSEParser {
    enum Result {
        case token(String)
        case metadata(SSEMetadata)
        case done
        case skip
    }

    struct SSEMetadata {
        let transcription: String
        let result: String
    }

    static func parse(line: String) -> Result {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return .skip }
        let payload = String(trimmed.dropFirst(6))
        if payload == "[DONE]" {
            logger.info("SSE stream done")
            return .done
        }

        // Try to parse metadata JSON
        if payload.hasPrefix("{") {
            guard let data = payload.data(using: .utf8) else {
                logger.warning("Malformed SSE payload: unable to encode as UTF-8")
                return .token(payload)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["event"] as? String == "metadata",
               let transcription = json["transcription"] as? String,
               let result = json["result"] as? String {
                logger.info("Parsed SSE metadata event")
                return .metadata(SSEMetadata(transcription: transcription, result: result))
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                logger.warning("SSE JSON payload missing expected metadata fields: \(json.keys.joined(separator: ", "))")
            } else {
                logger.warning("Malformed SSE JSON payload")
            }
        }

        return .token(payload)
    }
}
