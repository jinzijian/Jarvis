import Cocoa
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "com.speakflow", category: "ScreenCapture")

final class ScreenCaptureService: @unchecked Sendable {

    // MARK: - Helpers

    /// Returns the screen containing the mouse cursor, falling back to main screen.
    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
    }

    private func screenForDisplayID(_ displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    // MARK: - Public API

    /// Capture the entire main screen. Returns PNG data.
    func captureFullScreen(completion: @escaping (Data?) -> Void) {
        if #available(macOS 14.0, *) {
            captureFullScreenSCK(completion: completion)
        } else {
            captureFullScreenLegacy(completion: completion)
        }
    }

    /// Launch region selection. Returns cropped PNG data, or nil if cancelled.
    func captureRegion(completion: @escaping (Data?) -> Void) {
        // Use native macOS region selection for maximum multi-display compatibility.
        captureRegionLegacy(completion: completion)
    }

    // MARK: - ScreenCaptureKit (macOS 14+)

    @available(macOS 14.0, *)
    private func captureFullScreenSCK(completion: @escaping (Data?) -> Void) {
        // Capture target screen on main thread before entering async context
        guard let targetScreen = screenUnderMouse(),
              let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            logger.error("Could not find display under mouse")
            completion(nil)
            return
        }
        let screenFrame = targetScreen.frame
        let backingScaleFactor = targetScreen.backingScaleFactor
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
                else {
                    logger.error("SCK display not found for ID \(displayID)")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let filter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: [],
                    exceptingWindows: []
                )

                let pixelWidth = Int((screenFrame.width * backingScaleFactor).rounded())
                let pixelHeight = Int((screenFrame.height * backingScaleFactor).rounded())
                let config = SCStreamConfiguration()
                config.width = pixelWidth
                config.height = pixelHeight
                config.scalesToFit = false
                config.showsCursor = false

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )

                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let pngData = bitmap.representation(using: .png, properties: [:])
                logger.info("Full screen captured: image=\(cgImage.width)x\(cgImage.height), config=\(pixelWidth)x\(pixelHeight), scale=\(backingScaleFactor) (\(pngData?.count ?? 0) bytes)")
                DispatchQueue.main.async { completion(pngData) }
            } catch {
                logger.error("Full screen capture failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    @available(macOS 14.0, *)
    private func captureRegionSCK(completion: @escaping (Data?) -> Void) {
        // Capture target screen on main thread before entering async context
        guard let targetScreen = screenUnderMouse(),
              let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            logger.error("Could not find display under mouse")
            completion(nil)
            return
        }
        let screenFrame = targetScreen.frame
        let backingScaleFactor = targetScreen.backingScaleFactor
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
                else {
                    logger.error("SCK display not found for ID \(displayID)")
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                let filter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: [],
                    exceptingWindows: []
                )

                let pixelWidth = Int((screenFrame.width * backingScaleFactor).rounded())
                let pixelHeight = Int((screenFrame.height * backingScaleFactor).rounded())
                let config = SCStreamConfiguration()
                config.width = pixelWidth
                config.height = pixelHeight
                config.scalesToFit = false
                config.showsCursor = false

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
                logger.info("Region source captured: image=\(cgImage.width)x\(cgImage.height), config=\(pixelWidth)x\(pixelHeight), scale=\(backingScaleFactor)")

                // Show region selection overlay on main thread
                DispatchQueue.main.async {
                    guard let screen = self.screenForDisplayID(displayID) else {
                        completion(nil)
                        return
                    }
                    RegionSelectionOverlay.show(image: cgImage, screen: screen, completion: completion)
                }
            } catch {
                logger.error("Region capture failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - Legacy (macOS < 14)

    private func captureFullScreenLegacy(completion: @escaping (Data?) -> Void) {
        guard let targetScreen = screenUnderMouse() else {
            logger.error("No display found under mouse")
            completion(nil)
            return
        }

        let displayBounds = CGRect(
            x: targetScreen.frame.origin.x,
            y: targetScreen.frame.origin.y,
            width: targetScreen.frame.width,
            height: targetScreen.frame.height
        )

        guard let cgImage = CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            logger.error("CGWindowListCreateImage returned nil")
            completion(nil)
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert capture to PNG")
            completion(nil)
            return
        }

        logger.info("Full screen captured (\(pngData.count) bytes)")
        completion(pngData)
    }

    private func captureRegionLegacy(completion: @escaping (Data?) -> Void) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", tempURL.path]

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    let data = try? Data(contentsOf: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)
                    logger.info("Region screenshot captured (\(data?.count ?? 0) bytes)")
                    completion(data)
                } else {
                    logger.info("User cancelled screenshot")
                    completion(nil)
                }
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch screencapture: \(error.localizedDescription)")
            completion(nil)
        }
    }
}
