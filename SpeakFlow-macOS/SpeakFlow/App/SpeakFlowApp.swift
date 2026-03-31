import Combine
import os.log
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "com.speakflow", category: "SpeakFlowApp")

@main
struct SpeakFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty WindowGroup — all UI is managed via NSWindow manually
        Settings { EmptyView() }
    }
}

/// Manual settings window controller (SwiftUI Settings scene doesn't work reliably in .accessory apps)
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(appState: AppState) {
        if let existing = window, existing.isVisible {
            logger.info("Settings window already visible, bringing to front")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        logger.info("Creating new settings window")

        let view = MainWindowView().environmentObject(appState)
        let hosting = NSHostingController(rootView: view)

        let w = NSWindow(contentViewController: hosting)
        w.title = "SpeakFlow"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 720, height: 500))
        w.minSize = NSSize(width: 620, height: 420)
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private let oauthService = OAuthService.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")
        // Set notification delegate so notifications show even when app is in foreground
        UNUserNotificationCenter.current().delegate = self

        // Strip quarantine attribute so Accessibility permissions work for downloaded builds
        Self.stripQuarantine()

        // Hide dock icon (backup — LSUIElement in Info.plist is primary)
        NSApp.setActivationPolicy(.accessory)

        // Register URL scheme handler for OAuth callback
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
        }

        // Build initial menu
        rebuildMenu()

        // Check existing auth
        checkExistingAuth()

        // Start hotkey listener and wire up the full flow
        appState.setup()

        // Show onboarding if first launch, otherwise show main window
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            OnboardingWindow.show(appState: appState)
        } else {
            SettingsWindow.show(appState: appState)
        }

        // Log permission status
        logger.info("Accessibility: \(AXIsProcessTrusted()), Microphone: \(!self.appState.needsMicrophone), Hotkey ready: \(self.appState.hotkeyReady)")

        // Observe state changes to update icon and menu
        appState.$appPhase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBarIcon()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        appState.$isLoggedIn
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        appState.$needsAccessibility
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        appState.$needsMicrophone
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        appState.$hasActiveSubscription
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Application will terminate")
        appState.teardown()
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        let menu = NSMenu()

        // --- Auth / Status Section ---
        if !appState.isLoggedIn {
            let googleItem = NSMenuItem(title: "Sign in with Google", action: #selector(signInWithGoogle), keyEquivalent: "")
            googleItem.target = self
            menu.addItem(googleItem)

            let emailItem = NSMenuItem(title: "Sign in with Email...", action: #selector(signInWithEmail), keyEquivalent: "")
            emailItem.target = self
            menu.addItem(emailItem)
        } else {
            // Status line with colored dot
            let statusItem = NSMenuItem()
            statusItem.attributedTitle = statusAttributedString()
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            if !appState.hasActiveSubscription {
                let upgradeItem = NSMenuItem(title: "Upgrade to Pro", action: #selector(openUpgrade), keyEquivalent: "")
                upgradeItem.target = self
                menu.addItem(upgradeItem)
            }

            menu.addItem(.separator())

            let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
            signOutItem.target = self
            menu.addItem(signOutItem)
        }

        // Permission warnings (always visible regardless of login state)
        if appState.needsAccessibility {
            let item = NSMenuItem(title: "⚠ Grant Accessibility Permission", action: #selector(grantAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        if appState.needsMicrophone {
            let item = NSMenuItem(title: "⚠ Grant Microphone Permission", action: #selector(grantMicrophone), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // --- Main Window ---
        let openItem = NSMenuItem(title: "Open SpeakFlow", action: #selector(openSettings), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        // Select Microphone submenu
        let micItem = NSMenuItem(title: "Select Microphone", action: nil, keyEquivalent: "")
        let micSubmenu = buildMicrophoneSubmenu()
        micItem.submenu = micSubmenu
        menu.addItem(micItem)

        menu.addItem(.separator())

        // --- Links Section ---
        let feedbackItem = NSMenuItem(title: "Feedback", action: #selector(openFeedback), keyEquivalent: "")
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        let homepageItem = NSMenuItem(title: "Open SpeakFlow Homepage", action: #selector(openHomepage), keyEquivalent: "")
        homepageItem.target = self
        menu.addItem(homepageItem)

        menu.addItem(.separator())

        // --- Version Section ---
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let versionItem = NSMenuItem(title: "Version \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit SpeakFlow", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func buildMicrophoneSubmenu() -> NSMenu {
        // Refresh available mics
        appState.refreshMicrophones()

        let submenu = NSMenu()
        let microphones = appState.availableMicrophones
        let selectedID = appState.selectedMicrophoneID

        if microphones.isEmpty {
            let noMic = NSMenuItem(title: "No microphones available", action: nil, keyEquivalent: "")
            noMic.isEnabled = false
            submenu.addItem(noMic)
        } else {
            for mic in microphones {
                let item = NSMenuItem(title: mic.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mic.id
                if mic.id == selectedID {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }

        return submenu
    }

    private func statusAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Colored dot
        let dotColor: NSColor
        let statusText: String

        switch appState.appPhase {
        case .idle:
            dotColor = .systemGreen
            statusText = "Ready — Option+Z to start/stop"
        case .recording:
            dotColor = .systemRed
            statusText = "Listening..."
        case .processing:
            dotColor = .systemOrange
            statusText = "Thinking..."
        case .done:
            dotColor = .systemBlue
            statusText = "Done"
        case .error:
            dotColor = .systemRed
            statusText = appState.lastError ?? "Error"
        }

        result.append(NSAttributedString(string: "\u{25CF} ", attributes: [
            .foregroundColor: dotColor,
            .font: NSFont.systemFont(ofSize: 13),
        ]))
        result.append(NSAttributedString(string: statusText, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13),
        ]))

        return result
    }

    // MARK: - URL Scheme Handler

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }
        logger.info("Received URL: \(urlString)")

        if url.scheme == "speakflow-callback" {
            NSApp.activate(ignoringOtherApps: true)
            // Store a backup handler so login always updates appState,
            // even if the original completion handler from the view is gone.
            let previousHandler = oauthService.onComplete
            oauthService.onComplete = { [weak self] result in
                previousHandler?(result)
                guard let self else { return }
                if case .success(let response) = result {
                    self.appState.isLoggedIn = true
                    self.appState.userEmail = response.user.email
                    KeychainService.shared.userEmail = response.user.email
                    self.appState.loadSubscription()
                }
            }
            oauthService.handleCallbackURL(url)
        }
    }

    // MARK: - Menu Actions

    @objc private func signInWithGoogle() {
        oauthService.startGoogleLogin { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.appState.isLoggedIn = true
                self.appState.userEmail = response.user.email
                KeychainService.shared.userEmail = response.user.email
                self.appState.loadSubscription()
                NSApp.activate(ignoringOtherApps: true)
                logger.info("Login successful: \(response.user.email)")
            case .failure(let error):
                logger.error("Google login failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func openUpgrade() {
        UpgradeWindow.show(appState: appState)
    }

    @objc private func signInWithEmail() {
        LoginWindow.show(appState: appState)
    }

    @objc private func grantAccessibility() {
        appState.requestAccessibility()
    }

    @objc private func grantMicrophone() {
        appState.requestMicrophone()
    }

    @objc private func signOut() {
        appState.performSignOut()
        logger.info("Signed out")
    }

    @objc private func openSettings() {
        SettingsWindow.show(appState: appState)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let micID = sender.representedObject as? String else { return }
        appState.selectMicrophone(id: micID)
    }

    @objc private func openFeedback() {
        if let url = URL(string: "https://github.com/alexjin/speakflow-macos/issues") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openHomepage() {
        if let url = URL(string: "https://github.com/anthropics/speakflow") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        if let url = URL(string: "https://github.com/alexjin/speakflow-macos/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Notifications

    /// Show notification banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle notification tap — bring app to front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindow.show(appState: self.appState)
        }
        completionHandler()
    }

    // MARK: - Helpers

    private func checkExistingAuth() {
        let keychain = KeychainService.shared
        guard keychain.accessToken != nil else { return }

        // Optimistically show as logged in while we validate
        appState.userEmail = keychain.userEmail
        appState.isLoggedIn = true
        // Restore cached subscription state immediately so UI doesn't flicker
        appState.hasActiveSubscription = UserDefaults.standard.bool(forKey: "cachedHasActiveSubscription")

        Task {
            do {
                // This will auto-refresh if expired
                _ = try await AuthService.shared.getValidToken()
                await MainActor.run {
                    self.appState.userEmail = keychain.userEmail
                }
                appState.loadSubscription()
            } catch AuthError.notLoggedIn {
                // Refresh token is definitively invalid — force re-login
                logger.warning("Session permanently expired, clearing")
                await MainActor.run {
                    if self.appState.isSubscriptionCacheFresh {
                        // Cache is fresh — keep subscription visible, just mark logged out
                        self.appState.isLoggedIn = false
                        self.appState.userEmail = nil
                        logger.info("Subscription cache still fresh, preserving")
                    } else {
                        self.appState.performSignOut()
                    }
                }
            } catch {
                // Network or transient error — keep user logged in with cached state
                logger.warning("Token validation failed (transient), keeping login: \(error.localizedDescription)")
            }
        }
    }

    /// Remove quarantine extended attribute from the app bundle so that
    /// macOS TCC allows granting Accessibility to ad-hoc signed builds
    /// downloaded from the internet.
    private static func stripQuarantine() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            logger.info("Stripped quarantine from \(bundlePath)")
        }
    }

    private func updateMenuBarIcon() {
        let image: NSImage?
        switch appState.appPhase {
        case .idle:
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            image = icon
        case .recording:
            image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "SpeakFlow")
        case .processing:
            image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: "SpeakFlow")
        case .done:
            image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "SpeakFlow")
        case .error:
            image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "SpeakFlow")
        }
        statusItem.button?.image = image
    }
}
