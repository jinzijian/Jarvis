import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "GlobTool")

final class GlobTool: AgentTool {
    let name = "glob"
    let description = "Search for files matching a glob pattern (e.g. \"**/*.swift\", \"src/**/*.ts\"). Returns matching file paths sorted by modification time."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "Glob pattern to match files (e.g. '**/*.swift', '*.txt')"
            ],
            "path": [
                "type": "string",
                "description": "Directory to search in. Defaults to current working directory."
            ]
        ],
        "required": ["pattern"]
    ]

    private let maxResults = 100

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let pattern = args["pattern"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'pattern' parameter")
        }

        logger.info("Glob search with pattern: \(pattern)")

        let searchPath: String
        if let path = args["path"] as? String {
            searchPath = NSString(string: path).expandingTildeInPath
        } else {
            searchPath = FileManager.default.currentDirectoryPath
        }

        guard FileManager.default.fileExists(atPath: searchPath) else {
            return "Error: Directory not found at \(searchPath)"
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: searchPath),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "Error: Failed to enumerate directory"
        }

        // Convert glob pattern to a simple matching function
        let fnmatchPattern = pattern.hasPrefix("**/")
            ? String(pattern.dropFirst(3))
            : pattern

        var matches: [(path: String, modified: Date)] = []

        while let nextObject = enumerator.nextObject() {
            guard let fileURL = nextObject as? URL else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: searchPath + "/", with: "")
            let fileName = fileURL.lastPathComponent

            // Match against full relative path or just filename
            let matched: Bool
            if pattern.contains("**/") || pattern.contains("/") {
                matched = fnmatchMatch(relativePath, pattern: pattern)
            } else {
                matched = fnmatchMatch(fileName, pattern: fnmatchPattern)
            }

            if matched {
                let modified = values.contentModificationDate ?? .distantPast
                matches.append((fileURL.path, modified))
            }

            if matches.count >= maxResults { break }
        }

        matches.sort { $0.modified > $1.modified }

        if matches.isEmpty {
            logger.info("Glob found 0 matches for pattern: \(pattern)")
            return "No files found matching pattern '\(pattern)' in \(searchPath)"
        }

        logger.info("Glob found \(matches.count) matches for pattern: \(pattern)")
        let lines = matches.map { $0.path }
        return lines.joined(separator: "\n")
    }

    /// Simple glob matching using fnmatch-style patterns.
    private func fnmatchMatch(_ string: String, pattern: String) -> Bool {
        // Convert glob pattern to regex
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*":
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    if i < pattern.endIndex && pattern[i] == "/" {
                        i = pattern.index(after: i)
                    }
                    continue
                } else {
                    regex += "[^/]*"
                }
            case "?":
                regex += "[^/]"
            case ".":
                regex += "\\."
            case "{":
                regex += "("
            case "}":
                regex += ")"
            case ",":
                regex += "|"
            default:
                regex += String(c)
            }
            i = pattern.index(after: i)
        }
        regex += "$"

        return (try? NSRegularExpression(pattern: regex))
            .flatMap { $0.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) } != nil
    }
}
