import SwiftUI

// MARK: - Agent Overlay Panel

@MainActor
final class AgentOverlayPanel: OverlayPanel {
    private var eventMonitor: Any?

    func show(agentState: AgentState, appState: AppState) {
        dismiss()

        let content = AgentOverlayView(
            agentState: agentState,
            onExpand: { [weak self] in self?.expandToFull() },
            onCollapse: { [weak self] in self?.collapseToCapsule() },
            onDismiss: { [weak self] in self?.dismiss() },
            onCancel: { [weak appState] in appState?.cancelAgent() },
            onRetry: { [weak appState] command in appState?.runAgent(command: command) },
            onFollowUp: { [weak appState] text in appState?.continueAgent(followUp: text) }
        )

        // Start as capsule — small, auto-sized
        let panel = makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            hasShadow: true
        )

        let hosting = NSHostingController(rootView: content)
        panel.contentViewController = hosting
        panel.minSize = NSSize(width: 100, height: 36)
        panel.maxSize = NSSize(width: 800, height: 900)

        panel.appearance = NSAppearance(named: .darkAqua)
        positionBottomCenter(panel)
        present(panel)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
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

    func expandToFull() {
        guard let panel = panel else { return }

        // Switch style mask to allow resizing + title bar for expanded
        panel.styleMask = [.titled, .nonactivatingPanel, .fullSizeContentView, .resizable]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true

        let newSize = NSSize(width: 480, height: 500)
        let newOrigin = NSPoint(
            x: panel.frame.midX - newSize.width / 2,
            y: panel.frame.minY
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        }

        panel.makeKey()
    }

    func collapseToCapsule() {
        guard let panel = panel else { return }

        panel.styleMask = [.nonactivatingPanel, .fullSizeContentView]
        panel.isMovableByWindowBackground = false

        let newSize = NSSize(width: 400, height: 60)
        let newOrigin = NSPoint(
            x: panel.frame.midX - newSize.width / 2,
            y: panel.frame.minY
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        }
    }
}

// MARK: - Agent Overlay View

struct AgentOverlayView: View {
    @ObservedObject var agentState: AgentState
    let onExpand: () -> Void
    let onCollapse: () -> Void
    let onDismiss: () -> Void
    let onCancel: () -> Void
    let onRetry: (String) -> Void
    let onFollowUp: (String) -> Void

    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var followUpText = ""
    @State private var responseText = ""
    @State private var expandedStepIds: Set<String> = []
    @FocusState private var isInputFocused: Bool

    var body: some View {
        Group {
            if isExpanded {
                expandedView
            } else {
                capsuleView
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: agentState.phase) { newPhase in
            if newPhase == .agentWaiting {
                expand()
            }
            if (newPhase == .agentDone || newPhase == .agentError) && isExpanded {
                isInputFocused = true
            }
        }
    }

    private func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        onExpand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isInputFocused = true
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        onCollapse()
    }

    // MARK: - Capsule View

    private var capsuleView: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            Text(capsuleTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)

            if !agentState.steps.isEmpty {
                let done = agentState.steps.filter { $0.status == .done }.count
                Text("\(done)/\(agentState.steps.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }

            if agentState.phase == .agentRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
                .background(
                    Capsule().fill(Color(white: 0.1, opacity: 0.9))
                )
                .overlay(Capsule().stroke(statusColor.opacity(0.25), lineWidth: 0.5))
        )
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .fixedSize()
        .onHover { hovering in
            isHovering = hovering
        }
        .popover(isPresented: $isHovering, arrowEdge: .top) {
            hoverPreviewContent
        }
        .onTapGesture {
            isHovering = false
            expand()
        }
    }

    private var capsuleTitle: String {
        switch agentState.phase {
        case .agentRunning:
            return agentState.currentStepDescription.isEmpty
                ? "Agent running…"
                : agentState.currentStepDescription
        case .agentWaiting: return "Agent needs input"
        case .agentDone: return "Agent done"
        case .agentError: return "Agent error"
        case .agentCancelled: return "Cancelled"
        default: return "Agent"
        }
    }

    // MARK: - Hover Preview (popover)

