import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "WriteTool")

final class WriteTool: AgentTool {
    let name = "write"
    let description = "Write content to a file. Creates intermediate directories if needed. Overwrites existing file."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "Absolute path to the file to write"
            ],
            "content": [
                "type": "string",
                "description": "The content to write to the file"
            ]
        ],
        "required": ["file_path", "content"]
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let filePath = args["file_path"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'file_path' parameter")
        }
        guard let content = args["content"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'content' parameter")
        }

        logger.info("Writing file: \(filePath) (\(content.count) characters)")
        let expandedPath = NSString(string: filePath).expandingTildeInPath
        let directory = (expandedPath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            try content.write(toFile: expandedPath, atomically: true, encoding: .utf8)
            logger.info("Successfully wrote \(content.count) characters to \(filePath)")
            return "Successfully wrote \(content.count) characters to \(filePath)"
        } catch {
            logger.error("Failed to write file \(filePath): \(error.localizedDescription)")
            return "Error: Failed to write file: \(error.localizedDescription)"
        }
    }
}
