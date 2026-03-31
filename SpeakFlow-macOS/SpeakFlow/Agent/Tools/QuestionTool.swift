import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "QuestionTool")

final class QuestionTool: AgentTool {
    let name = "question"
    let description = "Ask the user a question, request confirmation, or present options. The agent loop pauses until the user responds."

    let parameters: [String: Any] = [
        "type": "object",
        "properties": [
            "message": [
                "type": "string",
                "description": "The question or message to show the user"
            ],
            "type": [
                "type": "string",
                "enum": ["confirmation", "clarification", "selection"],
                "description": "Type of question: confirmation (yes/no), clarification (free text), or selection (pick from options)"
            ],
            "options": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Options for selection type questions"
            ]
        ],
        "required": ["message", "type"]
    ]

    private weak var agentState: AgentState?

    init(agentState: AgentState) {
        self.agentState = agentState
    }

    func execute(arguments: String) async throws -> String {
        let args = try parseArguments(arguments)
        guard let message = args["message"] as? String else {
            throw AgentToolError.invalidArguments("Missing 'message' parameter")
        }
        guard let typeString = args["type"] as? String,
              let questionType = PendingQuestion.QuestionType(rawValue: typeString) else {
            throw AgentToolError.invalidArguments("Invalid or missing 'type' parameter")
        }

        let options = args["options"] as? [String]

        logger.info("Presenting question to user (type: \(typeString)): \(message)")

        guard let state = agentState else {
            logger.error("Question tool: AgentState not available")
            throw AgentToolError.executionFailed("AgentState not available")
        }

        await MainActor.run {
            state.pendingQuestion = PendingQuestion(
                message: message,
                type: questionType,
                options: options
            )
            state.phase = .agentWaiting
        }

        let response = await state.waitForUserResponse()
        logger.info("Question answered by user")
        return response
    }
}
