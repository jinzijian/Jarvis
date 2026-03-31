import XCTest
import CoreGraphics
@testable import SpeakFlow

final class ScreenshotToolTests: XCTestCase {

    private let tool = ScreenshotTool()

    // MARK: - Downsample & Compress

    func test_downsample_large_image() {
        let pngData = createTestPNG(width: 5120, height: 2880)
        let result = tool.downsampleAndCompress(pngData)

        // Result should be JPEG (smaller) and dimensions reduced
        XCTAssertLessThan(result.count, pngData.count, "Compressed output should be smaller than raw PNG")

        // Verify output image dimensions
        if let source = CGImageSourceCreateWithData(result as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let width = props[kCGImagePropertyPixelWidth as String] as? Int,
           let height = props[kCGImagePropertyPixelHeight as String] as? Int {
            XCTAssertLessThanOrEqual(max(width, height), 2560, "Max dimension should be capped at 2560")
        }
    }

    func test_downsample_preserves_small_image() {
        let pngData = createTestPNG(width: 1000, height: 800)
        let result = tool.downsampleAndCompress(pngData)

        // Should still compress (PNG → JPEG) but not change dimensions
        if let source = CGImageSourceCreateWithData(result as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let width = props[kCGImagePropertyPixelWidth as String] as? Int,
           let height = props[kCGImagePropertyPixelHeight as String] as? Int {
            XCTAssertEqual(width, 1000)
            XCTAssertEqual(height, 800)
        }
    }

    func test_downsample_maintains_aspect_ratio() {
        // Wide image: 6000x1000
        let pngData = createTestPNG(width: 6000, height: 1000)
        let result = tool.downsampleAndCompress(pngData)

        if let source = CGImageSourceCreateWithData(result as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let width = props[kCGImagePropertyPixelWidth as String] as? Int,
           let height = props[kCGImagePropertyPixelHeight as String] as? Int {
            let ratio = Double(width) / Double(height)
            XCTAssertEqual(ratio, 6.0, accuracy: 0.1, "Aspect ratio should be preserved")
            XCTAssertLessThanOrEqual(width, 2560)
        }
    }

    func test_output_is_jpeg() {
        let pngData = createTestPNG(width: 800, height: 600)
        let result = tool.downsampleAndCompress(pngData)

        // JPEG files start with FF D8
        XCTAssertGreaterThanOrEqual(result.count, 2)
        let bytes = [UInt8](result.prefix(2))
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0xD8)
    }

    func test_invalid_data_returns_original() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let result = tool.downsampleAndCompress(garbage)
        XCTAssertEqual(result, garbage, "Should return original data if not a valid image")
    }

    // MARK: - Helpers

    private func createTestPNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            fatalError("Failed to create CGContext")
        }

        // Fill with a gradient so JPEG compression has real content
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0))
        context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))

        guard let cgImage = context.makeImage() else {
            fatalError("Failed to create CGImage")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Failed to create PNG data")
        }
        return pngData
    }
}

final class AgentLoopMessageSanitizerTests: XCTestCase {

    func test_sanitizeMessageSequence_reordersDisplacedToolResults() async {
        let call1 = AgentToolCall(
            id: "call_1",
            function: AgentFunctionCall(name: "screenshot", arguments: "{}")
        )
        let call2 = AgentToolCall(
            id: "call_2",
            function: AgentFunctionCall(name: "bash", arguments: "{}")
        )

        let messages = [
            AgentMessage(role: .system, content: "system"),
            AgentMessage(role: .user, content: "open gmail"),
            AgentMessage(role: .assistant, content: "checking screen", toolCalls: [call1, call2]),
            AgentMessage(role: .tool, content: "screenshot ok", toolCallId: call1.id),
            AgentMessage(role: .user, content: "deferred screenshot image"),
            AgentMessage(role: .tool, content: "opened gmail", toolCallId: call2.id),
        ]

        let sanitized = await AgentLoop.sanitizeMessageSequence(messages)

        XCTAssertEqual(sanitized.map(\.role.rawValue), ["system", "user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(sanitized[3].toolCallId, call1.id)
        XCTAssertEqual(sanitized[4].toolCallId, call2.id)
    }

    func test_sanitizeMessageSequence_insertsPlaceholderForMissingToolResult() async {
        let call1 = AgentToolCall(
            id: "call_1",
            function: AgentFunctionCall(name: "screenshot", arguments: "{}")
        )
        let call2 = AgentToolCall(
            id: "call_2",
            function: AgentFunctionCall(name: "bash", arguments: "{}")
        )

        let messages = [
            AgentMessage(role: .system, content: "system"),
            AgentMessage(role: .user, content: "open gmail"),
            AgentMessage(role: .assistant, content: "checking screen", toolCalls: [call1, call2]),
            AgentMessage(role: .tool, content: "screenshot ok", toolCallId: call1.id),
            AgentMessage(role: .user, content: "deferred screenshot image"),
        ]

        let sanitized = await AgentLoop.sanitizeMessageSequence(messages)

        XCTAssertEqual(sanitized.map(\.role.rawValue), ["system", "user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(sanitized[3].toolCallId, call1.id)
        XCTAssertEqual(sanitized[4].toolCallId, call2.id)
        XCTAssertEqual(sanitized[4].content?.textValue, "[Cancelled before execution]")
    }

    func test_sanitizeMessageSequence_dropsOrphanToolMessages() async {
        let messages = [
            AgentMessage(role: .system, content: "system"),
            AgentMessage(role: .user, content: "hello"),
            AgentMessage(role: .tool, content: "orphan", toolCallId: "call_orphan"),
        ]

        let sanitized = await AgentLoop.sanitizeMessageSequence(messages)

        XCTAssertEqual(sanitized.count, 2)
        XCTAssertEqual(sanitized.map(\.role.rawValue), ["system", "user"])
    }
}
