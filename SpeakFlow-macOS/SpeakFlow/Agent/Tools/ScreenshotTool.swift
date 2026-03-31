import Cocoa
import ScreenCaptureKit
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "ScreenshotTool")

final class ScreenshotTool: AgentTool {
    let name = "screenshot"
    let description = "Capture a screenshot of the screen(s). Returns base64-encoded PNG image. Supports multi-monitor setups."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "display": [
                "type": "string",
                "description": "Which display to capture: \"all\" (stitch all screens, default), \"main\" (primary screen), \"mouse\" (screen under cursor), or a number (screen index starting from 0)",
                "default": "all"
            ]
        ],
        "required": [] as [String]
    ]

    /// Max dimension (width or height) for the output image to keep token usage reasonable.
    private let maxOutputDimension: CGFloat = 2560
    /// JPEG quality for output (0.0-1.0). JPEG is much smaller than PNG for screenshots.
    private let jpegQuality: CGFloat = 0.75

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        let display = args["display"] as? String ?? "all"

        let pngData: Data?

        switch display {
        case "main":
            pngData = await captureScreen(screen: NSScreen.main)
        case "mouse":
            let displayID = await MainActor.run { screenDisplayIDUnderMouse() }
            pngData = await captureScreen(screen: displayID.flatMap(screenForDisplayID(_:)))
        case "all":
            pngData = await captureAllScreens()
        default:
            // Numeric index
            if let index = Int(display) {
                let screens = NSScreen.screens
                guard index >= 0 && index < screens.count else {
                    return "Error: Screen index \(index) out of range. Available screens: 0..\(screens.count - 1)"
                }
                pngData = await captureScreen(screen: screens[index])
            } else {
                pngData = await captureAllScreens()
            }
        }

        guard let rawData = pngData else {
            return "Error: Failed to capture screenshot. Make sure Screen Recording permission is granted."
        }

        // Downsample and compress to JPEG to keep payload small for LLM
        let outputData = downsampleAndCompress(rawData)
        let base64 = outputData.base64EncodedString()
        let screens = NSScreen.screens
        let screenInfo = screens.enumerated().map { i, s in
            "Screen \(i): \(Int(s.frame.width))x\(Int(s.frame.height))"
        }.joined(separator: ", ")

        logger.info("Screenshot captured: raw=\(rawData.count) bytes, output=\(outputData.count) bytes, display=\(display), screens=[\(screenInfo)]")

        return "data:image/jpeg;base64,\(base64)"
    }

    /// Downsample if too large, then compress to JPEG.
    func downsampleAndCompress(_ pngData: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return pngData
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxDim = max(width, height)

        let targetImage: CGImage
        if maxDim > maxOutputDimension {
            let scale = maxOutputDimension / maxDim
            let newW = Int((width * scale).rounded())
            let newH = Int((height * scale).rounded())
            if let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                targetImage = ctx.makeImage() ?? cgImage
            } else {
                targetImage = cgImage
            }
        } else {
            targetImage = cgImage
        }

        let bitmap = NSBitmapImageRep(cgImage: targetImage)
        if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]) {
            return jpegData
        }
        return pngData
    }

    // MARK: - Capture Methods

    @MainActor
    private func screenDisplayIDUnderMouse() -> CGDirectDisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func screenForDisplayID(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    private func captureScreen(screen: NSScreen?) async -> Data? {
        guard let screen = screen else { return nil }

        if #available(macOS 14.0, *) {
            return await captureScreenSCK(screen: screen)
        } else {
            return captureScreenLegacy(screen: screen)
        }
    }

    /// Capture all screens and stitch them into a single image.
    private func captureAllScreens() async -> Data? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        if screens.count == 1 {
            return await captureScreen(screen: screens.first)
        }

        // Capture all screens in parallel
        let captures: [(NSScreen, Data)] = await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, screen) in screens.enumerated() {
                group.addTask {
                    let data = await self.captureScreen(screen: screen)
                    return (i, data)
                }
            }

            var results: [(Int, Data)] = []
            for await (index, data) in group {
                if let data = data {
                    results.append((index, data))
                }
            }
            results.sort { $0.0 < $1.0 }
            return results.map { (screens[$0.0], $0.1) }
        }

        guard !captures.isEmpty else { return nil }

        // Stitch images horizontally
        return stitchImages(captures)
    }

    // MARK: - ScreenCaptureKit (macOS 14+)

    @available(macOS 14.0, *)
    private func captureScreenSCK(screen: NSScreen) async -> Data? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                logger.warning("SCK display not found for ID \(displayID)")
                return nil
            }

            let filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: [],
                exceptingWindows: []
            )

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.scalesToFit = false
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        } catch {
            logger.error("SCK screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Legacy Fallback

    private func captureScreenLegacy(screen: NSScreen) -> Data? {
        guard let cgImage = CGWindowListCreateImage(
            screen.frame,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Image Stitching

    /// Stitch multiple screen captures into a single image, arranged by physical screen position.
    private func stitchImages(_ captures: [(NSScreen, Data)]) -> Data? {
        // Convert to CGImages with screen info
        var items: [(screen: NSScreen, image: CGImage)] = []
        for (screen, data) in captures {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }
            items.append((screen, cgImage))
        }

        guard !items.isEmpty else { return nil }

        // Compute the global bounding box from screen frames (in points).
        // NSScreen frames use bottom-left origin; we need to normalize.
        let allFrames = items.map { $0.screen.frame }
        let globalMinX = allFrames.map { $0.minX }.min()!
        let globalMinY = allFrames.map { $0.minY }.min()!
        let globalMaxX = allFrames.map { $0.maxX }.max()!
        let globalMaxY = allFrames.map { $0.maxY }.max()!

        // Use the max backing scale factor for output resolution
        let maxScale = items.map { $0.screen.backingScaleFactor }.max() ?? 2.0

        let totalWidth = Int((globalMaxX - globalMinX) * maxScale)
        let totalHeight = Int((globalMaxY - globalMinY) * maxScale)

        guard let context = CGContext(
            data: nil,
            width: totalWidth,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // Fill background black (for gaps between screens)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        // Draw each screen image at its correct position
        for item in items {
            let frame = item.screen.frame
            // Position relative to global origin, scaled to pixels
            let x = (frame.minX - globalMinX) * maxScale
            let y = (frame.minY - globalMinY) * maxScale
            let w = frame.width * maxScale
            let h = frame.height * maxScale

            context.draw(item.image, in: CGRect(x: x, y: y, width: w, height: h))
        }

        guard let stitchedImage = context.makeImage() else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: stitchedImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}
