import CoreAudio
import Foundation
import os.log
import SwiftUI

private let logger = Logger(subsystem: "com.speakflow", category: "AppState")

enum AppPhase {
    case idle
    case recording
    case processing
    case done
    case error
}

enum InputMode {
    case normal          // Existing dictation mode
    case textSelection   // User had text selected
    case screenshot      // User captured a screenshot region
    case fullScreen      // Silent full-screen capture + voice
}

@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn = true  // No auth needed in open-source mode
    @Published var userEmail: String? = "local"
    private var sessionExpiredObserver: Any?
    @Published var appPhase: AppPhase = .idle
    @Published var streamingText = ""
    @Published var lastResult: String?
    @Published var lastError: String?
    @Published var clipboardHint: String?
    @Published var needsAccessibility = false
    @Published var needsMicrophone = false
    @Published var hasActiveSubscription = true  // No subscription needed in open-source mode
    @Published var hotkeyReady = false

    private static let subscriptionCacheTTL: TimeInterval = 3600 // 1 hour
    private static let subscriptionRefreshInterval: TimeInterval = 30 * 60 // 30 minutes
    private var subscriptionRefreshTimer: Timer?
    @Published var availableMicrophones: [MicrophoneInfo] = []
    @Published var selectedMicrophoneID: String?

    // Context mode state
    @Published var inputMode: InputMode = .normal
    @Published var contextText: String?
    @Published var contextImage: Data?
    @Published var isContextEditable: Bool = false

    // Agent
    let agentState = AgentState()
    private var agentLoop: AgentLoop?
    private var agentTask: Task<Void, Never>?
    private let agentOverlayPanel = AgentOverlayPanel()
    let heartbeatScheduler = HeartbeatScheduler.shared

    // Services
    private let hotkeyService = HotkeyService()
    private let audioRecorder = AudioRecorderService()
    private let processingService = AudioProcessingService()
    private let textInputService = TextInputService()
    private let selectionService = SelectionService()
    private let screenCaptureService = ScreenCaptureService()
    private let overlayPanel = RecordingOverlayPanel()
    private let resultOverlayPanel = ResultOverlayPanel()
    private let vocabularyService = VocabularyService.shared

    private var recordingFileURL: URL?
    private var recordingStartTime: Date?
    private var processingTask: Task<Void, Never>?
    private var escGlobalMonitor: CFMachPort?
    private var escLocalMonitor: Any?
    private var vocabularyTimer: Timer?
    private var agentRecordingFileURL: URL?
    private var agentRecordingStartTime: Date?

    var isRecording: Bool { appPhase == .recording }
    var isProcessing: Bool { appPhase == .processing }

    func setup() {
        checkPermissions()
        refreshMicrophones()

        // Listen for session expiry (fires at most once per expiry cycle)
        // Only mark as logged out — preserve subscription cache for graceful degradation
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .authSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isLoggedIn = false
                self.userEmail = nil
                logger.warning("Session expired — subscription cache preserved")
            }
        }

        // Don't auto-prompt accessibility — let the user grant it via
        // onboarding, settings, or menu bar. Each rebuild changes the signature
        // which invalidates the previous grant, causing repeated prompts.
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !AXIsProcessTrusted() {
            logger.info("Accessibility not granted (will prompt when needed)")
        }

        // Load saved mic selection
        selectedMicrophoneID = UserDefaults.standard.string(forKey: "selectedMicrophoneID")

        // Fn key shortcuts (state-aware)
        let fnService = hotkeyService.fnKeyService
        fnService.isRecording = { [weak self] in
            self?.appPhase == .recording
        }
        fnService.onFnSingleTap = { [weak self] in
            Task { @MainActor in
                self?.handleFnTap()
            }
        }
        fnService.onFnDoubleTap = { [weak self] in
            Task { @MainActor in
                self?.toggleAgentRecording()
            }
        }
        fnService.onFnOption = { [weak self] in
            Task { @MainActor in
                self?.startScreenshotFlow()
            }
        }
        fnService.onFnA = { [weak self] in
            Task { @MainActor in
                self?.toggleFullScreenFlow()
            }
        }

        // Only start hotkey if onboarding is done (otherwise it triggers accessibility prompt)
        if hasCompletedOnboarding {
            startHotkeyIfReady()
        }

        // Connect enabled MCP servers in background
        Task {
            await MCPServerManager.shared.connectAll()
        }

        // Start heartbeat scheduler for timed tasks / reminders
        heartbeatScheduler.onAgentTrigger = { [weak self] command in
            Task { @MainActor in
                guard let self else { return }
                // If agent is currently active, queue as notification instead of interrupting
                if self.agentState.phase == .agentRunning || self.agentState.phase == .agentWaiting {
                    logger.info("[HEARTBEAT] Agent busy (phase=\(String(describing: self.agentState.phase))), sending notification fallback: \(command)")
                    self.heartbeatScheduler.sendNotificationFallback(
                        title: "SpeakFlow Agent",
                        body: "Scheduled task: \(command)"
                    )
                } else {
                    logger.info("[HEARTBEAT] Triggering agent for scheduled task: \(command)")
                    self.runAgent(command: command)
                }
            }
        }
        heartbeatScheduler.onNotifyTrigger = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.showReminder(message: message)
            }
        }
        heartbeatScheduler.start()

        // Sync vocabulary from cloud and start periodic batch processing
        Task {
            await vocabularyService.syncVocabulary()
            triggerVocabularyBatchIfNeeded()
        }
        startVocabularyTimer()

        // Periodically refresh subscription in background
        startSubscriptionRefreshTimer()
    }

    private func startSubscriptionRefreshTimer() {
        subscriptionRefreshTimer?.invalidate()
        subscriptionRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.subscriptionRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLoggedIn else { return }
                self.refreshSubscriptionSilently()
            }
        }
    }

    private func refreshSubscriptionSilently() {
        Task {
            do {
                let sub = try await AuthService.shared.fetchSubscription()
                applySubscriptionStatus(sub)
                logger.info("Background subscription refresh: is_active=\(sub.is_active)")
            } catch {
                logger.warning("Background subscription refresh failed (keeping cache): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Microphone Management

    func refreshMicrophones() {
        availableMicrophones = MicrophoneManager.listInputDevices()
        // If no mic selected or selected mic no longer available, use default
        if selectedMicrophoneID == nil || !availableMicrophones.contains(where: { $0.id == selectedMicrophoneID }) {
            if let defaultID = MicrophoneManager.defaultInputDeviceID() {
                selectedMicrophoneID = "\(defaultID)"
            }
        }
    }

    func selectMicrophone(id: String) {
        selectedMicrophoneID = id
        UserDefaults.standard.set(id, forKey: "selectedMicrophoneID")
    }

    // MARK: - Permissions

    func checkPermissions() {
        needsMicrophone = !PermissionsHelper.hasMicrophonePermission
        needsAccessibility = !AXIsProcessTrusted()
        if needsMicrophone { logger.warning("Microphone permission NOT granted") }
        if needsAccessibility { logger.warning("Accessibility permission NOT granted") }
    }

    func requestAccessibility() {
        PermissionsHelper.promptAccessibilityPermission()
        // Poll for permission after prompt (user needs to grant in System Settings)
        Task {
            for _ in 0..<30 { // check for 30 seconds
                try? await Task.sleep(for: .seconds(1))
                if PermissionsHelper.hasAccessibilityPermission {
                    needsAccessibility = false
                    startHotkeyIfReady()
                    break
                }
            }
        }
    }

    func requestMicrophone() {
        Task {
            let granted = await PermissionsHelper.requestMicrophonePermission()
            needsMicrophone = !granted
        }
    }

    /// Called after onboarding completes to initialize hotkeys
    func onOnboardingComplete() {
        startHotkeyIfReady()
    }

    private func startHotkeyIfReady() {
        hotkeyService.start()
        hotkeyReady = hotkeyService.isRunning
        // Always check actual system permission, not just hotkey status
        needsAccessibility = !AXIsProcessTrusted()
        logger.info("Hotkey started: \(self.hotkeyReady), accessibility: \(!self.needsAccessibility)")
    }

    func loadSubscription() {
        guard isLoggedIn else { return }
        Task {
            do {
                let sub = try await fetchSubscriptionStatusWithRetry()
                applySubscriptionStatus(sub)
                logger.info("Subscription loaded: is_active=\(sub.is_active), plan=\(sub.plan_name ?? "nil")")
            } catch AuthError.notLoggedIn {
                if isSubscriptionCacheFresh {
                    logger.info("Token expired but subscription cache still fresh, preserving")
                } else {
                    logger.warning("Token expired and cache stale, logging out")
                    performSignOut()
                }
            } catch {
                logger.warning("Failed to load subscription (transient): \(error.localizedDescription)")
                // Keep last known subscription state on transient failures
            }
        }
    }

    private func fetchSubscriptionStatusWithRetry() async throws -> SubscriptionStatus {
        var lastError: Error?
        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            do {
                return try await AuthService.shared.fetchSubscription()
            } catch AuthError.notLoggedIn {
                throw AuthError.notLoggedIn
            } catch {
                lastError = error
                logger.warning("Failed to load subscription (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)")
                if attempt < maxAttempts {
                    // Exponential backoff: 1s, 2s, 4s
                    let delay = pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError ?? AuthError.serverError("Unknown subscription error")
    }

    func applySubscriptionStatus(_ sub: SubscriptionStatus) {
        hasActiveSubscription = sub.is_active
        UserDefaults.standard.set(sub.is_active, forKey: "cachedHasActiveSubscription")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "cachedSubscriptionTimestamp")
    }

    var isSubscriptionCacheFresh: Bool {
        let timestamp = UserDefaults.standard.double(forKey: "cachedSubscriptionTimestamp")
        guard timestamp > 0 else { return false }
        return Date().timeIntervalSince1970 - timestamp < Self.subscriptionCacheTTL
    }

    func forceClearSubscriptionStatus() {
        hasActiveSubscription = false
        UserDefaults.standard.removeObject(forKey: "cachedHasActiveSubscription")
        UserDefaults.standard.removeObject(forKey: "cachedSubscriptionTimestamp")
    }

    func performSignOut() {
        AuthService.shared.logout()
        isLoggedIn = false
        userEmail = nil
        forceClearSubscriptionStatus()
        subscriptionRefreshTimer?.invalidate()
        subscriptionRefreshTimer = nil
        logger.info("Signed out, subscription cache cleared")
    }

    private func handleNoSubscriptionSignal() async {
        do {
            let sub = try await fetchSubscriptionStatusWithRetry()
            applySubscriptionStatus(sub)

            if sub.is_active {
                logger.error("Received noSubscription from process API, but subscription API reports active")
                overlayPanel.dismiss()
                resultOverlayPanel.dismiss()
                appPhase = .idle
                lastError = "Couldn’t verify subscription during processing. Please try again."
                return
            }

            overlayPanel.dismiss()
            resultOverlayPanel.dismiss()
            UpgradeWindow.show(appState: self)
            appPhase = .idle
        } catch AuthError.notLoggedIn {
            if isSubscriptionCacheFresh {
                logger.info("handleNoSubscriptionSignal: token expired but cache fresh, preserving")
            } else {
                performSignOut()
            }
            overlayPanel.dismiss()
            resultOverlayPanel.dismiss()
            appPhase = .idle
        } catch {
            logger.error("Failed to verify subscription after noSubscription signal: \(error.localizedDescription)")
            // Keep last known subscription state on transient failures.
            overlayPanel.dismiss()
            resultOverlayPanel.dismiss()
            appPhase = .idle
            lastError = "Couldn’t verify subscription. Check your network and try again."
        }
    }

    func teardown() {
        removeEscMonitors()
        hotkeyService.stop()
        vocabularyTimer?.invalidate()
        vocabularyTimer = nil
        subscriptionRefreshTimer?.invalidate()
        subscriptionRefreshTimer = nil
    }

    // MARK: - Recording Flow (Toggle Mode)

    /// Unified fn tap handler: stops any active recording, or starts voice dictation if idle.
    /// Called by FnKeyService — when recording, double-tap detection is already skipped.
    private func handleFnTap() {
        if appPhase == .recording {
            // Stop whatever is currently recording
            if agentRecordingFileURL != nil {
                stopAgentRecordingAndProcess()
            } else if bugReportRecordingFileURL != nil {
                stopBugReportRecordingAndProcess()
            } else {
                stopRecordingAndProcess()
            }
        } else if appPhase == .idle {
            startRecording()
        }
    }

    /// Toggle: press once to start, press again to stop
    private func toggleRecording() {
        if appPhase == .recording {
            stopRecordingAndProcess()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard appPhase == .idle else { return }

        // Save the frontmost app so we can paste into it later
        textInputService.saveFrontmostApp()

        // Detect selected text BEFORE showing overlay (overlay can interfere with AX focus)
        if inputMode == .normal {
            if let selection = selectionService.getSelectedText() {
                inputMode = .textSelection
                // Truncate very long selections to avoid excessive API costs
                let maxContextLength = 50_000
                if selection.text.count > maxContextLength {
                    contextText = String(selection.text.prefix(maxContextLength))
                } else {
                    contextText = selection.text
                }
                isContextEditable = selection.isEditable
                logger.info("Text selection detected: \(selection.text.prefix(50))... editable=\(selection.isEditable)")
            }
        }

        // Show overlay after selection detection
        overlayPanel.show(appState: self)

        if !isLoggedIn {
            overlayPanel.dismiss()
            LoginWindow.show(appState: self)
            resetInputMode()
            return
        }

        if needsMicrophone {
            lastError = "Microphone permission required"
            appPhase = .error
            requestMicrophone()
            resetAfterDelay()
            return
        }

        do {
            let deviceID: AudioDeviceID? = selectedMicrophoneID.flatMap { id in
                availableMicrophones.first(where: { $0.id == id })?.audioDeviceID
            }

            recordingFileURL = try audioRecorder.startRecording(deviceID: deviceID)
            recordingStartTime = Date()
            appPhase = .recording
            installEscMonitors()
            streamingText = ""
            lastError = nil
            clipboardHint = nil

            let modeLabel: String
            switch inputMode {
            case .normal: modeLabel = "normal"
            case .textSelection: modeLabel = "text selection (\(contextText?.count ?? 0) chars)"
            case .screenshot: modeLabel = "screenshot"
            case .fullScreen: modeLabel = "full screen"
            }
            logger.info("Recording started in \(modeLabel) mode")
        } catch {
            lastError = "Recording failed: \(error.localizedDescription)"
            appPhase = .error
            logger.error("Recording failed: \(error.localizedDescription)")
            resetInputMode()
            resetAfterDelay()
        }
    }

    /// Screenshot flow: capture region first, then start recording
    private func startScreenshotFlow() {
        guard appPhase == .idle else { return }

        // Save frontmost app before overlay appears
        textInputService.saveFrontmostApp()

        screenCaptureService.captureRegion { [weak self] (data: Data?) in
            guard let self = self else { return }
            Task { @MainActor in
                guard let imageData = data else {
                    logger.info("Screenshot cancelled")
                    return
                }
                self.inputMode = .screenshot
                self.contextImage = imageData
                logger.info("Screenshot captured (\(imageData.count) bytes)")
                self.startRecording()
            }
        }
    }

    /// Full screen flow: silently capture entire screen, then start recording
    private func toggleFullScreenFlow() {
        logger.warning("toggleFullScreenFlow called, appPhase=\(String(describing: self.appPhase))")
        // If already recording in fullScreen mode, stop and process
        if appPhase == .recording && inputMode == .fullScreen {
            stopRecordingAndProcess()
            return
        }
        guard appPhase == .idle else {
            logger.warning("toggleFullScreenFlow: not idle, ignoring")
            return
        }

        // Save frontmost app before capture
        textInputService.saveFrontmostApp()

        screenCaptureService.captureFullScreen { [weak self] (data: Data?) in
            guard let self = self else { return }
            Task { @MainActor in
                guard let imageData = data else {
                    logger.error("Full screen capture failed")
                    return
                }
                self.inputMode = .fullScreen
                self.contextImage = imageData
                logger.info("Full screen captured (\(imageData.count) bytes)")
                self.startRecording()
            }
        }
    }

    private func stopRecordingAndProcess() {
        guard appPhase == .recording else { return }

        guard let fileURL = audioRecorder.stopRecording() else {
            resetToIdle()
            return
        }

        // Skip if recording is too short (< 0.5 seconds)
        if let start = recordingStartTime, Date().timeIntervalSince(start) < 0.5 {
            logger.info("Recording too short, skipping")
            audioRecorder.cleanup()
            resetToIdle()
            return
        }

        appPhase = .processing

        let currentMode = inputMode
        let currentContextText = contextText
        let currentContextImage = contextImage
        let currentIsEditable = isContextEditable

        // Check if we can deliver text to the previous app (for fullScreen direct-insert)
        let fullScreenCanInsert = currentMode == .fullScreen &&
            AXIsProcessTrusted() &&
            textInputService.hasPreviousApp()

        // For non-editable text selection or screenshot, show result overlay for streaming
        // For fullScreen: only show overlay if there's no previous app to paste into
        if currentMode == .screenshot || (currentMode == .fullScreen && !fullScreenCanInsert) || (currentMode == .textSelection && !currentIsEditable) {
            overlayPanel.dismiss()
            resultOverlayPanel.show(appState: self)
        } else {
            overlayPanel.show(appState: self)
        }

        logger.info("Processing audio in \(String(describing: currentMode)) mode...")

        processingTask = Task {
            defer { self.processingTask = nil }
            do {
                // Stream-type only when the previous app still has an editable text target.
                let hasPreviousApp = AXIsProcessTrusted() && textInputService.hasPreviousApp()
                // Can paste via Cmd+V as long as we have a previous app
                let canDirectlyInsertText = hasPreviousApp
                // Streaming type (character-by-character) only for native text fields that support AX
                // Browsers and fullScreen mode use paste-at-end instead
                let canStreamType = currentMode == .normal &&
                    hasPreviousApp &&
                    textInputService.canInsertTextIntoPreviousApp()
                let useStreamingType = canStreamType
                var didActivate = false
                var completionDelaySeconds = 2.0

                let vocabPrompt = vocabularyService.buildWhisperPrompt()

                let streamingResult = try await processingService.processStreaming(
                    fileURL: fileURL,
                    contextText: currentContextText,
                    contextImage: currentContextImage,
                    useReasoning: currentMode == .fullScreen,
                    vocabularyPrompt: vocabPrompt,
                    onToken: { [weak self] (token: String) in
                        guard let self = self, !Task.isCancelled else { return }
                        await MainActor.run {
                            self.streamingText += token
                        }

                        if useStreamingType {
                            if !didActivate {
                                didActivate = true
                                await MainActor.run {
                                    self.overlayPanel.dismiss()
                                    _ = self.textInputService.activatePreviousApp()
                                }
                                try? await Task.sleep(for: .milliseconds(150))
                            }
                            await MainActor.run {
                                self.textInputService.typeText(token)
                            }
                        }
                    }
                )

                let result = streamingResult.result
                let transcription = streamingResult.transcription

                try Task.checkCancellation()

                lastResult = result
                logger.info("Result: \(result.prefix(50))...")
                audioRecorder.cleanup()

                switch currentMode {
                case .normal:
                    if useStreamingType {
                        // Already typed via streaming
                        appPhase = .done
                    } else {
                        completionDelaySeconds = deliverNormalResult(
                            result,
                            canDirectlyInsertText: canDirectlyInsertText
                        )
                    }
                    // Schedule AX silent re-read for vocabulary candidate collection
                    if let transcription = transcription {
                        scheduleAXReread(originalResult: result, transcription: transcription)
                    }
                case .textSelection:
                    if currentIsEditable && AXIsProcessTrusted() {
                        deliverReplaceResult(result)
                    } else {
                        appPhase = .done
                    }
                    // Record voice correction candidate
                    if let contextText = currentContextText, let transcription = transcription {
                        recordVoiceCorrectionCandidate(
                            contextText: contextText,
                            result: result,
                            transcription: transcription
                        )
                    }
                case .screenshot:
                    appPhase = .done
                case .fullScreen:
                    if canDirectlyInsertText {
                        // Paste result into previous app via Cmd+V
                        completionDelaySeconds = deliverNormalResult(
                            result,
                            canDirectlyInsertText: true
                        )
                    } else {
                        // No previous app — result is in the overlay
                        appPhase = .done
                    }
                }

                resetInputMode()
                resetAfterDelay(seconds: completionDelaySeconds)
            } catch is CancellationError {
                logger.info("Processing cancelled by user")
                audioRecorder.cleanup()
                resetInputMode()
            } catch {
                if error is CancellationError { return }
                lastError = error.localizedDescription
                appPhase = .error
                overlayPanel.show(appState: self)
                audioRecorder.cleanup()
                resetInputMode()
                logger.error("Processing error type=\(String(describing: type(of: error)), privacy: .public) msg=\(error.localizedDescription, privacy: .public)")
                // If auth failed, update login state so UI stays consistent
                if case AuthError.notLoggedIn = error {
                    isLoggedIn = false
                    logger.error("Set isLoggedIn=false due to AuthError.notLoggedIn")
                } else if case ProcessingError.unauthorized = error {
                    isLoggedIn = false
                    logger.error("Set isLoggedIn=false due to ProcessingError.unauthorized")
                } else if case ProcessingError.noSubscription = error {
                    await handleNoSubscriptionSignal()
                    return
                }
                logger.error("Processing error: \(error.localizedDescription)")
                resetAfterDelay(seconds: 4)
            }
        }
    }

    // MARK: - Cancel

    func cancelCurrentOperation() {
        guard appPhase != .idle else { return }
        logger.info("Cancelling current operation (phase: \(String(describing: self.appPhase)))")

        switch appPhase {
        case .recording:
            _ = audioRecorder.stopRecording()
            audioRecorder.cleanup()
        case .processing, .done:
            processingTask?.cancel()
            processingTask = nil
            audioRecorder.cleanup()
        default:
            break
        }

        resetToIdle()
    }

    // MARK: - ESC Cancellation

    private func installEscMonitors() {
        removeEscMonitors()
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    let appState = Unmanaged<AppState>.fromOpaque(refcon!).takeUnretainedValue()
                    Task { @MainActor in appState.cancelCurrentOperation() }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            escGlobalMonitor = tap
        }

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.cancelCurrentOperation() }
                return nil
            }
            return event
        }
    }

    private func removeEscMonitors() {
        if let tap = escGlobalMonitor {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            escGlobalMonitor = nil
        }
        if let m = escLocalMonitor { NSEvent.removeMonitor(m); escLocalMonitor = nil }
    }

    // MARK: - Result Delivery

    private func deliverNormalResult(_ result: String, canDirectlyInsertText: Bool) -> Double {
        if canDirectlyInsertText {
            clipboardHint = nil
            appPhase = .done
            overlayPanel.dismiss()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                textInputService.pasteText(result)
            }
            return 2
        } else {
            textInputService.copyToClipboard(result)
            clipboardHint = "已复制到剪贴板 — 当前无文本焦点，Cmd+V 粘贴"
            appPhase = .done
            logger.info("Clipboard fallback used for normal dictation")
            return 4
        }
    }

    private func deliverReplaceResult(_ result: String) {
        appPhase = .done
        overlayPanel.dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            textInputService.replaceSelectedText(result)
        }
    }

    // MARK: - Vocabulary

    /// Record a voice correction candidate when user selects text and speaks a correction.
    /// Only records if transcription ≈ result (meaning GPT didn't transform — it's a correction, not an instruction).
    private func recordVoiceCorrectionCandidate(contextText: String, result: String, transcription: String) {
        // If transcription and result are very different, GPT transformed it (instruction mode) — skip
        let similarity = stringSimilarity(transcription, result)
        guard similarity > 0.6 else {
            logger.info("Skipping candidate: transcription→result similarity \(similarity) < 0.6 (likely instruction)")
            return
        }

        vocabularyService.addCandidate(
            original: contextText,
            edited: result,
            source: "voice_correction"
        )
    }

    /// Schedule AX re-read after normal dictation to detect manual edits (best effort).
    private func scheduleAXReread(originalResult: String, transcription: String) {
        guard AXIsProcessTrusted() else { return }
        let capturedResult = originalResult

        Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }

            if let nearbyText = selectionService.readNearbyText() {
                // Check if the user edited the dictated text
                let similarity = stringSimilarity(capturedResult, nearbyText)
                if similarity < 0.95 && similarity > 0.3 {
                    // Text was modified but not completely replaced — likely a correction
                    vocabularyService.addCandidate(
                        original: capturedResult,
                        edited: nearbyText,
                        source: "silent_reread"
                    )
                    logger.info("AX reread detected edit (similarity: \(similarity))")
                }
            }
        }
    }

    /// Simple string similarity (Dice coefficient on bigrams).
    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return a == b ? 1.0 : 0.0 }
        let aChars = Array(a)
        let bChars = Array(b)
        guard aChars.count > 1 && bChars.count > 1 else {
            return a == b ? 1.0 : 0.0
        }

        func bigrams(_ chars: [Character]) -> [String] {
            var result: [String] = []
            for i in 0..<(chars.count - 1) {
                result.append(String(chars[i]) + String(chars[i + 1]))
            }
            return result
        }

        let aBigrams = bigrams(aChars)
        let bBigrams = bigrams(bChars)
        var bCopy = bBigrams
        var matches = 0
        for bg in aBigrams {
            if let idx = bCopy.firstIndex(of: bg) {
                matches += 1
                bCopy.remove(at: idx)
            }
        }
        return Double(2 * matches) / Double(aBigrams.count + bBigrams.count)
    }

    /// Process pending vocabulary candidates if any exist.
    private func triggerVocabularyBatchIfNeeded() {
        guard vocabularyService.hasPendingCandidates() else { return }

        Task {
            do {
                let confirmed = try await vocabularyService.processCandidatesBatch()
                logger.info("Vocabulary batch: \(confirmed.count) entries confirmed")
            } catch {
                logger.error("Vocabulary batch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Check for pending candidates every 30 minutes.
    private func startVocabularyTimer() {
        vocabularyTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.triggerVocabularyBatchIfNeeded()
            }
        }
    }

    // MARK: - State Reset

    private func resetInputMode() {
        inputMode = .normal
        contextText = nil
        contextImage = nil
        isContextEditable = false
    }

    private func resetToIdle() {
        removeEscMonitors()
        appPhase = .idle
        overlayPanel.dismiss()
        resultOverlayPanel.dismiss()
        resetInputMode()
    }

    private func resetAfterDelay(seconds: Double = 2) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if appPhase == .done || appPhase == .error {
                removeEscMonitors()
                appPhase = .idle
                overlayPanel.dismiss()
                // Don't auto-dismiss result overlay — user closes it manually
            }
        }
    }

    // MARK: - Agent Mode

    private func toggleAgentRecording() {
        // If agent is running, cancel it and start new recording
        if agentState.phase == .agentRunning || agentState.phase == .agentWaiting {
            cancelAgent()
        }

        // If already recording for agent, stop and process
        if appPhase == .recording && inputMode == .normal && agentRecordingFileURL != nil {
            stopAgentRecordingAndProcess()
            return
        }

        startAgentRecording()
    }

    private func startAgentRecording() {
        guard appPhase == .idle || agentState.phase == .agentDone || agentState.phase == .agentError || agentState.phase == .agentCancelled else { return }

        if !isLoggedIn {
            LoginWindow.show(appState: self)
            return
        }

        if needsMicrophone {
            lastError = "Microphone permission required"
            appPhase = .error
            requestMicrophone()
            resetAfterDelay()
            return
        }

        do {
            let deviceID: AudioDeviceID? = selectedMicrophoneID.flatMap { id in
                availableMicrophones.first(where: { $0.id == id })?.audioDeviceID
            }

            agentRecordingFileURL = try audioRecorder.startRecording(deviceID: deviceID)
            agentRecordingStartTime = Date()
            appPhase = .recording
            overlayPanel.show(appState: self)
            installEscMonitors()
            logger.info("Agent recording started")
        } catch {
            lastError = "Recording failed: \(error.localizedDescription)"
            appPhase = .error
            resetAfterDelay()
        }
    }

    private func stopAgentRecordingAndProcess() {
        guard appPhase == .recording else { return }

        guard let fileURL = audioRecorder.stopRecording() else {
            resetToIdle()
            return
        }

        if let start = agentRecordingStartTime, Date().timeIntervalSince(start) < 0.5 {
            logger.info("Agent recording too short, skipping")
            audioRecorder.cleanup()
            resetToIdle()
            return
        }

        appPhase = .processing
        overlayPanel.show(appState: self)

        processingTask = Task {
            defer { self.processingTask = nil }
            do {
                let vocabPrompt = vocabularyService.buildWhisperPrompt()

                // Transcribe audio (reuse existing service, we just need the transcription)
                let streamingResult = try await processingService.processStreaming(
                    fileURL: fileURL,
                    vocabularyPrompt: vocabPrompt,
                    onToken: { _ in }
                )

                // Use the transcription as the agent command
                let transcription = streamingResult.transcription ?? streamingResult.result
                guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    appPhase = .idle
                    overlayPanel.dismiss()
                    audioRecorder.cleanup()
                    return
                }

                audioRecorder.cleanup()

                // Launch agent
                appPhase = .idle
                overlayPanel.dismiss()
                removeEscMonitors()
                runAgent(command: transcription)

            } catch is CancellationError {
                audioRecorder.cleanup()
            } catch {
                lastError = error.localizedDescription
                appPhase = .error
                audioRecorder.cleanup()
                resetAfterDelay(seconds: 4)
            }
        }
    }

    func runAgent(command: String) {
        logger.info("[AGENT] runAgent: \"\(command)\"")
        let previousTask = agentTask
        previousTask?.cancel()

        let loop = AgentLoop(agentState: agentState)
        agentLoop = loop

        agentOverlayPanel.show(agentState: agentState, appState: self)

        agentTask = Task {
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await loop.run(userMessage: command)
        }
    }

    func continueAgent(followUp: String) {
        logger.info("[AGENT] continueAgent: \"\(followUp)\", hasLoop=\(self.agentLoop != nil)")
        // Add user message to stream before anything else
        agentState.appendUserMessage(followUp)

        guard let loop = agentLoop else {
            // No existing loop, start fresh
            runAgent(command: followUp)
            return
        }

        let previousTask = agentTask
        previousTask?.cancel()
        agentTask = Task {
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else { return }
            await loop.continueConversation(followUp: followUp)
        }
    }

    func cancelAgent() {
        logger.info("[AGENT] cancelAgent")
        agentTask?.cancel()
        agentTask = nil
        agentLoop = nil
        agentState.reset()
        agentOverlayPanel.dismiss()
    }

    // MARK: - Bug Report Mode

    private var bugReportRecordingFileURL: URL?
    private var bugReportRecordingStartTime: Date?

    private func toggleBugReportRecording() {
        // If already recording for bug report, stop and process
        if appPhase == .recording && bugReportRecordingFileURL != nil {
            stopBugReportRecordingAndProcess()
            return
        }

        startBugReportRecording()
    }

    private func startBugReportRecording() {
        guard appPhase == .idle else { return }

        if !isLoggedIn {
            LoginWindow.show(appState: self)
            return
        }

        if needsMicrophone {
            lastError = "Microphone permission required"
            appPhase = .error
            requestMicrophone()
            resetAfterDelay()
            return
        }

        do {
            let deviceID: AudioDeviceID? = selectedMicrophoneID.flatMap { id in
                availableMicrophones.first(where: { $0.id == id })?.audioDeviceID
            }

            bugReportRecordingFileURL = try audioRecorder.startRecording(deviceID: deviceID)
            bugReportRecordingStartTime = Date()
            appPhase = .recording
            overlayPanel.show(appState: self)
            installEscMonitors()
            streamingText = ""
            lastError = nil
            logger.info("Bug report recording started")
        } catch {
            lastError = "Recording failed: \(error.localizedDescription)"
            appPhase = .error
            resetAfterDelay()
        }
    }

    private func stopBugReportRecordingAndProcess() {
        guard appPhase == .recording else { return }

        guard let fileURL = audioRecorder.stopRecording() else {
            resetToIdle()
            return
        }

        if let start = bugReportRecordingStartTime, Date().timeIntervalSince(start) < 0.5 {
            logger.info("Bug report recording too short, skipping")
            audioRecorder.cleanup()
            resetToIdle()
            return
        }

        appPhase = .processing
        overlayPanel.show(appState: self)

        processingTask = Task {
            defer { self.processingTask = nil }
            do {
                let vocabPrompt = vocabularyService.buildWhisperPrompt()

                // Transcribe audio
                let streamingResult = try await processingService.processStreaming(
                    fileURL: fileURL,
                    vocabularyPrompt: vocabPrompt,
                    onToken: { _ in }
                )

                let transcription = streamingResult.transcription ?? streamingResult.result
                guard !transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    appPhase = .idle
                    overlayPanel.dismiss()
                    audioRecorder.cleanup()
                    return
                }

                audioRecorder.cleanup()

                // Submit bug report to backend
                try await BugReportService.shared.submitBugReport(transcription: transcription)

                streamingText = "Bug reported: \(transcription)"
                appPhase = .done
                overlayPanel.show(appState: self)
                removeEscMonitors()
                logger.info("Bug report submitted: \(transcription.prefix(50))...")
                resetAfterDelay(seconds: 3)

            } catch is CancellationError {
                audioRecorder.cleanup()
            } catch {
                lastError = "Bug report failed: \(error.localizedDescription)"
                appPhase = .error
                audioRecorder.cleanup()
                resetAfterDelay(seconds: 4)
            }
        }

        bugReportRecordingFileURL = nil
        bugReportRecordingStartTime = nil
    }

    /// Show a reminder/notification directly in the Agent overlay panel.
    /// Does not start an agent loop — just displays the message.
    /// User can then use the follow-up input to continue the conversation if they want.
    func showReminder(message: String) {
        logger.info("[REMINDER] Showing reminder: \"\(message)\"")
        agentState.showDirectMessage(
            userMessage: "⏰ Reminder",
            finalMessage: message
        )
        agentOverlayPanel.show(agentState: agentState, appState: self)
        // Also send a system notification as a backup (in case user's screen is off)
        heartbeatScheduler.sendNotificationFallback(title: "SpeakFlow Reminder", body: message)
    }
}
