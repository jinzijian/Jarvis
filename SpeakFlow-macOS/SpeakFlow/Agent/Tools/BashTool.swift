import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BashTool")

private final class BashExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    func resumeOnce(
        with result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }

    func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer.append(data)
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrBuffer.append(data)
    }

    func bufferedOutput() -> (stdout: Data, stderr: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutBuffer, stderrBuffer)
    }
}

final class BashTool: AgentTool {
    let name = "bash"
    let description = "Execute a shell command via /bin/zsh. Timeout: 30 seconds. Dangerous commands (rm -rf, sudo, curl|sh, dd, mkfs) are blocked."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute"
            ]
        ],
        "required": ["command"]
    ]

    private static let dangerousPatterns: [String] = [
        #"rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|.*-rf\s+)"#,
        #"\bsudo\b"#,
        #"curl\s.*\|\s*(sh|bash|zsh)"#,
        #">\s*/dev/sd"#,
        #"mkfs\."#,
        #"dd\s+if="#
    ]

    private static let compiledPatterns: [NSRegularExpression] = {
        dangerousPatterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
    }()

    private let maxOutputLength = 10_000
    private let timeoutSeconds: TimeInterval = 30

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let command = args["command"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'command' parameter")
        }

        logger.info("Bash executing command: \(command)")

        if let blocked = matchesDangerousPattern(command) {
            logger.warning("Bash command blocked by security policy: \(blocked)")
            return "Error: Command blocked by security policy (matched: \(blocked)). If this is intentional, use the question tool to ask the user for confirmation first."
        }

        return try await runProcess(command: command)
    }

    private func matchesDangerousPattern(_ command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for (i, regex) in Self.compiledPatterns.enumerated() {
            if regex.firstMatch(in: command, range: range) != nil {
                return Self.dangerousPatterns[i]
            }
        }
        return nil
    }

    private func runProcess(command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = BashExecutionState()

            // Timeout
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
                logger.warning("Bash command timed out after \(self.timeoutSeconds)s")
                state.resumeOnce(with: .failure(AgentToolError.timeout), continuation: continuation)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutItem)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                state.appendStdout(data)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                state.appendStderr(data)
            }

            process.terminationHandler = { [maxOutputLength, timeoutSeconds] _ in
                logger.info("Bash command completed with exit code: \(process.terminationStatus)")
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let buffered = state.bufferedOutput()
                let stdoutData = buffered.stdout
                let stderrData = buffered.stderr

                var output = String(data: stdoutData, encoding: .utf8) ?? ""
                let errOutput = String(data: stderrData, encoding: .utf8) ?? ""

                if !errOutput.isEmpty {
                    output += (output.isEmpty ? "" : "\n") + errOutput
                }

                if output.count > maxOutputLength {
                    output = String(output.prefix(maxOutputLength)) + "\n... (truncated)"
                }

                if output.isEmpty {
                    output = "(no output)"
                }

                if Self.requiresUiVerification(command), output == "(no output)" {
                    output = "Command executed with no stdout. UI state is NOT verified yet."
                }

                state.resumeOnce(with: .success(output), continuation: continuation)
            }

            do {
                try process.run()
            } catch {
                logger.error("Bash failed to launch process: \(error.localizedDescription)")
                timeoutItem.cancel()
                state.resumeOnce(
                    with: .failure(AgentToolError.executionFailed(error.localizedDescription)),
                    continuation: continuation
                )
            }
        }
    }

    private static func requiresUiVerification(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("cliclick") || trimmed.contains("osascript")
    }
}
