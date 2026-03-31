import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MCPClient")

enum MCPClientError: LocalizedError {
    case notConnected
    case processExited(Int32)
    case timeout
    case invalidResponse(String)
    case serverError(Int, String)
    case sseEndpointNotReceived

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP server not connected"
        case .processExited(let code): return "MCP server exited with code \(code)"
        case .timeout: return "MCP request timed out"
        case .invalidResponse(let msg): return "Invalid MCP response: \(msg)"
        case .serverError(let code, let msg): return "MCP error (\(code)): \(msg)"
        case .sseEndpointNotReceived: return "SSE endpoint event not received"
        }
    }
}

// MARK: - Transport Layer Protocol

protocol MCPTransportLayer: AnyObject, Sendable {
    func start() async throws
    func stop()
    func send(_ data: Data) throws
    var onMessage: (@Sendable (Data) -> Void)? { get set }
    var onClose: (@Sendable (Int32) -> Void)? { get set }
}

// MARK: - Stdio Transport

final class StdioTransport: MCPTransportLayer, @unchecked Sendable {
    var onMessage: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable (Int32) -> Void)?

    private let command: String
    private let args: [String]
    private let env: [String: String]?
    private let serverName: String

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var readBuffer = Data()
    private let queue = DispatchQueue(label: "com.speakflow.mcp.stdio")
    private var isStopping = false

    init(command: String, args: [String], env: [String: String]?, serverName: String) {
        self.command = command
        self.args = args
        self.env = env
        self.serverName = serverName
    }

    func start() async throws {
        let resolved = resolveCommand(command)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved.path)
        proc.arguments = resolved.prependArgs + args

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (key, value) in env {
                environment[key] = value
            }
        }
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let wasStopping = self.queue.sync {
                let v = self.isStopping
                self.isStopping = false
                return v
            }
            if !wasStopping {
                onClose?(p.terminationStatus)
            }
        }

        queue.sync { isStopping = false }

        do {
            try proc.run()
        } catch {
            throw MCPClientError.invalidResponse("Failed to start MCP server: \(error.localizedDescription)")
        }

        queue.sync {
            process = proc
            stdinHandle = stdinPipe.fileHandleForWriting
            stdoutHandle = stdoutPipe.fileHandleForReading
            stderrHandle = stderrPipe.fileHandleForReading
        }

        // Read stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.sync {
                self?.readBuffer.append(data)
                self?.processBuffer()
            }
        }

        // Log stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                logger.warning("MCP stderr [\(self?.serverName ?? "?")]: \(text)")
            }
        }

        logger.info("Stdio transport started for '\(self.serverName)' (pid \(proc.processIdentifier))")
    }

    func stop() {
        queue.sync { isStopping = true }
        let proc = queue.sync { () -> Process? in
            stdoutHandle?.readabilityHandler = nil
            stderrHandle?.readabilityHandler = nil
            stdinHandle?.closeFile()
            let p = process
            process = nil
            stdinHandle = nil
            stdoutHandle = nil
            stderrHandle = nil
            return p
        }
        proc?.terminate()
    }

    func send(_ data: Data) throws {
        try queue.sync {
            guard let handle = stdinHandle else { throw MCPClientError.notConnected }
            var framed = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            framed.append(data)
            try handle.write(contentsOf: framed)
        }
    }

    // MARK: - Buffer Processing

    private func processBuffer() {
        while let messageData = nextMessageFromBuffer() {
            guard !messageData.isEmpty else { continue }
            onMessage?(messageData)
        }
    }

    private func nextMessageFromBuffer() -> Data? {
        if readBuffer.starts(with: Data("Content-Length:".utf8)) {
            return nextFramedMessage()
        }
        if let lineMessage = nextLineMessage() {
            return lineMessage
        }
        return nextFramedMessage()
    }

    private func nextFramedMessage() -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = readBuffer.range(of: separator) else { return nil }

        let headerData = readBuffer.subdata(in: readBuffer.startIndex..<headerRange.lowerBound)
        guard let contentLength = parseContentLength(from: headerData) else {
            readBuffer.removeSubrange(readBuffer.startIndex..<headerRange.upperBound)
            return Data()
        }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength
        guard readBuffer.count >= bodyEnd else { return nil }

        let body = readBuffer.subdata(in: bodyStart..<bodyEnd)
        readBuffer.removeSubrange(readBuffer.startIndex..<bodyEnd)
        return body
    }

    private func nextLineMessage() -> Data? {
        guard let newlineRange = readBuffer.range(of: Data("\n".utf8)) else { return nil }
        var lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineRange.lowerBound)
        readBuffer.removeSubrange(readBuffer.startIndex...newlineRange.lowerBound)
        if lineData.last == UInt8(ascii: "\r") {
            lineData.removeLast()
        }
        return lineData
    }

    private func parseContentLength(from headerData: Data) -> Int? {
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        for line in headerText.components(separatedBy: "\r\n") {
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("content-length:") else { continue }
            let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
            if let value, let length = Int(value), length >= 0 {
                return length
            }
        }
        return nil
    }

    // MARK: - Command Resolution

    private func resolveCommand(_ command: String) -> (path: String, prependArgs: [String]) {
        if command.hasPrefix("/") {
            return (command, [])
        }

        let searchPaths: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            ProcessInfo.processInfo.environment["NVM_BIN"],
            ProcessInfo.processInfo.environment["HOME"].map { "\($0)/.nvm/versions/node" },
        ]
        .compactMap { $0 }
        .flatMap { dir -> [String] in
            if dir.hasSuffix("/.nvm/versions/node") {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                let sorted = contents.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                if let latest = sorted.first {
                    return ["\(dir)/\(latest)/bin"]
                }
                return []
            }
            return [dir]
        }

        for dir in searchPaths {
            let fullPath = "\(dir)/\(command)"
            if FileManager.default.fileExists(atPath: fullPath) {
                return (fullPath, [])
            }
        }

        return ("/usr/bin/env", [command])
    }
}

