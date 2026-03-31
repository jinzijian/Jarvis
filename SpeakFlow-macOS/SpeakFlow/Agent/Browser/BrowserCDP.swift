import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BrowserCDP")

/// Lightweight CDP (Chrome DevTools Protocol) client over WebSocket.
/// Handles command/response matching and event dispatching.
/// Ref: OpenClaw pw-session.ts
actor BrowserCDP {
    private var webSocket: URLSessionWebSocketTask?
    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var wsURL: String?
    private let session = URLSession(configuration: .default)

    /// Currently connected page target ID.
    private(set) var currentTargetId: String?

    // MARK: - Connection

    /// Connect to a page target's CDP WebSocket endpoint.
    /// Page-level commands (Page.navigate, DOM.*, Input.*, etc.) only work on
    /// page-level WebSocket connections, NOT the browser-level one from /json/version.
    func connect() async throws {
        // First, find an existing page target or create one
        let pageWSUrl = try await findOrCreatePageTarget()

        self.wsURL = pageWSUrl
        guard let wsURL = URL(string: pageWSUrl) else {
            throw BrowserError.connectionFailed("Invalid WebSocket URL: \(pageWSUrl)")
        }

        let ws = session.webSocketTask(with: wsURL)
        ws.resume()
        self.webSocket = ws
        logger.info("CDP WebSocket connected to page: \(pageWSUrl)")

        // Start receiving messages
        Task { await receiveLoop() }
    }

    /// Find an existing page target or create a new one, returning its WebSocket URL.
    private func findOrCreatePageTarget() async throws -> String {
        let listURL = "\(BrowserManager.shared.cdpURL)/json/list"
        guard let url = URL(string: listURL) else {
            throw BrowserError.connectionFailed("Invalid CDP URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        let targets = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []

        // Find first page target with a webSocketDebuggerUrl
        if let pageTarget = targets.first(where: { ($0["type"] as? String) == "page" }),
           let wsUrl = pageTarget["webSocketDebuggerUrl"] as? String {
            let targetId = pageTarget["id"] as? String
            currentTargetId = targetId
            logger.info("Reusing existing page target: \(targetId ?? "unknown")")
            return wsUrl
        }

        // No page target found — create one via /json/new
        let newURL = "\(BrowserManager.shared.cdpURL)/json/new?about:blank"
        guard let createURL = URL(string: newURL) else {
            throw BrowserError.connectionFailed("Invalid create target URL")
        }
        var createRequest = URLRequest(url: createURL)
        createRequest.httpMethod = "PUT"
        createRequest.timeoutInterval = 5
        let (createData, _) = try await URLSession.shared.data(for: createRequest)
        guard let newTarget = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let wsUrl = newTarget["webSocketDebuggerUrl"] as? String else {
            throw BrowserError.connectionFailed("Could not create new page target")
        }
        currentTargetId = newTarget["id"] as? String
        logger.info("Created new page target: \(self.currentTargetId ?? "unknown")")
        return wsUrl
    }

    /// Disconnect from CDP.
    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        for (_, cont) in pending {
            cont.resume(throwing: BrowserError.connectionFailed("Disconnected"))
        }
        pending.removeAll()
    }

    var isConnected: Bool { webSocket != nil }

    // MARK: - Commands

    /// Send a CDP command and wait for response.
    func send(method: String, params: [String: Any] = [:], timeout: TimeInterval = 8) async throws -> [String: Any] {
        guard let ws = webSocket else {
            throw BrowserError.connectionFailed("Not connected to CDP")
        }

        let id = nextId
        nextId += 1

        var message: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty {
            message["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: message)
        let text = String(data: data, encoding: .utf8)!

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation

            ws.send(.string(text)) { [weak self] error in
                if let error = error {
                    Task {
                        await self?.removePending(id: id)?.resume(
                            throwing: BrowserError.connectionFailed(error.localizedDescription)
                        )
                    }
                }
            }

            // Timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let cont = await self.removePending(id: id) {
                    cont.resume(throwing: AgentToolError.timeout)
                }
            }
        }
    }

    private func removePending(id: Int) -> CheckedContinuation<[String: Any], Error>? {
        pending.removeValue(forKey: id)
    }

    // MARK: - WebSocket Receive Loop

    private func receiveLoop() async {
        guard let ws = webSocket else { return }
        do {
            while true {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            logger.info("CDP WebSocket closed: \(error.localizedDescription)")
            disconnect()
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Response to a command
        if let id = json["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                cont.resume(throwing: BrowserError.actionFailed(message))
            } else {
                let result = json["result"] as? [String: Any] ?? [:]
                cont.resume(returning: result)
            }
        }
        // Events are ignored for now (can add listeners later)
    }

    // MARK: - Target Management

    /// Get list of available page targets.
    func getTargets() async throws -> [[String: Any]] {
        let url = URL(string: "\(BrowserManager.shared.cdpURL)/json/list")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return list.filter { ($0["type"] as? String) == "page" }
    }

    /// Connect to a specific page target by ID. Creates a new CDP session.
    func attachToTarget(_ targetId: String) async throws {
        let result = try await send(method: "Target.attachToTarget", params: [
            "targetId": targetId,
            "flatten": true,
        ])
        logger.info("Attached to target \(targetId): \(result)")
        currentTargetId = targetId
    }

    /// Create a new page target and return its targetId.
    func createTarget(url: String = "about:blank") async throws -> String {
        let result = try await send(method: "Target.createTarget", params: ["url": url])
        guard let targetId = result["targetId"] as? String else {
            throw BrowserError.actionFailed("No targetId returned from createTarget")
        }
        currentTargetId = targetId
        return targetId
    }
}
