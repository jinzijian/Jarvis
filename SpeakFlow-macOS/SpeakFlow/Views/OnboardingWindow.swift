import SwiftUI

// MARK: - Onboarding Steps

private enum OnboardingStep: Int, CaseIterable {
    case permissions = 0
    case login = 1
    case upgrade = 2
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
        w.setContentSize(NSSize(width: 720, height: 500))
        w.minSize = NSSize(width: 620, height: 420)
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
                    PermissionsStepView(onNext: { currentStep = .login })
                case .login:
                    LoginStepView(onNext: {
                        checkSubscriptionAndAdvance()
                    })
                case .upgrade:
                    UpgradeStepView(onDone: { finishOnboarding() })
                }
            }
        }
        .frame(width: 720, height: 500)
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
        case .login: return "Sign In"
        case .upgrade: return "Subscribe"
        }
    }

    private func checkSubscriptionAndAdvance() {
        guard appState.isLoggedIn else {
            currentStep = .upgrade
            return
        }
        Task {
            do {
                let sub = try await AuthService.shared.fetchSubscription()
                appState.applySubscriptionStatus(sub)
                if sub.is_active {
                    finishOnboarding()
                } else {
                    currentStep = .upgrade
                }
            } catch {
                currentStep = .upgrade
            }
        }
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        appState.onOnboardingComplete()
        OnboardingWindow.closeAndShowSettings()
    }
}

// MARK: - Step 1: Permissions

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
                    // Use TCC DB to detect screen recording grant, then auto-relaunch
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

// MARK: - Step 2: Login

private struct LoginStepView: View {
    var onNext: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var isGoogleLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text("Sign In")
                            .font(.system(size: 17, weight: .bold))
                        Text("Create an account or sign in to continue")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 16)

                    // Google Sign In
                    Button(action: googleLogin) {
                        HStack(spacing: 8) {
                            if isGoogleLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("G")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                            Text("Continue with Google")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading || isGoogleLoading)
                    .padding(.horizontal, 40)

                    // Divider
                    HStack {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                        Text("or").font(.system(size: 12)).foregroundColor(.secondary)
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 1)
                    }
                    .padding(.horizontal, 40)

                    // Email/Password
                    VStack(spacing: 10) {
                        TextField("Email", text: $email)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal, 40)

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .lineLimit(2)
                            .padding(.horizontal, 40)
                    }

                    Button(action: emailLogin) {
                        if isLoading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In with Email").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(email.isEmpty || password.isEmpty || isLoading || isGoogleLoading)
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Skip for Now") { onNext() }
            }
            .padding(16)
        }
        .onAppear {
            // If already logged in (e.g. tokens in keychain), auto-advance
            if appState.isLoggedIn { onNext() }
        }
        .onReceive(appState.$isLoggedIn) { loggedIn in
            if loggedIn { onNext() }
        }
    }

    private func googleLogin() {
        isGoogleLoading = true
        errorMessage = nil
        OAuthService.shared.startGoogleLogin { result in
            isGoogleLoading = false
            switch result {
            case .success(let response):
                appState.isLoggedIn = true
                appState.userEmail = response.user.email
                KeychainService.shared.userEmail = response.user.email
                appState.loadSubscription()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func emailLogin() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let response = try await AuthService.shared.login(email: email, password: password)
                await MainActor.run {
                    appState.isLoggedIn = true
                    appState.userEmail = response.user.email
                    KeychainService.shared.userEmail = response.user.email
                    appState.loadSubscription()
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Step 3: Upgrade

private struct UpgradeStepView: View {
    var onDone: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var isLoadingMonthly = false
    @State private var isLoadingAnnual = false
    @State private var inviteCode = ""
    @State private var isRedeeming = false
    @State private var message = ""
    @State private var messageIsError = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text("Choose a Plan")
                            .font(.system(size: 17, weight: .bold))
                        Text("Subscribe to start using SpeakFlow")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 16)

                    if !appState.isLoggedIn {
                        Text("Sign in first to subscribe")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    // Monthly
                    pricingCard(
                        title: "Monthly",
                        price: "$1",
                        subtitle: "first month, then $12.99/mo",
                        featured: false,
                        isLoading: isLoadingMonthly
                    ) {
                        checkout(plan: "monthly", setLoading: { isLoadingMonthly = $0 })
                    }

                    // Annual
                    pricingCard(
                        title: "Annual",
                        price: "$99.99/yr",
                        subtitle: "Save 36% — $8.33/mo",
                        featured: true,
                        isLoading: isLoadingAnnual
                    ) {
                        checkout(plan: "annual", setLoading: { isLoadingAnnual = $0 })
                    }

                    // Features
                    VStack(alignment: .leading, spacing: 6) {
                        featureRow("Unlimited voice commands")
                        featureRow("Screenshot & text context")
                        featureRow("All languages supported")
                        featureRow("Cancel anytime")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)

                    // Invite code
                    VStack(spacing: 6) {
                        Text("Have an invite code?")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("Enter code", text: $inviteCode)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            Button("Redeem") { redeem() }
                                .controlSize(.small)
                                .disabled(inviteCode.isEmpty || isRedeeming || !appState.isLoggedIn)
                        }
                        .padding(.horizontal, 28)
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(messageIsError ? .red : .green)
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Later") { onDone() }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func pricingCard(
        title: String,
        price: String,
        subtitle: String,
        featured: Bool,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                        if featured {
                            Text("BEST VALUE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(price)
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                featured
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(featured ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: featured ? 1.5 : 0.5)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMonthly || isLoadingAnnual || !appState.isLoggedIn)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func featureRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.8))
        }
    }

    private func checkout(plan: String, setLoading: @escaping (Bool) -> Void) {
        guard appState.isLoggedIn else {
            message = "Please sign in first"
            messageIsError = true
            return
        }
        setLoading(true)
        message = ""
        Task {
            do {
                let url = try await AuthService.shared.createCheckoutSession(plan: plan)
                if let nsURL = URL(string: url) {
                    NSWorkspace.shared.open(nsURL)
                }
                message = "Complete payment in your browser"
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            setLoading(false)
        }
    }

    private func redeem() {
        isRedeeming = true
        message = ""
        Task {
            do {
                let msg = try await AuthService.shared.redeemInviteCode(inviteCode)
                message = msg
                messageIsError = false
                inviteCode = ""
                appState.applySubscriptionStatus(SubscriptionStatus(is_active: true, plan_name: "invite", plan_display_name: "Pro", status: "active", current_period_end: nil, cancelled_at: nil, stripe_subscription_id: nil))
                onDone()
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            isRedeeming = false
        }
    }
}
