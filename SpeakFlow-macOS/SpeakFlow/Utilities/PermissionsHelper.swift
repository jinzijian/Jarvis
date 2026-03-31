import AVFoundation
import Cocoa
import os.log
import ScreenCaptureKit
import UserNotifications

private let logger = Logger(subsystem: "com.speakflow", category: "PermissionsHelper")

enum PermissionsHelper {
    static var hasMicrophonePermission: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.info("Microphone permission status: \(String(describing: status.rawValue))")
        return status == .authorized
    }

    static func requestMicrophonePermission() async -> Bool {
        logger.info("Requesting microphone permission")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        logger.info("Microphone permission request result: \(granted)")
        return granted
    }

    static var hasAccessibilityPermission: Bool {
        let trusted = AXIsProcessTrusted()
        logger.info("Accessibility permission: \(trusted)")
        return trusted
    }

    static func promptAccessibilityPermission() {
        logger.info("Prompting for accessibility permission")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var hasScreenRecordingPermission: Bool {
        let granted = CGPreflightScreenCaptureAccess()
        logger.info("Screen recording permission: \(granted)")
        return granted
    }

    /// Check screen recording permission by reading the TCC database directly.
    /// CGPreflightScreenCaptureAccess() caches its result within a process,
    /// so we read the DB to detect when the user grants permission externally.
    static func checkScreenRecordingFromTCC() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath,
            "SELECT auth_value FROM access WHERE service='kTCCServiceScreenCapture' AND client='\(bundleID)' LIMIT 1;"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // auth_value 2 = allowed
            let granted = output == "2"
            logger.info("Screen recording TCC check: \(granted)")
            return granted
        } catch {
            logger.error("Screen recording TCC check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Relaunch the app.
    static func relaunchApp() {
        logger.info("Relaunching app")
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    static func promptScreenRecordingPermission() {
        logger.info("Prompting for screen recording permission")
        // Use ScreenCaptureKit to trigger the system prompt and register the app
        // in the Screen Recording list on modern macOS.
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                // Expected to fail if permission not yet granted — but it registers the app.
                logger.info("Screen recording prompt triggered (expected error if not yet granted)")
            }
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether the app is running from /Applications (not from a DMG or Downloads).
    static var isRunningFromApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications")
    }

    /// Open System Settings → Accessibility pane directly.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications Permission

    static func checkNotificationPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let granted = settings.authorizationStatus == .authorized
        logger.info("Notification permission: \(granted)")
        return granted
    }

    static func requestNotificationPermission() async -> Bool {
        logger.info("Requesting notification permission")
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            logger.info("Notification permission request result: \(granted)")
            return granted
        } catch {
            logger.error("Notification permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Automation (Apple Events) Permission

    /// Check if we have Automation permission for System Events by running a harmless command.
    /// Returns true if the command succeeds (permission granted), false otherwise.
    static func checkAutomationPermission() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to return name of first process whose frontmost is true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let granted = process.terminationStatus == 0
            logger.info("Automation permission: \(granted)")
            return granted
        } catch {
            logger.error("Automation permission check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Trigger the Automation permission prompt for System Events.
    /// macOS will show a dialog asking the user to allow SpeakFlow to control System Events.
    static func promptAutomationPermission() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"System Events\" to return name of first process whose frontmost is true"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Open System Settings → Automation pane.
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App Management Permission

    /// Check if App Management permission is granted by reading the TCC database.
    /// App Management (`kTCCServiceAppBundles`) allows the app to manage other apps (e.g. kill Chrome).
    static func checkAppManagementPermission() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath,
            "SELECT auth_value FROM access WHERE service='kTCCServiceAppBundles' AND client='\(bundleID)' LIMIT 1;"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let granted = output == "2"
            logger.info("App management permission: \(granted)")
            return granted
        } catch {
            logger.error("App management permission check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Open System Settings → App Management pane.
    static func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }
}
