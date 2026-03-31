import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BrowserTool")

/// Single unified browser tool for AI agent.
/// Actions: navigate, snapshot, click, type, press, screenshot, tabs, login.
/// Ref: OpenClaw browser-tool.ts (single tool with action enum, not separate tools)
final class BrowserTool: AgentTool {
    let name = "browser"
    let description = """
        Control the SpeakFlow browser (persistent Chrome instance with saved login sessions).
        Workflow: navigate → snapshot (get element refs like e1, e2) → click/type using refs → snapshot again to verify.
        Use snapshot (fast, text) instead of screenshot (slow, image) for navigation.
        When you need to log in to a site, use action "login" to open a visible browser window for the user.
        """

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["navigate", "snapshot", "click", "type", "press", "screenshot", "tabs", "login"],
                "description": "The browser action to perform",
            ],
            "url": [
                "type": "string",
                "description": "URL for navigate/login actions",
            ],
            "ref": [
                "type": "string",
                "description": "Element ref from snapshot (e.g. 'e3') for click/type actions",
            ],
            "text": [
                "type": "string",
                "description": "Text to type for type action",
            ],
            "key": [
                "type": "string",
                "description": "Key name for press action (e.g. 'Enter', 'Tab', 'Escape')",
            ],
            "submit": [
                "type": "boolean",
                "description": "Press Enter after typing (default: false)",
            ],
        ],
        "required": ["action"],
    ]

    private let cdp = BrowserCDP()

    /// Current ref map from the last snapshot — used for click/type actions.
    private var currentRefMap = BrowserSnapshot.RefMap()

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let action = args["action"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'action' parameter")
        }

        // Auto-start browser and connect CDP for any action except login
        if action != "login" {
            try await ensureConnected()
        }

        switch action {
        case "navigate":
            return try await actionNavigate(args: args)
        case "snapshot":
            return try await actionSnapshot()
        case "click":
            return try await actionClick(args: args)
        case "type":
            return try await actionType(args: args)
        case "press":
            return try await actionPress(args: args)
        case "screenshot":
            return try await actionScreenshot()
        case "tabs":
            return try await actionTabs()
        case "login":
            return try await actionLogin(args: args)
        default:
            throw AgentToolError.invalidArguments("Unknown action: \(action)")
        }
    }

    // MARK: - Actions

    private func actionNavigate(args: [String: Any]) async throws -> String {
        guard let url = args["url"] as? String else {
            throw AgentToolError.invalidArguments("navigate requires 'url' parameter")
        }

        // Validate URL
        var targetURL = url
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            targetURL = "https://\(url)"
        }

        let result = try await BrowserActions.navigate(cdp: cdp, url: targetURL)
        // Auto-snapshot after navigation
        let (snapshot, refMap) = try await BrowserSnapshot.take(cdp: cdp)
        currentRefMap = refMap
        return "\(result)\n\n--- Page Snapshot ---\n\(snapshot)"
    }

    private func actionSnapshot() async throws -> String {
        let (snapshot, refMap) = try await BrowserSnapshot.take(cdp: cdp)
        currentRefMap = refMap
        return snapshot
    }

    private func actionClick(args: [String: Any]) async throws -> String {
        guard let ref = args["ref"] as? String else {
            throw AgentToolError.invalidArguments("click requires 'ref' parameter (e.g. 'e3')")
        }
        let result = try await BrowserActions.click(cdp: cdp, ref: ref, refMap: currentRefMap)
        // Auto-snapshot after click to show updated page
        let (snapshot, refMap) = try await BrowserSnapshot.take(cdp: cdp)
        currentRefMap = refMap
        return "\(result)\n\n--- Updated Snapshot ---\n\(snapshot)"
    }

    private func actionType(args: [String: Any]) async throws -> String {
        guard let ref = args["ref"] as? String else {
            throw AgentToolError.invalidArguments("type requires 'ref' parameter")
        }
        guard let text = args["text"] as? String else {
            throw AgentToolError.invalidArguments("type requires 'text' parameter")
        }
        let submit = args["submit"] as? Bool ?? false
        let result = try await BrowserActions.type(cdp: cdp, ref: ref, text: text, submit: submit, refMap: currentRefMap)

        if submit {
            // Wait a bit for page to react to submission
            try await Task.sleep(nanoseconds: 500_000_000)
            let (snapshot, refMap) = try await BrowserSnapshot.take(cdp: cdp)
            currentRefMap = refMap
            return "\(result)\n\n--- Updated Snapshot ---\n\(snapshot)"
        }
        return result
    }

    private func actionPress(args: [String: Any]) async throws -> String {
        guard let key = args["key"] as? String else {
            throw AgentToolError.invalidArguments("press requires 'key' parameter (e.g. 'Enter')")
        }
        return try await BrowserActions.press(cdp: cdp, key: key)
    }

    private func actionScreenshot() async throws -> String {
        return try await BrowserActions.screenshot(cdp: cdp)
    }

    private func actionTabs() async throws -> String {
        let targets = try await cdp.getTargets()
        if targets.isEmpty { return "No open tabs." }

        var lines: [String] = ["Open tabs:"]
        for (i, target) in targets.enumerated() {
            let title = target["title"] as? String ?? "(untitled)"
            let url = target["url"] as? String ?? ""
            let id = target["id"] as? String ?? ""
            lines.append("  \(i + 1). \(title)")
            lines.append("     url: \(url)")
            lines.append("     targetId: \(id)")
        }
        return lines.joined(separator: "\n")
    }

    private func actionLogin(args: [String: Any]) async throws -> String {
        let url = args["url"] as? String ?? "https://www.google.com"

        // Disconnect CDP since we're stopping headless Chrome
        await cdp.disconnect()

        try BrowserManager.shared.openLoginWindow(url: url)
        return """
            A visible Chrome window has been opened for the user to log in at: \(url)
            The headless browser has been stopped so the login window can use the same profile.
            Use the question tool to ask the user to confirm when they are done logging in.
            After the user confirms, use action "navigate" to restart the headless browser and go to the target page.
            The login session cookies will be preserved.
            """
    }

    // MARK: - Connection Management

    private func ensureConnected() async throws {
        // If a login window is open, close it first to release the profile lock
        BrowserManager.shared.closeLoginWindow()

        // Start headless Chrome if needed
        try await BrowserManager.shared.ensureRunning()

        // Connect CDP if needed
        if await !cdp.isConnected {
            try await cdp.connect()
        }
    }
}
