import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AgentState")

enum AgentPhase {
    case idle
    case recording
    case agentRunning
    case agentWaiting
    case agentDone
    case agentError
    case agentCancelled
}

@MainActor
final class AgentState: ObservableObject {
    @Published var phase: AgentPhase = .idle {
        didSet {
            logger.info("Agent phase transition: \(String(describing: oldValue)) -> \(String(describing: self.phase))")
        }
    }
    @Published var steps: [StepItem] = []
    @Published var streamItems: [StreamItem] = []
    @Published var currentStepDescription: String = ""
    @Published var userMessage: String = ""
    @Published var finalMessage: String = ""
    @Published var pendingQuestion: PendingQuestion? = nil
    @Published var elapsedTime: TimeInterval = 0

    private var questionContinuation: CheckedContinuation<String, Never>?
    private var timer: Timer?

    // MARK: - User Interaction

    func waitForUserResponse() async -> String {
        logger.info("Waiting for user response")
        let response = await withCheckedContinuation { continuation in
            questionContinuation = continuation
        }
        logger.info("User response received")
        return response
    }

    func submitUserResponse(_ response: String) {
        pendingQuestion = nil
        let continuation = questionContinuation
        questionContinuation = nil
        continuation?.resume(returning: response)
    }

    // MARK: - Step Management

    func addStep(id: String, title: String, toolCallId: String? = nil) {
        logger.info("Adding step: \(title) (id: \(id))")
        let step = StepItem(id: id, title: title, status: .running, toolCallId: toolCallId)
        steps.append(step)
        streamItems.append(.step(step))
        currentStepDescription = title
    }

    func updateStep(id: String, status: StepStatus, detail: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else {
            logger.warning("Step not found for update: \(id)")
            return
        }
        logger.info("Updating step \(id) to status: \(String(describing: status))")
        steps[index].status = status
        if let detail = detail {
            steps[index].detail = detail
        }
        if status == .running {
            currentStepDescription = steps[index].title
        }
        // Update matching stream item
        if let streamIndex = streamItems.firstIndex(where: {
            if case .step(let s) = $0 { return s.id == id }
            return false
        }) {
            streamItems[streamIndex] = .step(steps[index])
        }
    }

    func appendUserMessage(_ text: String) {
        streamItems.append(.userMessage(text: text))
    }

    func appendAgentReply(_ text: String) {
        streamItems.append(.agentReply(text: text))
    }

    func cancelPendingSteps() {
        logger.info("Cancelling all pending/running steps")
        for i in steps.indices where steps[i].status == .pending || steps[i].status == .running {
            steps[i].status = .cancelled
        }
    }

    // MARK: - Timer

    func startTimer() {
        elapsedTime = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedTime += 0.1
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Direct Message (no agent loop)

    /// Show a message directly in the overlay without running an agent loop.
    /// Used for heartbeat reminders and similar non-agent notifications.
    func showDirectMessage(userMessage msg: String, finalMessage: String) {
        reset()
        self.userMessage = msg
        self.finalMessage = finalMessage
        self.phase = .agentDone
    }

    // MARK: - Reset

    func reset() {
        logger.info("Resetting agent state")
        phase = .idle
        steps = []
        streamItems = []
        currentStepDescription = ""
        userMessage = ""
        finalMessage = ""
        pendingQuestion = nil
        elapsedTime = 0
        stopTimer()

        if let continuation = questionContinuation {
            questionContinuation = nil
            continuation.resume(returning: "")
        }
    }
}
