import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BrowserSnapshot")

/// Builds a text-based snapshot of the page using the Accessibility Tree (AX tree).
/// Each interactive element gets a ref (e1, e2, ...) that can be used in click/type actions.
/// Ref: OpenClaw pw-tools-core.snapshot.ts
struct BrowserSnapshot {
    /// Ref → CDP backendNodeId mapping for subsequent actions.
    struct RefMap {
        var refs: [String: Int] = [:]       // ref (e.g. "e1") → backendNodeId
        var nodeInfo: [String: NodeInfo] = [:] // ref → display info

        struct NodeInfo {
            let role: String
            let name: String
        }
    }

    /// Take a snapshot of the current page and return (text, refMap).
    static func take(cdp: BrowserCDP, maxChars: Int = 12000) async throws -> (String, RefMap) {
        // Get the full accessibility tree via CDP
        let result = try await cdp.send(method: "Accessibility.getFullAXTree", params: [:], timeout: 10)

        guard let nodes = result["nodes"] as? [[String: Any]] else {
            return ("(Empty page — no accessibility tree)", RefMap())
        }

        var refMap = RefMap()
        var refCounter = 1
        var lines: [String] = []
        var totalChars = 0

        // Get page info
        let pageInfo = try? await cdp.send(method: "Runtime.evaluate", params: [
            "expression": "JSON.stringify({title: document.title, url: location.href})",
            "returnByValue": true,
        ])
        if let pageValue = pageInfo?["result"] as? [String: Any],
           let pageStr = pageValue["value"] as? String,
           let pageData = pageStr.data(using: .utf8),
           let pageJSON = try? JSONSerialization.jsonObject(with: pageData) as? [String: String] {
            let title = pageJSON["title"] ?? ""
            let url = pageJSON["url"] ?? ""
            lines.append("[page] \(title)")
            lines.append("  url: \(url)")
            lines.append("")
        }

        // Process AX nodes into readable text with refs
        for node in nodes {
            guard totalChars < maxChars else {
                lines.append("... (snapshot truncated at \(maxChars) chars)")
                break
            }

            let role = extractStringProperty(node, name: "role") ?? ""
            let name = extractStringProperty(node, name: "name") ?? ""
            let value = extractStringProperty(node, name: "value")
            let description = extractStringProperty(node, name: "description")

            // Skip invisible/irrelevant nodes
            let ignored = extractBoolProperty(node, name: "hidden") == true
            if ignored { continue }

            // Skip structural-only nodes with no name
            let structuralRoles: Set<String> = [
                "none", "generic", "GenericContainer", "InlineTextBox",
                "LineBreak", "StaticText", "ignored", "Unknown",
            ]
            if structuralRoles.contains(role) && name.isEmpty { continue }

            // Determine indentation from node depth (use parentId chain length if available)
            let depth = nodeDepth(node, allNodes: nodes)
            let indent = String(repeating: "  ", count: min(depth, 6))

            // Interactive elements get a ref
            let isInteractive = interactiveRoles.contains(role)
            var ref = ""
            if isInteractive, let backendNodeId = node["backendDOMNodeId"] as? Int {
                let refKey = "e\(refCounter)"
                refCounter += 1
                refMap.refs[refKey] = backendNodeId
                refMap.nodeInfo[refKey] = RefMap.NodeInfo(role: role, name: name)
                ref = " \(refKey)"
            }

            // Build line
            var line = "\(indent)[\(role)\(ref)]"
            if !name.isEmpty {
                line += " \(name)"
            }
            if let value = value, !value.isEmpty, value != name {
                line += " value=\"\(value)\""
            }
            if let desc = description, !desc.isEmpty, desc != name {
                line += " — \(desc)"
            }

            lines.append(line)
            totalChars += line.count
        }

        let snapshot = lines.joined(separator: "\n")
        let interactiveCount = refMap.refs.count
        let footer = "\n\n[\(interactiveCount) interactive elements found. Use ref (e.g. e1) for click/type actions.]"

        logger.info("Snapshot: \(lines.count) lines, \(totalChars) chars, \(interactiveCount) interactive refs")
        return (snapshot + footer, refMap)
    }

    // MARK: - AX Tree Helpers

    private static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "TextField", "TextArea",
        "checkbox", "radio", "combobox", "ComboBox",
        "menuitem", "MenuItem", "MenuItemCheckBox", "MenuItemRadio",
        "tab", "Tab", "switch", "slider", "Slider",
        "spinbutton", "searchbox", "SearchField",
        "option", "ListBoxOption", "treeitem",
    ]

    private static func extractStringProperty(_ node: [String: Any], name: String) -> String? {
        // CDP AX nodes have properties as array of {name, value: {type, value}}
        if let properties = node["properties"] as? [[String: Any]] {
            for prop in properties {
                if prop["name"] as? String == name,
                   let val = prop["value"] as? [String: Any],
                   let str = val["value"] as? String {
                    return str
                }
            }
        }
        // Also check top-level role/name
        if name == "role", let role = node["role"] as? [String: Any] {
            return role["value"] as? String
        }
        if name == "name", let nameObj = node["name"] as? [String: Any] {
            return nameObj["value"] as? String
        }
        return nil
    }

    private static func extractBoolProperty(_ node: [String: Any], name: String) -> Bool? {
        if let properties = node["properties"] as? [[String: Any]] {
            for prop in properties {
                if prop["name"] as? String == name,
                   let val = prop["value"] as? [String: Any] {
                    return val["value"] as? Bool
                }
            }
        }
        if name == "hidden", let ignored = node["ignored"] as? Bool {
            return ignored
        }
        return nil
    }

    private static func nodeDepth(_ node: [String: Any], allNodes: [[String: Any]]) -> Int {
        // Simple heuristic: use parentId to count depth
        guard let parentId = node["parentId"] as? String else { return 0 }
        var depth = 1
        var currentParentId: String? = parentId
        var visited: Set<String> = []

        while let pid = currentParentId {
            if visited.contains(pid) { break }
            visited.insert(pid)
            if let parent = allNodes.first(where: { ($0["nodeId"] as? String) == pid }) {
                currentParentId = parent["parentId"] as? String
                depth += 1
                if depth > 10 { break }
            } else {
                break
            }
        }
        return depth
    }
}
