import Foundation

final class LsTool: AgentTool {
    let name = "ls"
    let description = "List directory contents with file types and sizes."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "Directory path to list. Defaults to current working directory."
            ]
        ],
        "required": []
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)

        let dirPath: String
        if let path = args["path"] as? String {
            dirPath = NSString(string: path).expandingTildeInPath
        } else {
            dirPath = FileManager.default.currentDirectoryPath
        }

        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
            return "Error: Not a directory: \(dirPath)"
        }

        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: dirPath)
        } catch {
            return "Error: Failed to list directory: \(error.localizedDescription)"
        }

        if contents.isEmpty {
            return "(empty directory)"
        }

        var lines: [String] = []
        for name in contents.sorted() {
            let fullPath = (dirPath as NSString).appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &entryIsDir)

            if entryIsDir.boolValue {
                lines.append("\(name)/")
            } else {
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = attrs?[.size] as? Int64 ?? 0
                lines.append("\(name)  (\(formatSize(size)))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
