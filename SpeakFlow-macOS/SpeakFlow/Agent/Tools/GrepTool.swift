import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "GrepTool")

final class GrepTool: AgentTool {
    let name = "grep"
    let description = "Search file contents using a regular expression pattern. Returns matching lines with file paths and line numbers."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Regular expression pattern to search for"
            ],
            "path": [
                "type": "string",
                "description": "File or directory to search in. Defaults to current working directory."
            ]
        ],
        "required": ["pattern"]
    ]

    private let maxResults = 50
    private let maxOutputLength = 10_000

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let pattern = args["pattern"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'pattern' parameter")
        }

        logger.info("Grep search with pattern: \(pattern)")

        let searchPath: String
        if let path = args["path"] as? String {
            searchPath = NSString(string: path).expandingTildeInPath
        } else {
            searchPath = FileManager.default.currentDirectoryPath
        }

        let result = try await runGrep(pattern: pattern, path: searchPath)
        let lineCount = result.components(separatedBy: "\n").count
        logger.info("Grep completed for pattern: \(pattern), result lines: \(lineCount)")
        return result
    }

    private func runGrep(pattern: String, path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = ["-rn", "--include=*", "-m", String(maxResults), pattern, path]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { [maxOutputLength] _ in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                var output = String(data: data, encoding: .utf8) ?? ""

                if output.isEmpty {
                    output = "No matches found for pattern '\(pattern)' in \(path)"
                } else if output.count > maxOutputLength {
                    output = String(output.prefix(maxOutputLength)) + "\n... (truncated)"
                }

                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                logger.error("Failed to launch grep process: \(error.localizedDescription)")
                continuation.resume(returning: "Error: Failed to run grep: \(error.localizedDescription)")
            }
        }
    }
}
