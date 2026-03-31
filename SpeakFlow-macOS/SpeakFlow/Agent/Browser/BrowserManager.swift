import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "BrowserManager")

/// Manages a dedicated headless Chrome instance for AI browser control.
/// Chrome runs with a persistent user-data-dir so login sessions survive restarts.
/// Ref: OpenClaw chrome.ts
final class BrowserManager {
    static let shared = BrowserManager()

    private let cdpPort: Int = 9222
    private var process: Process?
    private var loginProcess: Process?
    private var isStarting = false

    /// Persistent browser profile directory — cookies/localStorage survive restarts.
    var userDataDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.speakflow/browser/user-data"
    }

    var cdpURL: String { "http://127.0.0.1:\(cdpPort)" }
    var isRunning: Bool { process?.isRunning == true }

    private init() {}

    // MARK: - Lifecycle

    /// Start Chrome headless if not already running. Idempotent.
    func ensureRunning() async throws {
        if isRunning { return }

        // Check if something else is already on the CDP port
        if await isCDPReachable() {
            logger.info("CDP already reachable on port \(self.cdpPort), reusing")
            return
        }

        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        let execPath = try findChrome()
        logger.info("Found Chrome at: \(execPath)")

        // Ensure user-data-dir exists
        try FileManager.default.createDirectory(
            atPath: userDataDir,
            withIntermediateDirectories: true
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.arguments = [
            "--headless=new",
            "--remote-debugging-port=\(cdpPort)",
            "--user-data-dir=\(userDataDir)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-features=Translate,MediaRouter",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "--password-store=basic",
            "--disable-gpu",
            "--window-size=1280,900",
            "about:blank",
        ]
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            self.process = proc
            logger.info("Chrome launched, PID=\(proc.processIdentifier)")
        } catch {
            logger.error("Failed to launch Chrome: \(error.localizedDescription)")
            throw BrowserError.launchFailed(error.localizedDescription)
        }

        // Wait for CDP to become reachable
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await isCDPReachable() {
                logger.info("CDP ready on port \(self.cdpPort)")
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        stop()
        throw BrowserError.cdpTimeout
    }

    /// Stop the managed Chrome instance.
    /// Also kills any orphaned Chrome using our CDP port (e.g. from a previous app session).
    func stop() {
        // Try graceful termination of our tracked process
        if let proc = process, proc.isRunning {
            proc.terminate()
            logger.info("Chrome terminated (tracked process)")
        }
        process = nil

        // Also kill any Chrome using our CDP port (handles orphaned processes from previous launches)
        killChromeOnCDPPort()
    }

    /// Find and kill any Chrome process using our remote-debugging-port.
    private func killChromeOnCDPPort() {
        let finder = Process()
        finder.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        finder.arguments = ["-f", "remote-debugging-port=\(cdpPort)"]
        let pipe = Pipe()
        finder.standardOutput = pipe
        finder.standardError = FileHandle.nullDevice
        do {
            try finder.run()
            finder.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let pids = output.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                kill(Int32(pid), SIGTERM)
                logger.info("Killed orphaned Chrome PID=\(pid)")
            }
            if !pids.isEmpty {
                // Give Chrome a moment to shut down and release the profile lock
                Thread.sleep(forTimeInterval: 1.0)
            }
        } catch {
            logger.warning("Failed to search for orphaned Chrome: \(error.localizedDescription)")
        }
    }

    /// Open a visible Chrome window for user login, sharing the same profile.
    /// Must stop headless Chrome first since the profile directory is locked by it.
    /// After the user finishes logging in, call `closeLoginWindow()` then `ensureRunning()`
    /// to restart headless mode with the updated session cookies.
    func openLoginWindow(url: String) throws {
        // Stop headless Chrome to release the profile lock
        stop()

        let execPath = try findChrome()
        let loginProc = Process()
        loginProc.executableURL = URL(fileURLWithPath: execPath)
        loginProc.arguments = [
            "--user-data-dir=\(userDataDir)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--password-store=basic",
            "--window-size=1280,900",
            url,
        ]
        loginProc.environment = ProcessInfo.processInfo.environment
        try loginProc.run()
        self.loginProcess = loginProc
        logger.info("Opened login window for: \(url) (headless stopped, visible Chrome started)")
    }

    /// Close the visible login Chrome gracefully, waiting for cookies to flush to disk.
    func closeLoginWindow() {
        guard let proc = loginProcess, proc.isRunning else {
            loginProcess = nil
            return
        }

        // Send SIGTERM and wait for graceful shutdown (Chrome flushes cookies on clean exit)
        proc.terminate()
        proc.waitUntilExit()
        logger.info("Login Chrome exited (code=\(proc.terminationStatus))")
        loginProcess = nil

        // Extra safety: wait for profile lock file to be released
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Chrome Detection (macOS)

    /// Find Chrome executable on macOS. Ref: OpenClaw chrome.executables.ts
    private func findChrome() throws -> String {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw BrowserError.chromeNotFound
    }

    // MARK: - CDP Health Check

    func isCDPReachable() async -> Bool {
        guard let url = URL(string: "\(cdpURL)/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Errors

enum BrowserError: LocalizedError {
    case chromeNotFound
    case launchFailed(String)
    case cdpTimeout
    case notRunning
    case connectionFailed(String)
    case actionFailed(String)
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            return "Chrome not found. Please install Google Chrome."
        case .launchFailed(let msg):
            return "Failed to launch browser: \(msg)"
        case .cdpTimeout:
            return "Browser failed to start within 10 seconds."
        case .notRunning:
            return "Browser is not running. Use action 'navigate' to start it."
        case .connectionFailed(let msg):
            return "Browser connection failed: \(msg)"
        case .actionFailed(let msg):
            return "Browser action failed: \(msg)"
        case .elementNotFound(let ref):
            return "Element '\(ref)' not found. Run a new snapshot to get current refs."
        }
    }
}
