import Cocoa
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "TextInput")

final class TextInputService {
    private let axEditableAttribute = "AXEditable" as CFString

    /// The previously active app before recording started
    private var previousApp: NSRunningApplication?

    /// Save a reference to the frontmost app (call before recording starts)
    func saveFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }
        logger.info("Saved frontmost app: \(self.previousApp?.localizedName ?? "none", privacy: .public) (pid: \(self.previousApp?.processIdentifier ?? 0))")
    }

    /// Copy text to clipboard only (no paste simulation)
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Copied to clipboard (\(text.count) chars)")
    }

    /// Copy to clipboard, activate previous app, and simulate Cmd+V paste.
    /// Only call this when AXIsProcessTrusted() is true.
    func pasteText(_ text: String) {
        copyToClipboard(text)

        if let app = previousApp {
            logger.info("Activating \(app.localizedName ?? "unknown", privacy: .public) (pid: \(app.processIdentifier))")
            let activated = app.activate()
            logger.info("activate() returned: \(activated)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let current = NSWorkspace.shared.frontmostApplication
                logger.info("Current frontmost: \(current?.localizedName ?? "none", privacy: .public)")
                self.cgEventPaste()
            }
        } else {
            logger.info("No previous app — text is in clipboard, use Cmd+V")
        }
    }

    /// Returns true if a previous app was saved (regardless of text field detection).
    func hasPreviousApp() -> Bool {
        return previousApp != nil
    }

    /// Returns true when the previously active app still has a focused editable text control.
    func canInsertTextIntoPreviousApp() -> Bool {
        guard let app = previousApp else {
            logger.info("No previous app available for text insertion")
            return false
        }

        let canInsert = focusedElementAcceptsTextInput(pid: app.processIdentifier)
        logger.info("Previous app \(app.localizedName ?? "unknown", privacy: .public) accepts text input: \(canInsert)")
        return canInsert
    }

    /// Replace the currently selected text in the previous app.
    /// Tries AX API first (no clipboard pollution), falls back to Cmd+V.
    func replaceSelectedText(_ text: String) {
        if let app = previousApp {
            // Try AX API direct replacement first
            if replaceSelectedTextViaAX(text, pid: app.processIdentifier) {
                logger.info("Replaced selection via AX API")
                return
            }
            // Fallback: clipboard + Cmd+V (replaces selection in most editors)
            logger.warning("AX replace failed, falling back to Cmd+V")
            pasteText(text)
        } else {
            logger.info("No previous app — copying to clipboard")
            copyToClipboard(text)
        }
    }

    private func replaceSelectedTextViaAX(_ text: String, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue
        ) == .success, let focusedRaw = focusedValue else {
            return false
        }
        let element = focusedRaw as! AXUIElement
        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        return result == .success
    }

    private func focusedElementAcceptsTextInput(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedRaw = focusedValue else {
            return false
        }

        let element = focusedRaw as! AXUIElement

        if boolAttribute(axEditableAttribute, on: element) == true {
            return true
        }

        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success,
        selectedTextSettable.boolValue {
            return true
        }

        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &valueSettable
        ) == .success,
        valueSettable.boolValue {
            return true
        }

        if let role = stringAttribute(kAXRoleAttribute as CFString, on: element) {
            let editableRoles = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                kAXSearchFieldSubrole as String,
            ]
            if editableRoles.contains(role) {
                return true
            }
        }

        return false
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        if let boolNumber = value as? NSNumber {
            return boolNumber.boolValue
        }

        return nil
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Activate the previous app and return true if successful.
    func activatePreviousApp() -> Bool {
        guard let app = previousApp else {
            logger.info("No previous app to activate")
            return false
        }
        let activated = app.activate()
        logger.info("Activated \(app.localizedName ?? "unknown", privacy: .public): \(activated)")
        return activated
    }

    /// Type a string character by character using CGEvents.
    /// Much faster than clipboard paste for streaming — no Cmd+V needed.
    func typeText(_ text: String) {
        for char in text.unicodeScalars {
            let utf16 = Array(String(char).utf16)
            let source = CGEventSource(stateID: .hidSystemState)

            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    private func cgEventPaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            logger.error("Failed to create CGEvent for paste")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(50_000)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Pasted via CGEvent Cmd+V")
    }
}
