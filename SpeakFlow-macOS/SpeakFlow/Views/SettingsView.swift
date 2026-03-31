import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.speakflow", category: "SettingsView")

// MARK: - Main Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SettingsTab = .general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case permissions = "Permissions"
        case mcp = "MCP"
        case account = "Account"
        case usage = "Usage"

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .permissions: return "lock.shield.fill"
            case .mcp: return "server.rack"
            case .account: return "person.crop.circle.fill"
            case .usage: return "chart.bar.fill"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Custom tab bar
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsContent(appState: appState)
                    case .permissions:
                        PermissionsSettingsContent(appState: appState)
                    case .mcp:
                        MCPSettingsContent()
                    case .account:
                        AccountSettingsContent(appState: appState)
                    case .usage:
                        UsageSettingsContent()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 480, height: 460)
    }
}

// MARK: - Card Container

private struct SectionCard<Content: View>: View {
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

// MARK: - General Tab

private struct GeneralSettingsContent: View {
    @ObservedObject var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showOverlay") private var showOverlay = true

    var body: some View {
        VStack(spacing: 16) {
            SectionCard(title: "PREFERENCES", icon: "slider.horizontal.3") {
                SettingsToggle(label: "Launch at login", isOn: $launchAtLogin)
                Divider()
                SettingsToggle(label: "Show recording overlay", isOn: $showOverlay)
            }

            SectionCard(title: "KEYBOARD SHORTCUTS", icon: "keyboard") {
                ShortcutsSettingsView()
            }

            SectionCard(title: "HOW IT WORKS", icon: "questionmark.circle") {
                VStack(alignment: .leading, spacing: 8) {
                    let voiceKey = HotkeyBindingsManager.shared.keyCombo(for: .voiceDictation).description
                    StepRow(number: 1, text: "Press \(voiceKey) to start recording")
                    StepRow(number: 2, text: "Speak naturally — describe what you want to type")
                    StepRow(number: 3, text: "Press \(voiceKey) again — text appears at your cursor")
                }
            }
        }
    }
}

private struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 13))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
        }
    }
}

// MARK: - Permissions Tab

private struct PermissionsSettingsContent: View {
    @ObservedObject var appState: AppState
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var screenRecordingRequested = false
    @State private var automationGranted = false
    @State private var automationRequested = false
    @State private var appManagementGranted = false
    @State private var notificationGranted = false
    @State private var pollTimer: Timer?

    private var allGranted: Bool {
        micGranted && accessibilityGranted && screenRecordingGranted && automationGranted && appManagementGranted && notificationGranted
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("DEBUG: APP MANAGEMENT SHOULD BE HERE")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.red)

