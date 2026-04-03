import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.speakflow", category: "MainWindowView")

// MARK: - Sidebar Navigation

enum SidebarTab: String, CaseIterable {
    case home = "Home"
    case apiKey = "API Key"
    case shortcuts = "Shortcuts"
    case vocabulary = "Vocabulary"
    case mcp = "MCP Servers"
    case general = "Settings"
    case permissions = "Permissions"
    case account = "Account"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .apiKey: return "key.fill"
        case .shortcuts: return "keyboard"
        case .vocabulary: return "text.book.closed.fill"
        case .mcp: return "server.rack"
        case .general: return "gearshape.fill"
        case .permissions: return "lock.shield.fill"
        case .account: return "person.crop.circle.fill"
        }
    }
}

// MARK: - Main Window View

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SidebarTab = .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Logo
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                Text("SpeakFlow")
                    .font(.system(size: 16, weight: .bold))
                if appState.hasActiveSubscription {
                    Text("Pro")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)

            // Nav items
            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    sidebarButton(tab: tab)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            // Subscription status card
            subscriptionCard
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            // Bottom icons
            HStack(spacing: 16) {
                bottomIconButton(icon: "envelope.fill", tooltip: "Feedback") {
                    if let url = URL(string: "https://github.com/alexjin/speakflow-macos/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                bottomIconButton(icon: "questionmark.circle.fill", tooltip: "Help") {
                    let base = Constants.apiBaseURL.replacingOccurrences(of: "/api/v1", with: "")
                    if let url = URL(string: base) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func sidebarButton(tab: SidebarTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                selectedTab == tab
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
            .foregroundColor(selectedTab == tab ? .accentColor : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bottomIconButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Subscription Card

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.hasActiveSubscription {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Pro Plan")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Unlimited usage")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if appState.isLoggedIn {
                Text("Free")
                    .font(.system(size: 12, weight: .semibold))
                Text("Subscribe to unlock unlimited usage")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Button {
                    UpgradeWindow.show(appState: appState)
                } label: {
                    Text("Upgrade")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Text("Not signed in")
                    .font(.system(size: 12, weight: .semibold))
                Text("Sign in to get started")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button {
                    LoginWindow.show(appState: appState)
                } label: {
                    Text("Sign In")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Content Area

    private var content: some View {
        ScrollView {
            Group {
                switch selectedTab {
                case .home:
                    HomeContent()
                case .apiKey:
                    APIKeyContent()
                case .shortcuts:
                    ShortcutsContent()
                case .vocabulary:
                    VocabularyContent()
                case .mcp:
                    MCPSettingsContent()
                case .general:
                    GeneralContent()
                case .permissions:
                    PermissionsContent()
                case .account:
                    AccountContent()
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Home / Dashboard

private struct HomeContent: View {
    @EnvironmentObject var appState: AppState
    @State private var stats: UsageStats?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Hero
            VStack(alignment: .leading, spacing: 8) {
                Text("Speak naturally, type perfectly")
                    .font(.system(size: 22, weight: .bold))
                HStack(spacing: 4) {
                    Text("Press")
                    KeyboardBadge("Option + Z")
                    Text("to start and stop voice input.")
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }

            // Usage stats grid
            if let stats = stats {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    DashboardStatCard(
                        icon: "clock",
                        value: formatDuration(stats.total.audio_seconds),
                        label: "Total Audio"
                    )
                    DashboardStatCard(
                        icon: "arrow.up.arrow.down",
                        value: "\(stats.today.api_calls)",
                        label: "Today's Calls"
                    )
                    DashboardStatCard(
                        icon: "waveform",
                        value: formatDuration(stats.today.audio_seconds),
                        label: "Today's Audio"
                    )
                    DashboardStatCard(
                        icon: "text.bubble",
                        value: formatNumber(stats.total.input_tokens),
                        label: "Input Tokens"
                    )
                    DashboardStatCard(
                        icon: "bolt.fill",
                        value: formatNumber(stats.total.output_tokens),
                        label: "Output Tokens"
                    )
                    DashboardStatCard(
                        icon: "arrow.up.arrow.down",
                        value: "\(stats.total.api_calls)",
                        label: "Total Calls"
                    )
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage stats...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            // Keyboard shortcuts
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 14, weight: .semibold))

                let manager = HotkeyBindingsManager.shared
                ForEach(HotkeyAction.allCases) { action in
                    DashboardShortcutRow(
                        keys: manager.keyCombo(for: action).description,
                        title: action.title,
                        description: action.description
                    )
                }
                DashboardShortcutRow(
                    keys: "Select + \(manager.keyCombo(for: .voiceDictation).description)",
                    title: "Context Mode",
                    description: "Select text first, then speak to transform or ask about it."
                )
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
        .onAppear { loadStats() }
    }

    private func loadStats() {
        guard appState.isLoggedIn else {
            isLoading = false
            return
        }
        isLoading = true
        Task {
            do {
                stats = try await AuthService.shared.fetchUsageStats()
            } catch {
                logger.error("Failed to load dashboard stats: \(error.localizedDescription)")
            }
            isLoading = false
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = seconds / 60
        if mins < 1 { return String(format: "%.0fs", seconds) }
        if mins < 60 { return String(format: "%.1f min", mins) }
        return String(format: "%.1f hr", mins / 60)
    }

    private func formatNumber(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

private struct DashboardStatCard: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor.opacity(0.7))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct DashboardShortcutRow: View {
    let keys: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KeyboardBadge(keys)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct KeyboardBadge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .fixedSize()
    }
}

// MARK: - Shortcuts

private struct ShortcutsContent: View {
    @ObservedObject private var manager = HotkeyBindingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 22, weight: .bold))

            Text("Click a shortcut to change it. Press Escape to cancel.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            DashboardCard(title: "SHORTCUTS", icon: "keyboard") {
                ShortcutsSettingsView(manager: manager)
            }
        }
    }
}

// MARK: - API Key Settings

private struct APIKeyContent: View {
    @State private var apiKey = ""
    @State private var existingKeyPreview: String?
    @State private var currentModel = ""
    @State private var newModel = ""
    @State private var isValidating = false
    @State private var isSaving = false
    @State private var isSavingModel = false
    @State private var isValid: Bool?
    @State private var statusMessage = ""
    @State private var modelMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("API Key")
                .font(.system(size: 22, weight: .bold))

            // Current status
            DashboardCard(title: "OPENAI API KEY", icon: "key.fill") {
                if let preview = existingKeyPreview {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("API Key Configured")
                                .font(.system(size: 13, weight: .medium))
                            Text(preview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 16))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No API Key Set")
                                .font(.system(size: 13, weight: .medium))
                            Text("SpeakFlow requires an OpenAI API key to function")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }

                Divider()

                // Input
                VStack(alignment: .leading, spacing: 8) {
                    Text(existingKeyPreview != nil ? "Update API Key:" : "Enter API Key:")
                        .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 8) {
                        SecureField("sk-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))

                        Button(action: validateAndSave) {
                            if isValidating || isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Save")
                            }
                        }
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isValidating || isSaving)
                    }

                    if !statusMessage.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: isValid == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isValid == true ? .green : .red)
                                .font(.system(size: 11))
                            Text(statusMessage)
                                .font(.system(size: 11))
                                .foregroundColor(isValid == true ? .green : .red)
                        }
                    }
                }

                Divider()

                Button("Get API Key from OpenAI") {
                    if let url = URL(string: "https://platform.openai.com/api-keys") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 12))
            }

            // Model selection
            DashboardCard(title: "MODEL", icon: "cpu") {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPT Model")
                            .font(.system(size: 13, weight: .medium))
                        Text("Current: \(currentModel.isEmpty ? "loading..." : currentModel)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Divider()

                HStack(spacing: 8) {
                    TextField("e.g. gpt-5.4", text: $newModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button(action: saveModel) {
                        if isSavingModel {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Update")
                        }
                    }
                    .controlSize(.small)
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty || isSavingModel)
                }

                if !modelMessage.isEmpty {
                    Text(modelMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text("Your API key is stored in the backend's .env file and never leaves your machine.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { loadStatus() }
    }

    private func loadStatus() {
        Task {
            do {
                let url = URL(string: "\(Constants.apiBaseURL)/setup/status")!
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let keySet = json["openai_api_key_set"] as? Bool, keySet,
                       let preview = json["openai_api_key_preview"] as? String {
                        existingKeyPreview = preview
                    }
                    if let model = json["gpt_model"] as? String {
                        currentModel = model
                        newModel = model
                    }
                }
            } catch {
                // Backend not available
            }
        }
    }

    private func validateAndSave() {
        isValidating = true
        isValid = nil
        statusMessage = "Validating..."

        Task {
            do {
                // Validate first
                let validateURL = URL(string: "\(Constants.apiBaseURL)/setup/validate-key")!
                var validateReq = URLRequest(url: validateURL)
                validateReq.httpMethod = "POST"
                validateReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                validateReq.httpBody = try JSONEncoder().encode(["api_key": apiKey.trimmingCharacters(in: .whitespaces)])

                let (vData, _) = try await URLSession.shared.data(for: validateReq)
                guard let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any],
                      let valid = vJson["valid"] as? Bool else {
                    isValid = false
                    statusMessage = "Unexpected response."
                    isValidating = false
                    return
                }

                if !valid {
                    isValid = false
                    statusMessage = vJson["message"] as? String ?? "Invalid key."
                    isValidating = false
                    return
                }

                // Save
                isValidating = false
                isSaving = true
                let saveURL = URL(string: "\(Constants.apiBaseURL)/setup/save-key")!
                var saveReq = URLRequest(url: saveURL)
                saveReq.httpMethod = "POST"
                saveReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                saveReq.httpBody = try JSONEncoder().encode(["api_key": apiKey.trimmingCharacters(in: .whitespaces)])

                let (sData, _) = try await URLSession.shared.data(for: saveReq)
                if let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                   sJson["ok"] as? Bool == true,
                   let preview = sJson["preview"] as? String {
                    isValid = true
                    statusMessage = "API key saved successfully."
                    existingKeyPreview = preview
                    apiKey = ""
                } else {
                    isValid = false
                    statusMessage = "Failed to save."
                }
            } catch {
                isValid = false
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isValidating = false
            isSaving = false
        }
    }

    private func saveModel() {
        isSavingModel = true
        modelMessage = ""
        Task {
            do {
                let url = URL(string: "\(Constants.apiBaseURL)/setup/save-model")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["model": newModel.trimmingCharacters(in: .whitespaces)])

                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["ok"] as? Bool == true,
                   let model = json["model"] as? String {
                    currentModel = model
                    modelMessage = "Model updated to \(model)"
                }
            } catch {
                modelMessage = "Failed to update model."
            }
            isSavingModel = false
        }
    }
}

// MARK: - General Settings

private struct GeneralContent: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showOverlay") private var showOverlay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 22, weight: .bold))

            DashboardCard(title: "PREFERENCES", icon: "slider.horizontal.3") {
                SettingsToggleRow(label: "Launch at login", isOn: $launchAtLogin)
                Divider()
                SettingsToggleRow(label: "Show recording overlay", isOn: $showOverlay)
            }

            DashboardCard(title: "MICROPHONE", icon: "mic.fill") {
                ForEach(appState.availableMicrophones, id: \.id) { mic in
                    HStack {
                        Text(mic.name)
                            .font(.system(size: 13))
                        Spacer()
                        if mic.id == appState.selectedMicrophoneID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectMicrophone(id: mic.id)
                    }
                    if mic.id != appState.availableMicrophones.last?.id {
                        Divider()
                    }
                }
            }

            // Version
            HStack {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsContent: View {
    @EnvironmentObject var appState: AppState
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var screenRecordingRequested = false
    @State private var automationGranted = false
    @State private var automationRequested = false
    @State private var notificationGranted = false
    @State private var pollTimer: Timer?

    private var allGranted: Bool {
        micGranted && accessibilityGranted && screenRecordingGranted && automationGranted && notificationGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Permissions")
                .font(.system(size: 22, weight: .bold))

            DashboardCard(title: "MICROPHONE", icon: "mic.fill") {
                HStack(spacing: 10) {
                    Image(systemName: micGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(micGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone Access")
                            .font(.system(size: 13, weight: .medium))
                        Text(micGranted ? "Granted" : "Required for voice recording")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !micGranted {
                        Button("Grant") {
                            Task {
                                let granted = await PermissionsHelper.requestMicrophonePermission()
                                micGranted = granted
                                appState.needsMicrophone = !granted
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            DashboardCard(title: "ACCESSIBILITY", icon: "hand.raised.fill") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(accessibilityGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .medium))
                        Text(accessibilityGranted ? "Granted" : "Required for global hotkey and auto-paste")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        Button("Grant") {
                            PermissionsHelper.promptAccessibilityPermission()
                        }
                        .controlSize(.small)
                    }
                }

                if !accessibilityGranted {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Settings > Privacy & Security > Accessibility > click + > select SpeakFlow")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button("Open Accessibility Settings") {
                            PermissionsHelper.openAccessibilitySettings()
                        }
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    }
                }
            }

            DashboardCard(title: "SCREEN RECORDING", icon: "rectangle.dashed.badge.record") {
                HStack(spacing: 10) {
                    Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(screenRecordingGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording")
                            .font(.system(size: 13, weight: .medium))
                        Text(screenRecordingGranted ? "Granted" : "Required for screenshot context features")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !screenRecordingGranted {
                        Button("Grant") {
                            PermissionsHelper.promptScreenRecordingPermission()
                            PermissionsHelper.openScreenRecordingSettings()
                            screenRecordingRequested = true
                        }
                        .controlSize(.small)
                    }
                }

                if screenRecordingRequested && !screenRecordingGranted {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("After enabling Screen Recording in Settings, please restart SpeakFlow.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Button("Restart SpeakFlow") {
                            let bundlePath = Bundle.main.bundlePath
                            let task = Process()
                            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                            task.arguments = ["-n", bundlePath]
                            try? task.run()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NSApp.terminate(nil)
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
            }

            DashboardCard(title: "AUTOMATION", icon: "gearshape.2.fill") {
                HStack(spacing: 10) {
                    Image(systemName: automationGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(automationGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automation (System Events)")
                            .font(.system(size: 13, weight: .medium))
                        Text(automationGranted ? "Granted" : "Required for agent to control apps")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !automationGranted {
                        Button("Grant") {
                            PermissionsHelper.promptAutomationPermission()
                            automationRequested = true
                        }
                        .controlSize(.small)
                    }
                }

                if automationRequested && !automationGranted {
                    Divider()
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
                }
            }

            DashboardCard(title: "NOTIFICATIONS", icon: "bell.fill") {
                HStack(spacing: 10) {
                    Image(systemName: notificationGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(notificationGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                            .font(.system(size: 13, weight: .medium))
                        Text(notificationGranted ? "Granted" : "Required for scheduled reminders")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !notificationGranted {
                        Button("Grant") {
                            Task {
                                notificationGranted = await PermissionsHelper.requestNotificationPermission()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            if allGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("All permissions granted!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                }
            }
        }
        .onAppear {
            micGranted = PermissionsHelper.hasMicrophonePermission
            accessibilityGranted = AXIsProcessTrusted()
            screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
            automationGranted = PermissionsHelper.checkAutomationPermission()
            Task {
                notificationGranted = await PermissionsHelper.checkNotificationPermission()
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                DispatchQueue.main.async {
                    // Poll accessibility
                    let newAcc = AXIsProcessTrusted()
                    if newAcc != accessibilityGranted {
                        accessibilityGranted = newAcc
                        appState.needsAccessibility = !newAcc
                        if newAcc {
                            appState.onOnboardingComplete()
                        }
                    }
                    // Poll microphone
                    let newMic = PermissionsHelper.hasMicrophonePermission
                    if newMic != micGranted {
                        micGranted = newMic
                        appState.needsMicrophone = !newMic
                    }
                    // Poll screen recording
                    if !screenRecordingGranted && screenRecordingRequested {
                        let tccGranted = PermissionsHelper.checkScreenRecordingFromTCC()
                        if tccGranted {
                            PermissionsHelper.relaunchApp()
                            return
                        }
                    }
                    screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
                }
                // Check automation on background thread
                if !automationGranted {
                    DispatchQueue.global(qos: .utility).async {
                        let granted = PermissionsHelper.checkAutomationPermission()
                        DispatchQueue.main.async {
                            automationGranted = granted
                        }
                    }
                }
                // Check notification permission
                if !notificationGranted {
                    Task {
                        let granted = await PermissionsHelper.checkNotificationPermission()
                        await MainActor.run {
                            notificationGranted = granted
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
}

// MARK: - Account

private struct AccountContent: View {
    @EnvironmentObject var appState: AppState
    @State private var subscription: SubscriptionStatus?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var inviteCode = ""
    @State private var redeemMessage = ""
    @State private var isRedeeming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account")
                .font(.system(size: 22, weight: .bold))

            if appState.isLoggedIn {
                DashboardCard(title: "PROFILE", icon: "person.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.userEmail ?? "-")
                                .font(.system(size: 13, weight: .medium))
                            Text("Signed in")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Button("Sign Out") {
                            appState.performSignOut()
                            subscription = nil
                        }
                        .controlSize(.small)
                        .foregroundColor(.red)
                    }
                }

                DashboardCard(title: "SUBSCRIPTION", icon: "creditcard.fill") {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("Loading...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    } else if let loadError, subscription == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Couldn’t refresh subscription")
                                .font(.system(size: 13, weight: .medium))
                            Text(loadError)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            Button("Retry") { loadSubscription() }
                                .controlSize(.small)
                        }
                    } else if let sub = subscription, sub.is_active {
                        HStack {
                            Text("Plan")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(sub.plan_display_name ?? "Pro")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Divider()
                        HStack {
                            Text("Status")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            HStack(spacing: 5) {
                                Circle().fill(Color.green).frame(width: 7, height: 7)
                                Text(sub.statusLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.green)
                            }
                        }
                        if let days = sub.daysRemaining {
                            Divider()
                            HStack {
                                Text("Expires")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                if days <= 7 {
                                    Text("\(days) day\(days == 1 ? "" : "s") left")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.orange)
                                } else {
                                    Text(sub.periodEndDate!, style: .date)
                                        .font(.system(size: 12))
                                }
                            }
                        }
                        if sub.stripe_subscription_id != nil
                            && sub.stripe_subscription_id?.hasPrefix("invite_") == false {
                            Button("Manage Subscription") { openPortal() }
                                .controlSize(.small)
                                .padding(.top, 4)
                        }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No active plan")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Subscribe to unlock unlimited usage")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Upgrade") {
                                UpgradeWindow.show(appState: appState)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                DashboardCard(title: "INVITE CODE", icon: "ticket.fill") {
                    HStack(spacing: 8) {
                        TextField("Enter code", text: $inviteCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Button("Redeem") { redeem() }
                            .controlSize(.small)
                            .disabled(inviteCode.isEmpty || isRedeeming)
                    }
                    if !redeemMessage.isEmpty {
                        Text(redeemMessage)
                            .font(.system(size: 11))
                            .foregroundColor(redeemMessage.contains("activated") ? .green : .red)
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Sign in to manage your account")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button("Sign in with Google") {
                        OAuthService.shared.startGoogleLogin { result in
                            if case .success(let response) = result {
                                appState.isLoggedIn = true
                                appState.userEmail = response.user.email
                                KeychainService.shared.userEmail = response.user.email
                                appState.loadSubscription()
                                loadSubscription()
                            }
                        }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
        .onAppear { if appState.isLoggedIn { loadSubscription() } }
    }

    private func loadSubscription() {
        isLoading = true
        loadError = nil
        Task {
            do {
                let sub = try await AuthService.shared.fetchSubscription()
                logger.info("Subscription loaded: is_active=\(sub.is_active), plan=\(sub.plan_name ?? "nil")")
                subscription = sub
                appState.applySubscriptionStatus(sub)
            } catch {
                logger.error("Failed to load subscription: \(error.localizedDescription)")
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func redeem() {
        isRedeeming = true
        redeemMessage = ""
        Task {
            do {
                let message = try await AuthService.shared.redeemInviteCode(inviteCode)
                redeemMessage = message
                inviteCode = ""
                appState.applySubscriptionStatus(SubscriptionStatus(is_active: true, plan_name: "invite", plan_display_name: "Pro", status: "active", current_period_end: nil, cancelled_at: nil, stripe_subscription_id: nil))
                loadSubscription()
            } catch {
                redeemMessage = error.localizedDescription
            }
            isRedeeming = false
        }
    }

    private func openPortal() {
        Task {
            do {
                let url = try await AuthService.shared.fetchPortalURL()
                if let nsURL = URL(string: url) {
                    NSWorkspace.shared.open(nsURL)
                }
            } catch {
                logger.error("Failed to open portal: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Shared Components

// MCP Servers page now lives in MCPSettingsView.swift as MCPSettingsContent

// MARK: - Shared Components

private struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

private struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(.system(size: 13))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
