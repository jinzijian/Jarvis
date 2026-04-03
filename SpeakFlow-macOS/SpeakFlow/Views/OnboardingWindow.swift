import SwiftUI

// MARK: - Onboarding Steps

private enum OnboardingStep: Int, CaseIterable {
    case permissions = 0
    case apiKey = 1
    case toolAuth = 2
}

// MARK: - Window Controller

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static weak var savedAppState: AppState?

    static func showIfNeeded(appState: AppState) {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        guard !hasCompletedOnboarding else { return }
        show(appState: appState)
    }

    static func show(appState: AppState) {
        savedAppState = appState

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView()
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: view)

        let w = NSWindow(contentViewController: hosting)
        w.title = "SpeakFlow Setup"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 720, height: 540))
        w.minSize = NSSize(width: 620, height: 460)
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }

    static func setWindowLevel(_ level: NSWindow.Level) {
        window?.level = level
    }

    static func closeAndShowSettings() {
        let appState = savedAppState
        window?.close()
        window = nil
        guard let appState = appState else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            SettingsWindow.show(appState: appState)
        }
    }
}

// MARK: - Main Onboarding View

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep: OnboardingStep = .permissions

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // Content
            Group {
                switch currentStep {
                case .permissions:
                    PermissionsStepView(onNext: { currentStep = .apiKey })
                case .apiKey:
                    APIKeyStepView(onNext: { currentStep = .toolAuth })
                case .toolAuth:
                    ToolAuthStepView(onDone: { finishOnboarding() })
                }
            }
        }
        .frame(width: 720, height: 540)
    }

    private var stepIndicator: some View {
        HStack(spacing: 24) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(stepColor(for: step))
                            .frame(width: 28, height: 28)
                        if step.rawValue < currentStep.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(step == currentStep ? .white : .secondary)
                        }
                    }
                    Text(stepLabel(for: step))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(step == currentStep ? .primary : .secondary)
                }
            }
        }
    }

    private func stepColor(for step: OnboardingStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return .green
        } else if step == currentStep {
            return .accentColor
        } else {
            return Color(nsColor: .separatorColor)
        }
    }

    private func stepLabel(for step: OnboardingStep) -> String {
        switch step {
        case .permissions: return "Permissions"
        case .apiKey: return "API Key"
        case .toolAuth: return "Connect Tools"
        }
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        appState.onOnboardingComplete()
        OnboardingWindow.closeAndShowSettings()
    }
}

// MARK: - Step 1: Permissions (unchanged)

private struct PermissionsStepView: View {
    var onNext: () -> Void

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var screenRecordingRequested = false
    @State private var automationGranted = false
    @State private var automationRequested = false
    @State private var notificationGranted = false
    @State private var pollTimer: Timer?

    private var runningFromDMG: Bool {
        !PermissionsHelper.isRunningFromApplications
    }

    private var allGranted: Bool {
        micGranted && accessibilityGranted && screenRecordingGranted && automationGranted && notificationGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text("Grant Permissions")
                            .font(.system(size: 17, weight: .bold))
                        Text("SpeakFlow needs these to work properly")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 16)

                    if runningFromDMG {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Move to Applications first")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Drag SpeakFlow.app to /Applications, then relaunch.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(8)
                        .padding(.horizontal, 20)
                    }

                    // Microphone
                    permissionRow(
                        title: "Microphone",
                        description: "Required for voice recording",
                        icon: "mic.fill",
                        granted: micGranted
                    ) {
                        Task {
                            micGranted = await PermissionsHelper.requestMicrophonePermission()
                        }
                    }

                    Divider().padding(.horizontal, 20)

                    // Accessibility
                    permissionRow(
                        title: "Accessibility",
                        description: "Required for global hotkey and auto-paste",
                        icon: "hand.raised.fill",
                        granted: accessibilityGranted
                    ) {
                        PermissionsHelper.promptAccessibilityPermission()
                    }

