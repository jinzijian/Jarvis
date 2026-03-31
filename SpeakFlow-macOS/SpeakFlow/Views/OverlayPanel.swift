import SwiftUI

@MainActor
class OverlayPanel {
    private(set) var panel: NSPanel?

    func dismiss() {
        panel?.close()
        panel = nil
    }

    func makePanel(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.nonactivatingPanel, .borderless, .fullSizeContentView],
        hasShadow: Bool = false
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = hasShadow
        panel.hidesOnDeactivate = false
        return panel
    }

    func present(_ panel: NSPanel) {
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func makeKeyIfNeeded() {
        panel?.makeKey()
    }

    func positionBottomCenter(_ panel: NSPanel) {
        // Use the screen where the mouse cursor is, not NSScreen.main
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let screen else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.minY + screenFrame.height * 0.25
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

}