    private var hoverPreviewContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(headerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if agentState.phase == .agentRunning || agentState.phase == .agentDone {
                    Text(String(format: "%.1fs", agentState.elapsedTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if !agentState.steps.isEmpty {
                Divider().opacity(0.2)

                // Steps (compact)
                ForEach(agentState.steps.suffix(8)) { step in
                    HStack(spacing: 6) {
                        stepIconSmall(step.status)
                        Text(step.title)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                if agentState.steps.count > 8 {
                    Text("+\(agentState.steps.count - 8) more")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            // Final message preview
            if !agentState.finalMessage.isEmpty {
                Divider().opacity(0.2)
                Text(agentState.finalMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func stepIconSmall(_ status: StepStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.45)
                .frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                .foregroundColor(.green).frame(width: 12, height: 12)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .foregroundColor(.red).frame(width: 12, height: 12)
        case .cancelled:
            Image(systemName: "stop.fill").font(.system(size: 7))
                .foregroundColor(.white.opacity(0.4)).frame(width: 12, height: 12)
        case .pending:
            Circle().stroke(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 10, height: 10)
        }
    }

    // MARK: - Expanded View (full stream + input)

    private var expandedView: some View {
        VStack(spacing: 0) {
            expandedHeader
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider().opacity(0.3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(agentState.streamItems) { item in
                            streamItemView(item).id(item.id)
                        }

                        if agentState.phase == .agentWaiting, let question = agentState.pendingQuestion {
                            questionArea(question).id("pending-question")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: agentState.streamItems.count) { _ in
                    if let lastId = agentState.streamItems.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: agentState.phase) { newPhase in
                    if newPhase == .agentWaiting {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("pending-question", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.3)
            inputArea
            bottomBar
        }
        .background(
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: .behindWindow,
                appearance: NSAppearance(named: .darkAqua)
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    // MARK: - Stream Item Views

    @ViewBuilder
    private func streamItemView(_ item: StreamItem) -> some View {
        switch item {
        case .userMessage(_, let text):
            userMessageBubble(text)
        case .step(let stepItem):
            stepRow(stepItem)
        case .agentReply(_, let text):
            agentReplyBubble(text)
        }
    }

    private func userMessageBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func agentReplyBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundColor(.purple.opacity(0.8))
                .frame(width: 20)
            markdownText(text)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.88))
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
    }

    // MARK: - Header

    private var expandedHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                statusDot
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }

            Spacer()

            Button { collapse() } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)

            if agentState.phase == .agentRunning || agentState.phase == .agentWaiting {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var headerTitle: String {
        switch agentState.phase {
        case .agentRunning: return "Agent"
        case .agentWaiting: return "Agent needs input"
        case .agentDone: return "Agent done"
        case .agentError: return "Agent error"
        case .agentCancelled: return "Agent cancelled"
        default: return "Agent"
        }
    }

    // MARK: - Step Row

    private func stepRow(_ step: StepItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                stepIcon(step.status).frame(width: 16)
                Text(step.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(expandedStepIds.contains(step.id) ? nil : 1)
                Spacer()
                if step.detail != nil && !step.detail!.isEmpty {
                    Image(systemName: expandedStepIds.contains(step.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if step.detail != nil && !step.detail!.isEmpty {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedStepIds.contains(step.id) {
                            expandedStepIds.remove(step.id)
                        } else {
                            expandedStepIds.insert(step.id)
                        }
                    }
                }
            }

            if expandedStepIds.contains(step.id), let detail = step.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                    .padding(.top, 6).padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stepIcon(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14)).foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14)).foregroundColor(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 14)).foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Question Area

    private func questionArea(_ question: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.message)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))

            if let options = question.options {
                VStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            agentState.submitUserResponse(option)
                        } label: {
                            Text(option)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if question.type == .confirmation {
                HStack(spacing: 10) {
                    Button {
                        agentState.submitUserResponse("confirmed")
                    } label: {
                        Text("Confirm")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.3)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        agentState.submitUserResponse("cancelled")
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: 8) {
            let isRunning = agentState.phase == .agentRunning
            let isWaiting = agentState.phase == .agentWaiting && agentState.pendingQuestion?.type == .clarification

            if isWaiting {
                TextField(agentState.pendingQuestion?.message ?? "Type a reply...", text: $responseText)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                    .focused($isInputFocused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    .onSubmit {
                        guard !responseText.isEmpty else { return }
                        agentState.submitUserResponse(responseText)
                        responseText = ""
                    }
                Button {
                    guard !responseText.isEmpty else { return }
                    agentState.submitUserResponse(responseText)
                    responseText = ""
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundColor(responseText.isEmpty ? .white.opacity(0.3) : .accentColor)
                }
                .buttonStyle(.plain).disabled(responseText.isEmpty)
            } else {
                TextField(
                    isRunning ? "Agent running..." : "Continue the conversation...",
                    text: $followUpText
                )
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                .focused($isInputFocused)
                .disabled(isRunning)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                .onSubmit { sendFollowUp() }

                Button { sendFollowUp() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundColor(followUpText.isEmpty || isRunning ? .white.opacity(0.3) : .accentColor)
                }
                .buttonStyle(.plain).disabled(followUpText.isEmpty || isRunning)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func sendFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""
        onFollowUp(text)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            let done = agentState.steps.filter { $0.status == .done }.count
            let total = agentState.steps.count
            if total > 0 {
                Text("\(done)/\(total) · \(String(format: "%.1f", agentState.elapsedTime))s")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            if agentState.phase == .agentDone || agentState.phase == .agentError || agentState.phase == .agentCancelled {
                Button { onRetry(agentState.userMessage) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        Text("Retry").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            if agentState.phase == .agentRunning {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Markdown

    private func markdownText(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }

    // MARK: - Status

    private var statusDot: some View {
        ZStack {
            Circle().fill(statusColor.opacity(0.2)).frame(width: 16, height: 16)
            Circle().fill(statusColor).frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.5), radius: 3)
        }
    }

    private var statusColor: Color {
        switch agentState.phase {
        case .agentRunning: return .blue
        case .agentWaiting: return .orange
        case .agentDone: return .green
        case .agentError: return .red
        case .agentCancelled: return .gray
        default: return .blue
        }
    }
}