// MARK: - SSE Transport

final class SSETransport: MCPTransportLayer, @unchecked Sendable {
    var onMessage: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable (Int32) -> Void)?

    private let url: String
    private let headers: [String: String]?
    private let serverName: String

    private var session: URLSession?
    private var sseTask: Task<Void, Never>?
    private var endpointURL: URL?
    private let queue = DispatchQueue(label: "com.speakflow.mcp.sse")
    private var isStopping = false
    private let endpointReady = AsyncStream<URL>.makeStream()

    init(url: String, headers: [String: String]?, serverName: String) {
        self.url = url
        self.headers = headers
        self.serverName = serverName
    }

    func start() async throws {
        guard let sseURL = URL(string: url) else {
            throw MCPClientError.invalidResponse("Invalid SSE URL: \(url)")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 0
        let newSession = URLSession(configuration: config)
        queue.sync {
            session = newSession
            isStopping = false
        }

        var request = URLRequest(url: sseURL)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Start SSE listener in background
        sseTask = Task { [weak self] in
            await self?.listenSSE(session: newSession, request: request)
        }

        // Wait for endpoint event (with timeout)
        let endpoint: URL? = await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await url in self.endpointReady.stream {
                    return url
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        guard let endpoint else {
            stop()
            throw MCPClientError.sseEndpointNotReceived
        }

        queue.sync { endpointURL = endpoint }
        logger.info("SSE transport started for '\(self.serverName)', endpoint: \(endpoint.absoluteString)")
    }

    func stop() {
        queue.sync { isStopping = true }
        sseTask?.cancel()
        sseTask = nil
        queue.sync {
            session?.invalidateAndCancel()
            session = nil
            endpointURL = nil
        }
    }

    func send(_ data: Data) throws {
        guard let endpoint = queue.sync(execute: { endpointURL }),
              let session = queue.sync(execute: { session }) else {
            throw MCPClientError.notConnected
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        request.httpBody = data

        // Fire-and-forget POST; responses come back via SSE stream
        let task = session.dataTask(with: request) { [weak self] responseData, response, error in
            if let error {
                logger.warning("SSE POST error [\(self?.serverName ?? "?")]: \(error.localizedDescription)")
                return
            }
            // Some servers return JSON-RPC response inline on POST
            if let responseData, !responseData.isEmpty {
                self?.onMessage?(responseData)
            }
        }
        task.resume()
    }

    // MARK: - SSE Parsing

    private func listenSSE(session: URLSession, request: URLRequest) async {
        do {
            let (bytes, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("SSE connection failed with status \(statusCode) for '\(self.serverName)'")
                let wasStopping = queue.sync { isStopping }
                if !wasStopping { onClose?(-1) }
                return
            }

            var currentEvent = ""
            var currentData = ""

            for try await line in bytes.lines {
                if Task.isCancelled { break }

                if line.isEmpty {
                    // End of event — dispatch
                    if !currentData.isEmpty {
                        handleSSEEvent(event: currentEvent, data: currentData)
                    }
                    currentEvent = ""
                    currentData = ""
                    continue
                }

                if line.hasPrefix("event:") {
                    currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if currentData.isEmpty {
                        currentData = data
                    } else {
                        currentData += "\n" + data
                    }
                }
                // Ignore id:, retry:, comments (:)
            }
        } catch {
            if !Task.isCancelled {
                logger.warning("SSE stream error [\(self.serverName)]: \(error.localizedDescription)")
                let wasStopping = queue.sync { isStopping }
                if !wasStopping { onClose?(-1) }
            }
        }
    }

    private func handleSSEEvent(event: String, data: String) {
        if event == "endpoint" {
            // The data is a relative or absolute URL for POSTing JSON-RPC
            let endpointStr = data.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: URL?
            if endpointStr.hasPrefix("http://") || endpointStr.hasPrefix("https://") {
                resolved = URL(string: endpointStr)
            } else {
                // Relative to the SSE base URL
                resolved = URL(string: url).flatMap { URL(string: endpointStr, relativeTo: $0)?.absoluteURL }
            }
            if let resolved {
                endpointReady.continuation.yield(resolved)
                endpointReady.continuation.finish()
            }
            return
        }

        // event == "message" or default: treat data as JSON-RPC response
        if let messageData = data.data(using: .utf8) {
            onMessage?(messageData)
        }
    }
}

// MARK: - MCP Client

/// Communicates with a single MCP server over stdio or SSE JSON-RPC.
final class MCPClient: @unchecked Sendable {
    let config: MCPServerConfig
    private var _tools: [MCPToolInfo] = []
    private var _isConnected = false
    var onUnexpectedExit: (@Sendable (Int32) -> Void)?

    var tools: [MCPToolInfo] {
        queue.sync { _tools }
    }
    var isConnected: Bool {
        queue.sync { _isConnected }
    }

    private var transport: MCPTransportLayer?
    private var requestId = 0
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private let queue = DispatchQueue(label: "com.speakflow.mcp.client")

    init(config: MCPServerConfig) {
        self.config = config
    }

    deinit {
        disconnect()
    }

    // MARK: - Lifecycle

    func connect() async throws {
        let t: MCPTransportLayer
        switch config.transport {
        case .stdio(let command, let args, let env):
            t = StdioTransport(command: command, args: args, env: env, serverName: config.name)
        case .sse(let url, let headers):
            t = SSETransport(url: url, headers: headers, serverName: config.name)
        }

        t.onMessage = { [weak self] data in
            self?.handleResponseData(data)
        }
        t.onClose = { [weak self] status in
            self?.handleTransportClose(status: status)
        }

        try await t.start()

        queue.sync {
            transport = t
            _isConnected = true
        }

        logger.info("MCP server '\(self.config.name)' connected via \(self.config.transport.displayDescription)")

        // Initialize
        let _ = try await sendRequest(method: "initialize", params: [
            "protocolVersion": AnyCodable("2024-11-05"),
            "capabilities": AnyCodable([:] as [String: Any]),
            "clientInfo": AnyCodable(["name": "SpeakFlow", "version": "1.0"]),
        ])

        sendNotification(method: "notifications/initialized")
        try await refreshTools()
    }

    func disconnect() {
        let t = queue.sync { () -> MCPTransportLayer? in
            _isConnected = false
            let t = transport
            transport = nil
            return t
        }
        failPendingRequests(with: MCPClientError.notConnected)
        t?.stop()
    }

    // MARK: - Tools

    func refreshTools() async throws {
        let response = try await sendRequest(method: "tools/list", params: nil)
        guard let result = response.result else {
            queue.sync { _tools = [] }
            return
        }

        let data = try JSONSerialization.data(withJSONObject: result.value)
        let toolsResult = try JSONDecoder().decode(MCPToolsListResult.self, from: data)
        let newTools = toolsResult.tools
        queue.sync { _tools = newTools }
        logger.info("MCP '\(self.config.name)' has \(newTools.count) tools")
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let response = try await sendRequest(method: "tools/call", params: [
            "name": AnyCodable(name),
            "arguments": AnyCodable(arguments),
        ])

        if let error = response.error {
            throw MCPClientError.serverError(error.code, error.message)
        }

        guard let result = response.result else {
            return ""
        }

        let data = try JSONSerialization.data(withJSONObject: result.value)
        let callResult = try JSONDecoder().decode(MCPToolCallResult.self, from: data)

        if callResult.isError == true {
            let errorText = callResult.content.compactMap { $0.text }.joined(separator: "\n")
            throw MCPClientError.serverError(-1, errorText)
        }

        return callResult.content.compactMap { $0.text }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC

    private func sendRequest(method: String, params: [String: AnyCodable]?) async throws -> JSONRPCResponse {
        guard isConnected else { throw MCPClientError.notConnected }

        let id = queue.sync {
            requestId += 1
            return requestId
        }

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let payload = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let writeStarted = queue.sync { () -> Bool in
                pendingRequests[id] = continuation
                do {
                    try transport?.send(payload)
                    return true
                } catch {
                    let removed = pendingRequests.removeValue(forKey: id)
                    removed?.resume(throwing: error)
                    return false
                }
            }

            guard writeStarted else { return }

            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.queue.sync {
                    if let cont = self?.pendingRequests.removeValue(forKey: id) {
                        cont.resume(throwing: MCPClientError.timeout)
                    }
                }
            }
        }
    }

    private func sendNotification(method: String) {
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let data = try? JSONSerialization.data(withJSONObject: notification) {
            queue.sync {
                try? transport?.send(data)
            }
        }
    }

    // MARK: - Response Handling

    private func handleResponseData(_ data: Data) {
        queue.sync {
            do {
                let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
                if let id = response.id, let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                }
            } catch {
                logger.warning("Failed to parse MCP response: \(error.localizedDescription)")
            }
        }
    }

    private func handleTransportClose(status: Int32) {
        queue.sync {
            _isConnected = false
            transport = nil
        }
        failPendingRequests(with: MCPClientError.processExited(status))
        onUnexpectedExit?(status)
    }

    private func failPendingRequests(with error: MCPClientError) {
        let continuations = queue.sync {
            let continuations = Array(pendingRequests.values)
            pendingRequests.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
