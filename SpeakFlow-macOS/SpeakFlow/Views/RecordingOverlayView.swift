import SwiftUI

// MARK: - Overlay Panel Controller

@MainActor
final class RecordingOverlayPanel: OverlayPanel {
    func show(appState: AppState) {
        if let panel = panel {
            panel.orderFrontRegardless()
            return
        }

        let content = RecordingOverlayView()
            .environmentObject(appState)

        let hosting = NSHostingController(rootView: content)

        // Use a fixed content rect; the capsule view sizes itself via .fixedSize().
        // Avoid sizeThatFits() here — it triggers a layout pass that conflicts
        // with the panel's own layout, causing _NSDetectedLayoutRecursion.
        let panel = makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60)
        )
        panel.contentViewController = hosting
        positionBottomCenter(panel)
        present(panel)
    }
}

// MARK: - Recording Overlay Content

struct RecordingOverlayView: View {

    private enum Constants {
        static let timerInterval: TimeInterval = 0.05
        static let fastDecayTimeConstant: Double = 0.8
        static let fastAsymptote: CGFloat = 0.95
        static let slowOnsetDelay: Double = 2.0
        static let slowTimeConstant: Double = 10.0
        static let slowContribution: CGFloat = 0.03
        static let progressCap: CGFloat = 0.98
        static let dotCycleRate: Int = 8
        static let dotMaxCount: Int = 3
        static let transitionDuration: Double = 0.3
    }

    @EnvironmentObject var appState: AppState
    @State private var animationPhase = 0
    @State private var timer: Timer?
    @State private var progress: CGFloat = 0
    @State private var progressStartTime: Date?

    private var isProcessing: Bool { appState.appPhase == .processing }

    var body: some View {
        OverlayCapsuleView(
            icon: capsuleIcon,
            text: overlayText,
            stableText: stableOverlayText,
            progress: isProcessing ? progress : nil
        )
        .animation(.easeInOut(duration: Constants.transitionDuration), value: appState.appPhase)
        .onAppear { startAnimations() }
        .onDisappear { stopTimer() }
        .onChange(of: appState.appPhase) { handlePhaseChange($0) }
    }

    // MARK: - Icon

    private var capsuleIcon: OverlayCapsuleView.CapsuleIcon? {
        switch appState.appPhase {
        case .recording:
            return .pulse(systemName: "mic.fill", color: .red)
        case .done:
            if appState.clipboardHint != nil {
                return .plain(systemName: "doc.on.clipboard.fill", color: .blue)
            }
            return .plain(systemName: "checkmark.circle.fill", color: .green)
        case .error:
            return .plain(systemName: "exclamationmark.circle.fill", color: .orange)
        case .processing:
            return nil
        case .idle:
            return .plain(systemName: "mic.fill", color: .white.opacity(0.7))
        }
    }

    // MARK: - Text

    private var dots: String {
        String(repeating: ".", count: ((animationPhase / Constants.dotCycleRate) % Constants.dotMaxCount) + 1)
    }

    private var overlayText: String {
        overlayLabel(dots: dots)
    }

    private var stableOverlayText: String {
        overlayLabel(dots: "...")
    }

    private func overlayLabel(dots: String) -> String {
        switch appState.appPhase {
        case .idle:
            return "Ready"
        case .recording:
            return recordingLabel(dots: dots)
        case .processing:
            return "Thinking\(dots)"
        case .done:
            return appState.clipboardHint ?? "Done"
        case .error:
            return appState.lastError ?? "Error"
        }
    }

    private func recordingLabel(dots: String) -> String {
        switch appState.inputMode {
        case .textSelection:
            let count = appState.contextText?.count ?? 0
            return "已选中 \(count) 字 — 请说指令\(dots)"
        case .screenshot:
            return "已截图 — 请说指令\(dots)"
        case .fullScreen:
            return "已截屏 — 请说指令\(dots)"
        case .normal:
            return "Listening\(dots)"
        }
    }

    // MARK: - Progress

    private func progressValue(elapsed t: TimeInterval) -> CGFloat {
        let fast = Constants.fastAsymptote * (1 - exp(-pow(t / Constants.fastDecayTimeConstant, 2)))
        if t <= Constants.slowOnsetDelay {
            return fast
        }
        return min(Constants.progressCap, fast + Constants.slowContribution * (1 - exp(-(t - Constants.slowOnsetDelay) / Constants.slowTimeConstant)))
    }

    // MARK: - Lifecycle

    private func startAnimations() {
        if appState.appPhase == .processing {
            progress = 0
            progressStartTime = Date()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Constants.timerInterval, repeats: true) { _ in
            DispatchQueue.main.async {
                animationPhase += 1
                if appState.appPhase == .processing, let start = progressStartTime {
                    progress = progressValue(elapsed: Date().timeIntervalSince(start))
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func handlePhaseChange(_ newPhase: AppPhase) {
        if newPhase == .processing {
            progress = 0
            progressStartTime = Date()
        } else {
            progressStartTime = nil
        }
    }
}
