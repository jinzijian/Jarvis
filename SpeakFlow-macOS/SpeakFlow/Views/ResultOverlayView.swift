import SwiftUI

@MainActor
final class ResultOverlayPanel: OverlayPanel {
    private var eventMonitor: Any?

    func show(appState: AppState) {
        dismiss()

        let content = ResultOverlayView(onDismiss: { [weak self] in
            self?.dismiss()
        })
        .environmentObject(appState)

        let hosting = NSHostingController(rootView: content)

        let panel = makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView, .resizable],
            hasShadow: true
        )
        panel.isMovableByWindowBackground = true
        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Hide traffic light buttons — we have our own close button
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = hosting
        panel.minSize = NSSize(width: 300, height: 150)
        panel.maxSize = NSSize(width: 640, height: 520)

        positionBottomCenter(panel)
        present(panel)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    override func dismiss() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        super.dismiss()
    }
}

/// NSVisualEffectView wrapper for native macOS frosted-glass background
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var appearance: NSAppearance? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.appearance = appearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = appearance
    }
}

struct ResultOverlayView: View {
    @EnvironmentObject var appState: AppState
    let onDismiss: () -> Void

    @State private var copied = false
    @State private var copyHover = false
    @State private var closeHover = false

    private var displayText: String {
        if appState.appPhase == .processing {
            return appState.streamingText.isEmpty ? "Thinking..." : appState.streamingText
        }
        return appState.lastResult ?? appState.streamingText
    }

    private var isProcessing: Bool {
        appState.appPhase == .processing
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill((isProcessing ? Color.orange : Color.green).opacity(0.2))
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(isProcessing ? Color.orange : Color.green)
                            .frame(width: 8, height: 8)
                            .shadow(color: (isProcessing ? Color.orange : Color.green).opacity(0.5), radius: 3)
                    }
                    Text(isProcessing ? "Processing..." : "Result")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.85))
                }

                Spacer()

                // Close button
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(closeHover ? 0.12 : 0))
                        )
                }
                .buttonStyle(.plain)
                .onHover { closeHover = $0 }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Result text area
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading) {
                        Text(displayText)
                            .font(.system(size: 13.5, weight: .regular, design: .default))
                            .foregroundColor(.primary.opacity(0.88))
                            .textSelection(.enabled)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("resultText")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .onChange(of: displayText) { _ in
                        if appState.appPhase == .processing {
                            proxy.scrollTo("resultText", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Bottom toolbar
            HStack(spacing: 10) {
                Button(action: copyResult) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(copied ? "Copied!" : "Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(copied ? .green : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(copyHover ? 0.1 : 0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(copyHover ? 0.12 : 0.06), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .onHover { copyHover = $0 }

                Spacer()

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 460, height: 340)
        .background(
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
    }

    private func copyResult() {
        let text = appState.lastResult ?? appState.streamingText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
