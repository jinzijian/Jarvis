import Cocoa
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "Selection")

struct SelectionContext {
    let text: String
    let isEditable: Bool
    let sourceApp: NSRunningApplication?
}

final class SelectionService {
    /// Attempt to get the currently selected text from the frontmost application
    /// using the Accessibility API (AXUIElement).
    func getSelectedText() -> SelectionContext? {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility not trusted")
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        // Skip our own app
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused UI element
        var focusedValue: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusResult == .success, let focusedRaw = focusedValue else {
            logger.warning("Could not get focused element")
            return nil
        }
        let focusedElement = focusedRaw as! AXUIElement

        // Get selected text
        var selectedTextValue: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextValue
        )
        guard textResult == .success,
              let selectedText = selectedTextValue as? String,
              !selectedText.isEmpty else {
            logger.info("No selected text found")
            return nil
        }

        let isEditable = checkIfEditable(element: focusedElement)

        logger.info("Found selected text (\(selectedText.count) chars), editable=\(isEditable)")
        return SelectionContext(
            text: selectedText,
            isEditable: isEditable,
            sourceApp: frontApp
        )
    }

    /// Read text near the cursor from the frontmost app via Accessibility API.
    /// Best effort — returns nil if app doesn't support AX text reading.
    func readNearbyText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedValue: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusResult == .success, let focusedRaw = focusedValue else { return nil }
        let focusedElement = focusedRaw as! AXUIElement

        // Try to read the full value of the focused text element
        var valueResult: AnyObject?
        let valStatus = AXUIElementCopyAttributeValue(
            focusedElement, kAXValueAttribute as CFString, &valueResult
        )
        guard valStatus == .success, let fullText = valueResult as? String, !fullText.isEmpty else {
            return nil
        }

        // Get insertion point to extract nearby text
        var rangeValue: AnyObject?
        let rangeStatus = AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        )

        if rangeStatus == .success, let axRange = rangeValue {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(axRange as! AXValue, .cfRange, &cfRange) {
                let cursorPos = cfRange.location
                let textCount = fullText.count
                // Extract ~200 chars around cursor
                let start = max(0, cursorPos - 100)
                let end = min(textCount, cursorPos + 100)
                let startIdx = fullText.index(fullText.startIndex, offsetBy: start)
                let endIdx = fullText.index(fullText.startIndex, offsetBy: end)
                return String(fullText[startIdx..<endIdx])
            }
        }

        // Fallback: return last 200 chars
        if fullText.count > 200 {
            return String(fullText.suffix(200))
        }
        return fullText
    }

    private func checkIfEditable(element: AXUIElement) -> Bool {
        // Check role
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""

        // Known editable roles
        let editableRoles = ["AXTextField", "AXTextArea", "AXComboBox"]
        if editableRoles.contains(role) {
            // Exclude password fields
            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
            if (subroleValue as? String) == "AXSecureTextField" {
                return false
            }
            return true
        }

        // Check if value attribute is settable (works for custom text views, web contenteditable)
        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &isSettable
        )
        if settableResult == .success && isSettable.boolValue {
            return true
        }

        return false
    }
}
