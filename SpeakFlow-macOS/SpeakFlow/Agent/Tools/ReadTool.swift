import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ReadTool")

final class ReadTool: AgentTool {
    let name = "read"
    let description = "Read file contents. Returns content with line numbers (like cat -n). Supports optional offset and limit for reading specific line ranges."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "Absolute path to the file to read"
            ],
            "offset": [
                "type": "integer",
                "description": "Line number to start reading from (1-based). Optional."
            ],
            "limit": [
                "type": "integer",
                "description": "Maximum number of lines to read. Optional."
            ]
        ],
        "required": ["file_path"]
    ]

    private let maxOutputLength = 10_000

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let filePath = args["file_path"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'file_path' parameter")
        }

        logger.info("Reading file: \(filePath)")
        let expandedPath = NSString(string: filePath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("File not found: \(filePath)")
            return "Error: File not found at \(filePath)"
        }

        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            logger.warning("File not readable: \(filePath)")
            return "Error: File is not readable at \(filePath)"
        }

        let content: String
        do {
            content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        } catch {
            logger.error("Failed to read file \(filePath): \(error.localizedDescription)")
            return "Error: Failed to read file: \(error.localizedDescription)"
        }

        let allLines = content.components(separatedBy: "\n")
        logger.info("File \(filePath) has \(allLines.count) lines, \(content.count) characters")
        let offset = (args["offset"] as? Int).map { max(1, $0) } ?? 1
        let limit = args["limit"] as? Int

        let startIndex = offset - 1
        guard startIndex < allLines.count else {
            return "Error: Offset \(offset) is beyond end of file (\(allLines.count) lines)"
        }

        let endIndex: Int
        if let limit = limit {
            endIndex = min(startIndex + limit, allLines.count)
        } else {
            endIndex = allLines.count
        }

        var result = ""
        for i in startIndex..<endIndex {
            let lineNum = String(format: "%6d", i + 1)
            result += "\(lineNum)\t\(allLines[i])\n"
        }

        if result.count > maxOutputLength {
            result = String(result.prefix(maxOutputLength)) + "\n... (truncated)"
        }

        return result
    }
}