                    if !accessibilityGranted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("If SpeakFlow doesn't appear in the list:")
                                .font(.system(size: 11, weight: .medium))
                            Text("System Settings > Privacy & Security > Accessibility > click + > select SpeakFlow")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button("Open Accessibility Settings") {
                                PermissionsHelper.openAccessibilitySettings()
                            }
                            .font(.system(size: 11))
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 24)
                    }

                    Divider().padding(.horizontal, 20)

                    // Screen Recording
                    permissionRow(
                        title: "Screen Recording",
                        description: "Required for screenshot context features",
                        icon: "rectangle.dashed.badge.record",
                        granted: screenRecordingGranted
                    ) {
                        OnboardingWindow.setWindowLevel(.normal)
                        PermissionsHelper.promptScreenRecordingPermission()
                        PermissionsHelper.openScreenRecordingSettings()
                        screenRecordingRequested = true
                    }

                    if screenRecordingRequested && !screenRecordingGranted {
                        VStack(spacing: 8) {
                            Text("After enabling Screen Recording in Settings, please restart SpeakFlow.")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                            Button("Restart SpeakFlow") {
                                relaunchApp()
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 24)
                    }

                    Divider().padding(.horizontal, 20)

                    // Automation (System Events)
                    permissionRow(
                        title: "Automation",
                        description: "Required for agent to control apps (click, type, switch windows)",
                        icon: "gearshape.2.fill",
                        granted: automationGranted
                    ) {
                        PermissionsHelper.promptAutomationPermission()
                        automationRequested = true
                    }

                    if automationRequested && !automationGranted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Click \"OK\" on the system dialog to allow SpeakFlow to control System Events.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button("Open Automation Settings") {
                                PermissionsHelper.openAutomationSettings()
                            }
                            .font(.system(size: 11))
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 24)
                    }

                    if allGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("All permissions granted!")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                        }
                        .padding(.top, 4)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(allGranted ? "Next" : "Skip for Now") { onNext() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onAppear {
            micGranted = PermissionsHelper.hasMicrophonePermission
            accessibilityGranted = AXIsProcessTrusted()
            screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
            automationGranted = PermissionsHelper.checkAutomationPermission()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                DispatchQueue.main.async {
                    accessibilityGranted = AXIsProcessTrusted()
                    if !screenRecordingGranted && screenRecordingRequested {
                        let tccGranted = PermissionsHelper.checkScreenRecordingFromTCC()
                        if tccGranted {
                            PermissionsHelper.relaunchApp()
                            return
                        }
                    }
                    screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
                }
                if !automationGranted {
                    DispatchQueue.global(qos: .utility).async {
                        let granted = PermissionsHelper.checkAutomationPermission()
                        DispatchQueue.main.async {
                            automationGranted = granted
                        }
                    }
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        description: String,
        icon: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: granted ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 16))
                    .foregroundColor(granted ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button("Grant") { action() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Step 2: API Key

private struct APIKeyStepView: View {
    var onNext: () -> Void

    @State private var apiKey = ""
    @State private var isValidating = false
    @State private var isValid: Bool?
    @State private var statusMessage = ""
    @State private var isSaving = false
    @State private var existingKeyPreview: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text("OpenAI API Key")
                            .font(.system(size: 17, weight: .bold))
                        Text("SpeakFlow uses OpenAI for speech recognition and AI processing")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 16)

                    // Existing key indicator
                    if let preview = existingKeyPreview {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("API key configured: \(preview)")
                                .font(.system(size: 12))
                                .foregroundColor(.green)
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(8)
                        .padding(.horizontal, 40)
                    }

                    // Instructions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to get your API key:")
                            .font(.system(size: 12, weight: .semibold))

                        HStack(alignment: .top, spacing: 8) {
                            Text("1.")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Go to OpenAI Platform")
                                    .font(.system(size: 12))
                                Button("platform.openai.com/api-keys") {
                                    if let url = URL(string: "https://platform.openai.com/api-keys") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.system(size: 11))
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Text("2.")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            Text("Click \"Create new secret key\" and copy it")
                                .font(.system(size: 12))
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Text("3.")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            Text("Paste it below")
                                .font(.system(size: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 40)

                    // API Key input
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            SecureField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))

                            Button(action: validateKey) {
                                if isValidating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Validate")
                                }
                            }
                            .controlSize(.regular)
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                        }

                        // Status
                        if !statusMessage.isEmpty {
                            HStack(spacing: 6) {
                                if isValid == true {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else if isValid == false {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                Text(statusMessage)
                                    .font(.system(size: 12))
                                    .foregroundColor(isValid == true ? .green : (isValid == false ? .red : .secondary))
                            }
                        }
                    }
                    .padding(.horizontal, 40)

                    // Save button
                    if isValid == true {
                        Button(action: saveAndContinue) {
                            if isSaving {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            } else {
                                Text("Save & Continue")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isSaving)
                        .padding(.horizontal, 40)
                    }

                    // Cost note
                    VStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Your API key is stored locally and never sent to our servers.\nYou'll be billed directly by OpenAI based on your usage.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                if existingKeyPreview != nil {
                    Button("Skip (key already set)") { onNext() }
                } else {
                    Button("Skip for Now") { onNext() }
                }
            }
            .padding(16)
        }
        .onAppear { checkExistingKey() }
    }

    private func checkExistingKey() {
        Task {
            do {
                let url = URL(string: "\(Constants.apiBaseURL)/setup/status")!
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let keySet = json["openai_api_key_set"] as? Bool, keySet,
                   let preview = json["openai_api_key_preview"] as? String {
                    existingKeyPreview = preview
                }
            } catch {
                // Backend not running yet — that's OK
            }
        }
    }

    private func validateKey() {
        isValidating = true
        isValid = nil
        statusMessage = "Validating..."

        Task {
            do {
                let url = URL(string: "\(Constants.apiBaseURL)/setup/validate-key")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["api_key": apiKey.trimmingCharacters(in: .whitespaces)])

                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let valid = json["valid"] as? Bool,
                   let message = json["message"] as? String {
                    isValid = valid
                    statusMessage = message
                } else {
                    isValid = false
                    statusMessage = "Unexpected response from server."
                }
            } catch {
                isValid = false
                statusMessage = "Could not connect to backend. Is it running?"
            }
            isValidating = false
        }
    }

    private func saveAndContinue() {
        isSaving = true
        Task {
            do {
                let url = URL(string: "\(Constants.apiBaseURL)/setup/save-key")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["api_key": apiKey.trimmingCharacters(in: .whitespaces)])

                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["ok"] as? Bool == true {
                    onNext()
                } else {
                    statusMessage = "Failed to save key."
                    isValid = false
                }
            } catch {
                statusMessage = "Could not save: \(error.localizedDescription)"
                isValid = false
            }
            isSaving = false
        }
    }
}

