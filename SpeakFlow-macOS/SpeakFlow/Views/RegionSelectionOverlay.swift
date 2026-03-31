import Cocoa
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "RegionSelectionOverlay")

/// Borderless window subclass that can become key (required to receive keyboard events).
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen overlay that lets the user drag-select a region on a captured screenshot.
/// Used as a replacement for `screencapture -i -s` when using ScreenCaptureKit.
final class RegionSelectionOverlay {

    /// Show the overlay with a pre-captured full-screen image.
    /// Completion is called with cropped PNG data, or nil if cancelled.
    static func show(
        image: CGImage,
        screen: NSScreen,
        completion: @escaping (Data?) -> Void
    ) {
        let frame = screen.frame
        let window = KeyableWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RegionSelectionView(
            fullImage: image,
            screenFrame: frame
        ) { croppedData in
            window.orderOut(nil)
            completion(croppedData)
        }

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        // Activate our app so we receive key events (Escape)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - RegionSelectionView

private final class RegionSelectionView: NSView {

    private let fullImage: CGImage
    private let onComplete: (Data?) -> Void

    private var dragOrigin: NSPoint?
    private var currentRect: NSRect = .zero
    private var isDragging = false

    init(
        fullImage: CGImage,
        screenFrame: NSRect,
        onComplete: @escaping (Data?) -> Void
    ) {
        self.fullImage = fullImage
        self.onComplete = onComplete
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Draw the captured image as background (fill the entire view)
        ctx.draw(fullImage, in: bounds)

        // Semi-transparent dark overlay on top
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)

        if isDragging && currentRect.width > 0 && currentRect.height > 0 {
            // Clear the selected region to show the original image
            ctx.saveGState()
            ctx.clip(to: currentRect)
            ctx.draw(fullImage, in: bounds)
            ctx.restoreGState()

            // White border around selection
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(currentRect.insetBy(dx: -0.5, dy: -0.5))
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        isDragging = true
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)

        let x = min(origin.x, point.x)
        let y = min(origin.y, point.y)
        let w = abs(point.x - origin.x)
        let h = abs(point.y - origin.y)
        currentRect = NSRect(x: x, y: y, width: w, height: h)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false

        // Treat tiny selections as cancel
        if currentRect.width < 5 || currentRect.height < 5 {
            onComplete(nil)
            return
        }

        // Map view points to image pixels using actual image dimensions.
        // This avoids mismatches on mixed-DPI multi-display setups.
        let viewHeight = bounds.height
        let scaleX = CGFloat(fullImage.width) / bounds.width
        let scaleY = CGFloat(fullImage.height) / bounds.height

        var cropRect = CGRect(
            x: currentRect.origin.x * scaleX,
            y: (viewHeight - currentRect.origin.y - currentRect.height) * scaleY,
            width: currentRect.width * scaleX,
            height: currentRect.height * scaleY
        )
        cropRect = cropRect.intersection(
            CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        ).integral

        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = fullImage.cropping(to: cropRect) else {
            logger.error("Failed to crop image")
            onComplete(nil)
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cropped)
        let pngData = bitmap.representation(using: .png, properties: [:])
        onComplete(pngData)
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete(nil)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete(nil)
        }
    }
}
