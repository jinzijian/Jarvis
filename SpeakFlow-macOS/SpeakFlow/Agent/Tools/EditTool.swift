import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "EditTool")

final class EditTool: AgentTool {
    let name = "edit"
    let description = "Perform exact string replacement in a file. The old_string must be unique in the file unless replace_all is true."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "Absolute path to the file to edit"
            ],
            "old_string": [
                "type": "string",
                "description": "The exact string to find and replace"
            ],
            "new_string": [
                "type": "string",
                "description": "The replacement string"
            ],
            "replace_all": [
                "type": "boolean",
                "description": "If true, replace all occurrences. Default: false."
            ]
        ],
        "required": ["file_path", "old_string", "new_string"]
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let filePath = args["file_path"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'file_path' parameter")
        }
        guard let oldString = args["old_string"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'old_string' parameter")
        }
        guard let newString = args["new_string"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'new_string' parameter")
        }
        let replaceAll = args["replace_all"] as? Bool ?? false

        logger.info("Editing file: \(filePath) (replaceAll: \(replaceAll))")
        let expandedPath = NSString(string: filePath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("Edit target file not found: \(filePath)")
            return "Error: File not found at \(filePath)"
        }

        let content: String
        do {
            content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        } catch {
            logger.error("Failed to read file for edit \(filePath): \(error.localizedDescription)")
            return "Error: Failed to read file: \(error.localizedDescription)"
        }

        guard oldString != newString else {
            logger.warning("Edit old_string and new_string are identical")
            return "Error: old_string and new_string are identical"
        }

        guard content.contains(oldString) else {
            logger.warning("Edit old_string not found in \(filePath)")
            return "Error: old_string not found in file"
        }

        if !replaceAll {
            let occurrences = content.components(separatedBy: oldString).count - 1
            if occurrences > 1 {
                logger.warning("Edit old_string has \(occurrences) occurrences in \(filePath), expected unique match")
                return "Error: old_string appears \(occurrences) times in file. Provide more context to make it unique, or set replace_all to true."
            }
        }

        let newContent: String
        if replaceAll {
            newContent = content.replacingOccurrences(of: oldString, with: newString)
        } else {
            guard let range = content.range(of: oldString) else {
                return "Error: old_string not found in file"
            }
            newContent = content.replacingCharacters(in: range, with: newString)
        }

        do {
            try newContent.write(toFile: expandedPath, atomically: true, encoding: .utf8)
            let count = replaceAll ? content.components(separatedBy: oldString).count - 1 : 1
            logger.info("Edit replaced \(count) occurrence(s) in \(filePath)")
            return "Successfully replaced \(count) occurrence(s) in \(filePath)"
        } catch {
            logger.error("Failed to write edited file \(filePath): \(error.localizedDescription)")
            return "Error: Failed to write file: \(error.localizedDescription)"
        }
    }
}
