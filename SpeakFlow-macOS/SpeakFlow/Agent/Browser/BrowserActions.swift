import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BrowserActions")

/// Browser interaction actions via CDP. Uses refs from BrowserSnapshot.
/// Ref: OpenClaw pw-tools-core.interactions.ts
struct BrowserActions {

    // MARK: - Navigation

    /// Navigate to a URL.
    static func navigate(cdp: BrowserCDP, url: String) async throws -> String {
        let result = try await cdp.send(method: "Page.navigate", params: ["url": url], timeout: 15)
        // Wait for load
        _ = try? await cdp.send(method: "Page.enable", params: [:])
        try await waitForLoad(cdp: cdp, timeout: 10)
        let frameId = result["frameId"] as? String ?? "unknown"
        return "Navigated to \(url) (frame: \(frameId))"
    }

    // MARK: - Click

    /// Click an element by ref. Resolves ref → coordinates via CDP.
    static func click(cdp: BrowserCDP, ref: String, refMap: BrowserSnapshot.RefMap) async throws -> String {
        let nodeId = try resolveRef(ref: ref, refMap: refMap)

        // Get the element's bounding box
        let box = try await getElementBox(cdp: cdp, backendNodeId: nodeId)
        let x = box.x + box.width / 2
        let y = box.y + box.height / 2

        // Mouse click sequence
        try await cdp.send(method: "Input.dispatchMouseEvent", params: [
            "type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1,
        ])
        try await cdp.send(method: "Input.dispatchMouseEvent", params: [
            "type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1,
        ])

        // Brief wait for any navigation/rendering
        try await Task.sleep(nanoseconds: 300_000_000)

        let info = refMap.nodeInfo[ref]
        return "Clicked [\(info?.role ?? "element")] \"\(info?.name ?? ref)\""
    }

    // MARK: - Type

    /// Type text into an element by ref.
    static func type(cdp: BrowserCDP, ref: String, text: String, submit: Bool = false, refMap: BrowserSnapshot.RefMap) async throws -> String {
        let nodeId = try resolveRef(ref: ref, refMap: refMap)

        // Focus the element
        try await cdp.send(method: "DOM.focus", params: ["backendNodeId": nodeId])

        // Clear existing content
        try await cdp.send(method: "Runtime.evaluate", params: [
            "expression": """
                (function() {
                    const el = document.activeElement;
                    if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
                        el.value = '';
                        el.dispatchEvent(new Event('input', {bubbles: true}));
                    }
                })()
                """,
        ])

        // Type each character using insertText for better compatibility
        try await cdp.send(method: "Input.insertText", params: ["text": text])

        if submit {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await cdp.send(method: "Input.dispatchKeyEvent", params: [
                "type": "keyDown", "key": "Enter", "code": "Enter",
                "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13,
            ])
            try await cdp.send(method: "Input.dispatchKeyEvent", params: [
                "type": "keyUp", "key": "Enter", "code": "Enter",
                "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13,
            ])
        }

        let info = refMap.nodeInfo[ref]
        let preview = text.count > 30 ? String(text.prefix(30)) + "..." : text
        return "Typed \"\(preview)\" into [\(info?.role ?? "element")] \"\(info?.name ?? ref)\"\(submit ? " and submitted" : "")"
    }

    // MARK: - Press Key

    /// Press a keyboard key (Enter, Tab, Escape, ArrowDown, etc.)
    static func press(cdp: BrowserCDP, key: String) async throws -> String {
        let keyInfo = keyMap[key] ?? (key: key, code: key, keyCode: 0)
        try await cdp.send(method: "Input.dispatchKeyEvent", params: [
            "type": "keyDown", "key": keyInfo.key, "code": keyInfo.code,
            "windowsVirtualKeyCode": keyInfo.keyCode, "nativeVirtualKeyCode": keyInfo.keyCode,
        ])
        try await cdp.send(method: "Input.dispatchKeyEvent", params: [
            "type": "keyUp", "key": keyInfo.key, "code": keyInfo.code,
            "windowsVirtualKeyCode": keyInfo.keyCode, "nativeVirtualKeyCode": keyInfo.keyCode,
        ])
        return "Pressed key: \(key)"
    }

    // MARK: - Screenshot (via CDP)

    /// Take a screenshot of the current page, returns base64 PNG.
    static func screenshot(cdp: BrowserCDP) async throws -> String {
        let result = try await cdp.send(method: "Page.captureScreenshot", params: [
            "format": "jpeg",
            "quality": 75,
        ], timeout: 10)
        guard let data = result["data"] as? String else {
            throw BrowserError.actionFailed("Screenshot returned no data")
        }
        return "data:image/jpeg;base64,\(data)"
    }

    // MARK: - Wait for Load

    static func waitForLoad(cdp: BrowserCDP, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try? await cdp.send(method: "Runtime.evaluate", params: [
                "expression": "document.readyState",
                "returnByValue": true,
            ], timeout: 3)
            if let value = result?["result"] as? [String: Any],
               let state = value["value"] as? String,
               state == "complete" || state == "interactive" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Helpers

    private static func resolveRef(ref: String, refMap: BrowserSnapshot.RefMap) throws -> Int {
        guard let nodeId = refMap.refs[ref] else {
            throw BrowserError.elementNotFound(ref)
        }
        return nodeId
    }

    /// Get an element's bounding box in page coordinates.
    private static func getElementBox(cdp: BrowserCDP, backendNodeId: Int) async throws -> (x: Double, y: Double, width: Double, height: Double) {
        // Resolve to a remote object first
        let resolveResult = try await cdp.send(method: "DOM.resolveNode", params: [
            "backendNodeId": backendNodeId,
        ])
        guard let remoteObject = resolveResult["object"] as? [String: Any],
              let objectId = remoteObject["objectId"] as? String else {
            throw BrowserError.elementNotFound("Could not resolve node \(backendNodeId)")
        }

        // Get bounding rect via JS
        let evalResult = try await cdp.send(method: "Runtime.callFunctionOn", params: [
            "objectId": objectId,
            "functionDeclaration": """
                function() {
                    const rect = this.getBoundingClientRect();
                    return JSON.stringify({x: rect.x, y: rect.y, width: rect.width, height: rect.height});
                }
                """,
            "returnByValue": true,
        ])

        guard let resultValue = evalResult["result"] as? [String: Any],
              let jsonStr = resultValue["value"] as? String,
              let jsonData = jsonStr.data(using: .utf8),
              let rect = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Double],
              let x = rect["x"], let y = rect["y"],
              let w = rect["width"], let h = rect["height"] else {
            throw BrowserError.actionFailed("Could not get element bounding box")
        }

        return (x: x, y: y, width: w, height: h)
    }

    // MARK: - Key Map

    private static let keyMap: [String: (key: String, code: String, keyCode: Int)] = [
        "Enter": ("Enter", "Enter", 13),
        "Tab": ("Tab", "Tab", 9),
        "Escape": ("Escape", "Escape", 27),
        "Backspace": ("Backspace", "Backspace", 8),
        "Delete": ("Delete", "Delete", 46),
        "ArrowUp": ("ArrowUp", "ArrowUp", 38),
        "ArrowDown": ("ArrowDown", "ArrowDown", 40),
        "ArrowLeft": ("ArrowLeft", "ArrowLeft", 37),
        "ArrowRight": ("ArrowRight", "ArrowRight", 39),
        "Space": (" ", "Space", 32),
        "Home": ("Home", "Home", 36),
        "End": ("End", "End", 35),
        "PageUp": ("PageUp", "PageUp", 33),
        "PageDown": ("PageDown", "PageDown", 34),
    ]
}