            SectionCard(title: "MICROPHONE", icon: "mic.fill") {
                HStack(spacing: 10) {
                    Image(systemName: micGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(micGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone Access")
                            .font(.system(size: 13, weight: .medium))
                        Text(micGranted ? "Granted — voice recording is available" : "Required for voice recording")
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

            SectionCard(title: "ACCESSIBILITY", icon: "hand.raised.fill") {
                HStack(spacing: 10) {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(accessibilityGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                            .font(.system(size: 13, weight: .medium))
                        Text(accessibilityGranted ? "Granted — hotkey and auto-paste are available" : "Required for global hotkey and auto-paste")
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
                        Text("If SpeakFlow doesn't appear in the list:")
                            .font(.system(size: 11, weight: .medium))
                        Text("System Settings → Privacy & Security → Accessibility → click + → select SpeakFlow")
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

            SectionCard(title: "SCREEN RECORDING", icon: "rectangle.dashed.badge.record") {
                HStack(spacing: 10) {
                    Image(systemName: screenRecordingGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(screenRecordingGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen Recording")
                            .font(.system(size: 13, weight: .medium))
                        Text(screenRecordingGranted ? "Granted — screenshot context features are available" : "Required for screenshot context features")
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

            SectionCard(title: "AUTOMATION", icon: "gearshape.2.fill") {
                HStack(spacing: 10) {
                    Image(systemName: automationGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(automationGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automation (System Events)")
                            .font(.system(size: 13, weight: .medium))
                        Text(automationGranted ? "Granted — agent can control apps" : "Required for agent to click, type, and switch windows")
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

            SectionCard(title: "NOTIFICATIONS", icon: "bell.fill") {
                HStack(spacing: 10) {
                    Image(systemName: notificationGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(notificationGranted ? .green : .red)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications")
                            .font(.system(size: 13, weight: .medium))
                        Text(notificationGranted ? "Granted — reminders will appear" : "Required for scheduled reminders")
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
                    Text("All permissions granted — SpeakFlow is ready to use!")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            micGranted = PermissionsHelper.hasMicrophonePermission
            accessibilityGranted = AXIsProcessTrusted()
            screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
            automationGranted = PermissionsHelper.checkAutomationPermission()
            appManagementGranted = PermissionsHelper.checkAppManagementPermission()
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
                    // Poll screen recording — use TCC DB since CGPreflight caches within process
                    if !screenRecordingGranted && screenRecordingRequested {
                        let tccGranted = PermissionsHelper.checkScreenRecordingFromTCC()
                        if tccGranted {
                            PermissionsHelper.relaunchApp()
                            return
                        }
                    }
                    screenRecordingGranted = PermissionsHelper.hasScreenRecordingPermission
                }
                // Check automation on background thread (runs osascript)
                if !automationGranted {
                    DispatchQueue.global(qos: .utility).async {
                        let granted = PermissionsHelper.checkAutomationPermission()
                        DispatchQueue.main.async {
                            automationGranted = granted
                        }
                    }
                }
                // Check app management permission
                if !appManagementGranted {
                    DispatchQueue.global(qos: .utility).async {
                        let granted = PermissionsHelper.checkAppManagementPermission()
                        DispatchQueue.main.async {
                            appManagementGranted = granted
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

// MARK: - Account Tab

private struct AccountSettingsContent: View {
    @ObservedObject var appState: AppState
    @State private var subscription: SubscriptionStatus?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var inviteCode = ""
    @State private var redeemMessage = ""
    @State private var isRedeeming = false

    var body: some View {
        VStack(spacing: 16) {
            if appState.isLoggedIn {
                // Profile card
                SectionCard(title: "PROFILE", icon: "person.fill") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.userEmail ?? "—")
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

                // Subscription card
                SectionCard(title: "SUBSCRIPTION", icon: "creditcard.fill") {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
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
                        activeSubscriptionView(sub)
                    } else {
                        noSubscriptionView()
                    }
                }

                // Invite code card
                SectionCard(title: "INVITE CODE", icon: "ticket.fill") {
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
                // Not signed in
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            }
        }
        .onAppear { if appState.isLoggedIn { loadSubscription() } }
    }

    @ViewBuilder
    private func activeSubscriptionView(_ sub: SubscriptionStatus) -> some View {
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
                Circle()
                    .fill(sub.is_active ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                Text(sub.statusLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(sub.is_active ? .green : .red)
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
                        .foregroundColor(.primary.opacity(0.7))
                }
            }
        }

        if sub.cancelled_at != nil {
            Text("Will not renew after current period")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(.top, 2)
        }

        if sub.status == "past_due" {
            Text("Payment failed — please update payment method")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .padding(.top, 2)
        }

        if sub.stripe_subscription_id != nil
            && sub.stripe_subscription_id?.hasPrefix("invite_") == false {
            Button("Manage Subscription") { openPortal() }
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func noSubscriptionView() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("No active plan")
                    .font(.system(size: 13, weight: .medium))
                Text("Subscribe to unlock unlimited usage")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("View Plans") { openPricing() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
    }

    private func loadSubscription() {
        isLoading = true
        loadError = nil
        Task {
            do {
                let sub = try await AuthService.shared.fetchSubscription()
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
                // Create a synthetic active status for the cache
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

    private func openPricing() {
        let base = Constants.apiBaseURL.replacingOccurrences(of: "/api/v1", with: "")
        if let url = URL(string: "\(base)/pricing") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Usage Tab

private struct UsageSettingsContent: View {
    @State private var stats: UsageStats?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading usage data...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if let stats = stats {
                SectionCard(title: "TODAY", icon: "calendar") {
                    UsageGrid(period: stats.today)
                }

                SectionCard(title: "ALL TIME", icon: "clock.fill") {
                    UsageGrid(period: stats.total)
                }

                Button {
                    load()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(errorMessage ?? "No data available")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Button("Try Again") { load() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                stats = try await AuthService.shared.fetchUsageStats()
            } catch is AuthError {
                errorMessage = "Sign in to view usage stats"
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct UsageGrid: View {
    let period: UsagePeriod

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            StatCard(title: "API Calls", value: "\(period.api_calls)", icon: "arrow.up.arrow.down")
            StatCard(title: "Audio", value: formatDuration(period.audio_seconds), icon: "waveform")
            StatCard(title: "Input Tokens", value: formatNumber(period.input_tokens), icon: "text.bubble")
            StatCard(title: "Output Tokens", value: formatNumber(period.output_tokens), icon: "doc.text")
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

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor.opacity(0.8))
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
    }
}