// MARK: - Step 3: Tool Authorization (Composio)

private struct ToolAuthStepView: View {
    var onDone: () -> Void

    @State private var connections: [ToolConnection] = []
    @State private var isLoading = true
    @State private var connectingApp: String?

    private let recommendedApps = [
        ToolApp(key: "gmail", name: "Gmail", icon: "envelope.fill", description: "Read and send emails"),
        ToolApp(key: "googlecalendar", name: "Google Calendar", icon: "calendar", description: "View and manage events"),
        ToolApp(key: "slack", name: "Slack", icon: "bubble.left.and.bubble.right.fill", description: "Send and read messages"),
        ToolApp(key: "github", name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", description: "Manage repos and issues"),
        ToolApp(key: "notion", name: "Notion", icon: "doc.text.fill", description: "Search and edit pages"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text("Connect Your Tools")
                            .font(.system(size: 17, weight: .bold))
                        Text("SpeakFlow can manage your apps via voice commands.\nConnect the tools you want to use.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 16)

                    // Recommended apps
                    VStack(spacing: 2) {
                        ForEach(recommendedApps, id: \.key) { app in
                            let isConnected = connections.contains { $0.appName.lowercased() == app.key && $0.isActive }
                            let isConnecting = connectingApp == app.key

                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(isConnected ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.1))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: isConnected ? "checkmark.circle.fill" : app.icon)
                                        .font(.system(size: 16))
                                        .foregroundColor(isConnected ? .green : .accentColor)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(app.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if isConnected {
                                    Text("Connected")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else if isConnecting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Connect") {
                                        connectApp(app.key)
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)

                            if app.key != recommendedApps.last?.key {
                                Divider().padding(.horizontal, 20)
                            }
                        }
                    }

                    // Note
                    VStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("You can connect more tools later in Settings.\nOAuth is handled by Composio — your credentials are never stored locally.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)

                    let connectedCount = connections.filter(\.isActive).count
                    if connectedCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("\(connectedCount) tool\(connectedCount == 1 ? "" : "s") connected!")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .onAppear { loadConnections() }
    }

    private func loadConnections() {
        isLoading = true
        Task {
            do {
                let conns = try await ComposioService.shared.getConnections()
                connections = conns.map { ToolConnection(appName: $0.appName, isActive: $0.isActive) }
            } catch {
                // Composio not configured — that's fine
            }
            isLoading = false
        }
    }

    private func connectApp(_ appName: String) {
        connectingApp = appName
        Task {
            do {
                try await ComposioService.shared.openOAuth(appName: appName)
                // Poll for connection after OAuth
                try? await Task.sleep(for: .seconds(3))
                loadConnections()
            } catch {
                // OAuth error — user can retry
            }
            connectingApp = nil
        }
    }
}

// MARK: - Helper Models

private struct ToolApp {
    let key: String
    let name: String
    let icon: String
    let description: String
}

private struct ToolConnection {
    let appName: String
    let isActive: Bool
}
