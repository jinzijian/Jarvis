import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ViewFileTool")

final class ViewFileTool: AgentTool {
    let name = "view_file"
    let description = """
        View a PDF or image file by sending it to the model for analysis. \
        Supports: PDF (.pdf), images (.jpg, .jpeg, .png, .gif, .webp, .heic, .tiff, .bmp). \
        The model can read text, tables, charts, photos, scanned documents, etc. \
        Max file size: 20 MB. For plain text files, use the 'read' tool instead.
        """

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "Absolute path to the PDF or image file"
            ]
        ],
        "required": ["file_path"]
    ]

    private let maxFileSize = 20 * 1024 * 1024

    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "tif", "bmp"
    ]

    private let mimeTypes: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
        "tiff": "image/tiff",
        "tif": "image/tiff",
        "bmp": "image/bmp",
        "pdf": "application/pdf",
    ]

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let filePath = args["file_path"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'file_path' parameter")
        }

        logger.info("ViewFile reading: \(filePath)")
        let expandedPath = NSString(string: filePath).expandingTildeInPath
        let ext = (expandedPath as NSString).pathExtension.lowercased()
        let filename = (expandedPath as NSString).lastPathComponent

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("ViewFile file not found: \(filePath)")
            return "Error: File not found at \(filePath)"
        }

        guard mimeTypes[ext] != nil else {
            let supported = (imageExtensions.union(["pdf"])).sorted().joined(separator: ", ")
            logger.warning("ViewFile unsupported file type: .\(ext)")
            return "Error: Unsupported file type '.\(ext)'. Supported: \(supported). For text files, use the 'read' tool."
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: expandedPath),
              let fileSize = attrs[.size] as? Int else {
            logger.error("ViewFile cannot read file attributes: \(filePath)")
            return "Error: Cannot read file attributes"
        }

        logger.info("ViewFile \(filename): \(fileSize) bytes, type: \(ext)")

        if fileSize > maxFileSize {
            let sizeMB = Double(fileSize) / 1_048_576
            logger.warning("ViewFile file too large: \(String(format: "%.1f", sizeMB)) MB")
            return "Error: File is too large (\(String(format: "%.1f", sizeMB)) MB). Max: 20 MB."
        }

        guard let data = FileManager.default.contents(atPath: expandedPath) else {
            logger.error("ViewFile failed to read file data: \(filePath)")
            return "Error: Failed to read file"
        }

        let base64 = data.base64EncodedString()
        let mime = mimeTypes[ext]!

        // Return with special prefix that AgentLoop recognizes:
        // - "data:application/pdf;..." → handled as file content part
        // - "data:image/...;..."       → handled as image content part
        return "data:\(mime);name=\(filename);base64,\(base64)"
    }
}
