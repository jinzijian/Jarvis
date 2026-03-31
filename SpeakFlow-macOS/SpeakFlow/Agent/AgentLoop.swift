import Foundation
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "AgentLoop")

@MainActor
final class AgentLoop {
    private let apiClient = AgentAPIClient()
    private let agentState: AgentState
    private let toolRegistry: ToolRegistry
    /// Max iterations per single turn (run or follow-up), not cumulative.
    private let maxIterationsPerTurn = 30
    /// How many recent screenshots to keep in full (older ones get stripped).
    private let maxRecentScreenshots = 1

    /// Accumulated messages for multi-turn conversation
    private var messages: [AgentMessage] = []
    private var turnIterations = 0
    private var promptCacheKey: String?

    private var composioToolsLoaded = false

    init(agentState: AgentState) {
        self.agentState = agentState
        self.toolRegistry = ToolRegistry(agentState: agentState)
    }

    /// Load Composio tools (proxied through backend). Called before first run.
    private func ensureComposioTools() async {
        guard !composioToolsLoaded else { return }
        composioToolsLoaded = true
        debugLog("[COMPOSIO] Starting tool fetch...")
        do {
            let composioTools = try await ComposioService.shared.fetchTools()
            debugLog("[COMPOSIO] Fetched \(composioTools.count) tools from backend")
            for tool in composioTools {
                toolRegistry.registerTool(tool)
            }
            if composioTools.isEmpty {
                debugLog("[COMPOSIO] WARNING: 0 tools returned — user may not have connected any apps")
            }
        } catch AuthError.notLoggedIn {
            debugLog("[COMPOSIO] Skipped: user not logged in")
        } catch {
            debugLog("[COMPOSIO] FAILED to load tools: \(error.localizedDescription)")
            logger.error("[COMPOSIO] Tool fetch failed: \(error.localizedDescription)")
        }
    }

    /// Write debug info to a file (bypasses macOS log privacy)
    private func debugLog(_ message: String) {
        logger.info("\(message)")
        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".speakflow/agent_debug.log")
        let line = "\(Date()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    func run(userMessage: String) async {
        logger.info("[RUN] New agent session: \"\(userMessage)\"")
        promptCacheKey = "agent:\(UUID().uuidString.lowercased())"
        await MainActor.run {
            agentState.reset()
            agentState.userMessage = userMessage
            agentState.appendUserMessage(userMessage)
            agentState.phase = .agentRunning
            agentState.startTimer()
        }

        let systemPrompt = buildSystemPrompt()
        messages = [
            AgentMessage(role: .system, content: systemPrompt),
            AgentMessage(role: .user, content: userMessage),
        ]

        await ensureComposioTools()
        await executeLoop(command: userMessage)
    }

    /// Continue the conversation with a follow-up message, preserving history.
    func continueConversation(followUp: String) async {
        if promptCacheKey == nil {
            promptCacheKey = "agent:\(UUID().uuidString.lowercased())"
        }
        logger.info("[FOLLOW-UP] Continue conversation (history=\(self.messages.count) msgs): \"\(followUp)\"")
        await MainActor.run {
            agentState.phase = .agentRunning
            agentState.startTimer()
        }

        messages.append(AgentMessage(role: .user, content: followUp))

        await executeLoop(command: followUp)
    }

    private func executeLoop(command: String) async {
        turnIterations = 0
        logger.info("[LOOP] Starting executeLoop")

        while !Task.isCancelled {
            turnIterations += 1
            if turnIterations > maxIterationsPerTurn {
                logger.warning("Agent reached max iterations per turn (\(self.maxIterationsPerTurn))")
                await MainActor.run {
                    agentState.finalMessage = "Agent reached maximum iterations, stopped."
                    agentState.phase = .agentError
                    agentState.stopTimer()
                }
                saveHistory(command: command, status: "error")
                return
            }

            await MainActor.run {
                agentState.phase = .agentRunning
            }

            // Ensure the transcript is still valid before the next model call.
            sanitizeMessages()

            // Strip old image data from messages to prevent token explosion
            compactImageHistory()

            await syncMCPTools()
            let allTools = toolRegistry.allDefinitions()
            logger.info("[LOOP] Iteration \(self.turnIterations)/\(self.maxIterationsPerTurn), tools=\(allTools.count)")

            let response: AgentChatResponse
            do {
                response = try await apiClient.chat(
                    messages: messages,
                    tools: allTools,
                    promptCacheKey: promptCacheKey
                )
            } catch {
                logger.error("Agent API error: \(error.localizedDescription)")
                await MainActor.run {
                    agentState.finalMessage = "Request failed: \(error.localizedDescription)"
                    agentState.phase = .agentError
                    agentState.stopTimer()
                }
                saveHistory(command: command, status: "error")
                return
            }

            if let usage = response.usage {
                let cached = usage.cachedPromptTokens ?? 0
                let prompt = usage.promptTokens ?? 0
                if cached > 0 {
                    logger.info("[CACHE] prompt cache hit: \(cached)/\(prompt) prompt tokens")
                } else {
                    logger.info("[CACHE] prompt cache miss: prompt_tokens=\(prompt)")
                }
            }

            guard let toolCalls = response.message.toolCalls, !toolCalls.isEmpty else {
                // No tool calls = task complete
                let finalMsg = response.message.content?.textValue ?? ""
                logger.info("[DONE] Agent finished. Final: \(finalMsg.prefix(100))")
                await MainActor.run {
                    agentState.finalMessage = finalMsg
                    if !finalMsg.isEmpty {
                        agentState.appendAgentReply(finalMsg)
                    }
                    agentState.phase = .agentDone
                    agentState.stopTimer()
                }
                // Keep assistant response in messages for future follow-ups
                messages.append(response.message)
                saveHistory(command: command, status: "done")
                return
            }

            // Extract step description from assistant content
            if let text = response.message.content?.textValue, !text.isEmpty {
                await MainActor.run {
                    agentState.currentStepDescription = text
                }
            }

            // Append assistant message (with tool calls)
            messages.append(response.message)

            // Execute each tool call.
            // Deferred messages (e.g. screenshot images) are appended only after
            // all tool results so the transcript stays assistant -> tool* -> user.
            var deferredMessages: [AgentMessage] = []
            for call in toolCalls {
                guard !Task.isCancelled else { break }

                let stepId = call.id
                let stepTitle = response.message.content?.textValue ?? fallbackStepTitle(call)

                await MainActor.run {
                    agentState.addStep(id: stepId, title: stepTitle, toolCallId: call.id)
                }

                do {
                    logger.info("[TOOL] Calling \(call.function.name) args=\(call.function.arguments.prefix(120))")
                    let result = try await toolRegistry.execute(
                        name: call.function.name,
                        arguments: call.function.arguments
                    )
                    logger.info("[TOOL] \(call.function.name) OK, result=\(result.count) chars")

                    // view_file results: PDF → file content part, image → image_url content part
                    if call.function.name == "view_file", result.hasPrefix("data:") {
                        // Parse filename from "data:mime;name=xxx;base64,..."
                        let filename: String = {
                            if let nameRange = result.range(of: "name="),
                               let semiRange = result[nameRange.upperBound...].range(of: ";") {
                                return String(result[nameRange.upperBound..<semiRange.lowerBound])
                            }
                            return "file"
                        }()

                        if result.hasPrefix("data:application/pdf;") {
                            // PDF → file content part
                            let fileDataUrl: String = {
                                if let base64Range = result.range(of: ";base64,") {
                                    return "data:application/pdf;base64," + result[base64Range.upperBound...]
                                }
                                return result
                            }()

                            messages.append(AgentMessage(
                                role: .tool,
                                content: "PDF loaded successfully (\(filename)). The file is attached in the next message for your analysis.",
                                toolCallId: call.id
                            ))

                            deferredMessages.append(AgentMessage(
                                role: .user,
                                contentParts: [
                                    .text("Here is the PDF file (\(filename)). Analyze it to complete the user's request."),
                                    .file(data: fileDataUrl, filename: filename),
                                ]
                            ))

                            logger.info("[TOOL] view_file PDF: \(filename) deferred as file content")
                        } else {
                            // Image → image_url content part
                            let imageDataUrl: String = {
                                // Strip the name= part to get clean data URI
                                guard let mimeEnd = result.range(of: ";name="),
                                      let base64Start = result.range(of: ";base64,") else {
                                    return result
                                }
                                return String(result[result.startIndex..<mimeEnd.lowerBound]) + String(result[base64Start.lowerBound...])
                            }()

                            messages.append(AgentMessage(
                                role: .tool,
                                content: "Image loaded successfully (\(filename)). The image is attached in the next message for your analysis.",
                                toolCallId: call.id
                            ))

                            deferredMessages.append(AgentMessage(
                                role: .user,
                                contentParts: [
                                    .text("Here is the image file (\(filename)). Analyze it to complete the user's request."),
                                    .imageUrl(imageDataUrl, detail: "high"),
                                ]
                            ))

                            logger.info("[TOOL] view_file image: \(filename) deferred as image content")
                        }

                        await MainActor.run {
                            agentState.updateStep(id: stepId, status: .done, detail: "Loaded: \(filename)")
                        }
                    }
                    // Screenshot results: keep the tool response text-only and
                    // send the image as a follow-up user message after all tool
                    // results for this assistant block.
                    else if (call.function.name == "screenshot" || call.function.name == "browser"), result.hasPrefix("data:image/") {
                        let imageDataUrl = result
                        messages.append(AgentMessage(
                            role: .tool,
                            content: "Screenshot captured successfully. The image is attached in the next message for your analysis.",
                            toolCallId: call.id
                        ))

                        deferredMessages.append(AgentMessage(
                            role: .user,
                            contentParts: [
                                .text("Here is the screenshot you just captured. Analyze it to complete the user's request."),
                                .imageUrl(imageDataUrl, detail: "low"),
                            ]
                        ))

                        logger.info("[TOOL] Screenshot: text in tool result, image deferred (detail=low)")

                        await MainActor.run {
                            agentState.updateStep(id: stepId, status: .done, detail: "Screenshot captured")
                        }
                    } else {
                        messages.append(AgentMessage(
                            role: .tool,
                            content: result,
                            toolCallId: call.id
                        ))

                        await MainActor.run {
                            agentState.updateStep(id: stepId, status: .done, detail: truncateDetail(result))
                        }
                    }

                } catch {
                    let errorResult = "Error: \(error.localizedDescription)"

                    messages.append(AgentMessage(
                        role: .tool,
                        content: errorResult,
                        toolCallId: call.id
                    ))

                    await MainActor.run {
                        agentState.updateStep(id: stepId, status: .failed, detail: errorResult)
                    }

                    logger.warning("Tool \(call.function.name) failed: \(error.localizedDescription)")
                }
            }

            messages.append(contentsOf: deferredMessages)

            // If cancelled mid-loop, ensure all tool_calls have results before exiting
            if Task.isCancelled {
                sanitizeMessages()
            }
        }

        // Cancelled
        await MainActor.run {
            agentState.cancelPendingSteps()
            agentState.phase = .agentCancelled
            agentState.stopTimer()
        }
        saveHistory(command: command, status: "cancelled")
    }

    private func syncMCPTools() async {
        await MainActor.run {
            MCPServerManager.shared.registerTools(in: toolRegistry)
        }
    }

    private func saveHistory(command: String, status: String) {
        Task { @MainActor in
            AgentHistory.shared.add(
                command: command,
                result: agentState.finalMessage.isEmpty ? nil : agentState.finalMessage,
                status: status,
                steps: agentState.steps,
                elapsedTime: agentState.elapsedTime
            )
        }
    }

    private func fallbackStepTitle(_ call: AgentToolCall) -> String {
        let name = call.function.name
        let argsPreview = String(call.function.arguments.prefix(60))
        return "\(name): \(argsPreview)"
    }

    private func truncateDetail(_ text: String, maxLength: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // For JSON-like content, provide a brief summary
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let lineCount = trimmed.components(separatedBy: "\n").count
            let charCount = trimmed.count
            if charCount > maxLength {
                return "JSON result (\(lineCount) lines, \(charCount) chars)"
            }
        }
        // Take first line only for multi-line content
        if let firstLine = trimmed.components(separatedBy: "\n").first, trimmed.contains("\n") {
            let preview = firstLine.count > maxLength ? String(firstLine.prefix(maxLength)) + "..." : firstLine
            let totalLines = trimmed.components(separatedBy: "\n").count
            return totalLines > 1 ? "\(preview) (+\(totalLines - 1) lines)" : preview
        }
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
    }

    // MARK: - Message Validation

    /// Rebuild the transcript so every assistant message with tool calls is
    /// followed immediately by exactly one tool result per call. This is a
    /// defensive repair path for cancellation and other edge cases.
    private func sanitizeMessages() {
        let originalCount = messages.count
        messages = Self.sanitizeMessageSequence(messages)
        if messages.count != originalCount {
            logger.warning("[SANITIZE] Adjusted transcript message count: \(originalCount) -> \(self.messages.count)")
        }
    }

    static func sanitizeMessageSequence(_ source: [AgentMessage]) -> [AgentMessage] {
        var sanitized: [AgentMessage] = []
        var consumedToolIndexes = Set<Int>()
        var i = 0

        func firstUnconsumedToolIndex(
            in range: Range<Int>,
            matching toolCallId: String
        ) -> Int? {
            for index in range {
                guard !consumedToolIndexes.contains(index) else { continue }
                guard source[index].role == .tool else { continue }
                guard source[index].toolCallId == toolCallId else { continue }
                return index
            }
            return nil
        }

        while i < source.count {
            let message = source[i]

            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else {
                if message.role != .tool {
                    sanitized.append(message)
                }
                i += 1
                continue
            }

            sanitized.append(message)

            var blockEnd = i + 1
            while blockEnd < source.count, source[blockEnd].role != .assistant {
                blockEnd += 1
            }

            let contiguousToolRange: Range<Int> = {
                var upperBound = i + 1
                while upperBound < source.count, source[upperBound].role == .tool {
                    upperBound += 1
                }
                return (i + 1)..<upperBound
            }()

            for call in toolCalls {
                let toolIndex =
                    firstUnconsumedToolIndex(in: contiguousToolRange, matching: call.id)
                    ?? firstUnconsumedToolIndex(in: contiguousToolRange.upperBound..<blockEnd, matching: call.id)

                if let toolIndex {
                    sanitized.append(source[toolIndex])
                    consumedToolIndexes.insert(toolIndex)
                } else {
                    sanitized.append(AgentMessage(
                        role: .tool,
                        content: "[Cancelled before execution]",
                        toolCallId: call.id
                    ))
                }
            }

            if contiguousToolRange.upperBound < blockEnd {
                for index in contiguousToolRange.upperBound..<blockEnd {
                    if source[index].role != .tool {
                        sanitized.append(source[index])
                    }
                }
            }

            i = blockEnd
        }

        return sanitized
    }

    // MARK: - Image & Context Compaction

    /// Strip old image data from messages to prevent token explosion.
    /// Keeps only the N most recent screenshot images; older ones get replaced with text.
    /// Also truncates oversized tool results (>50K chars).
    private func compactImageHistory() {
        let maxToolResultLength = 50_000

        // Find indices of all messages containing images
        var imageIndices: [Int] = []
        for i in 0..<messages.count {
            if let content = messages[i].content, content.hasImage {
                imageIndices.append(i)
            }
        }

        // Strip all but the N most recent images
        if imageIndices.count > maxRecentScreenshots {
            let toStrip = imageIndices.dropLast(maxRecentScreenshots)
            for i in toStrip {
                messages[i] = AgentMessage(
                    role: messages[i].role,
                    messageContent: messages[i].content?.withoutImages,
                    toolCalls: messages[i].toolCalls,
                    toolCallId: messages[i].toolCallId
                )
                logger.info("[COMPACT] Stripped image from message[\(i)]")
            }
        }

        // Truncate oversized text tool results
        for i in 0..<messages.count {
            guard messages[i].role == .tool,
                  let content = messages[i].content,
                  !content.hasImage else { continue }

            let text = content.textValue
            if text.count > maxToolResultLength {
                let truncated = String(text.prefix(maxToolResultLength)) + "\n...[truncated, \(text.count) chars total]"
                messages[i] = AgentMessage(
                    role: .tool,
                    content: truncated,
                    toolCallId: messages[i].toolCallId
                )
                logger.info("[COMPACT] Truncated tool result at message[\(i)]: \(text.count) → \(maxToolResultLength) chars")
            }
        }
    }

    private func buildSystemPrompt() -> String {
        var prompt = """
        你是 SpeakFlow Agent，一个运行在 macOS 上的语音驱动助手。
        用户通过语音给你指令，你用最少的步骤完成任务。
        当前时间：\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]))
        用户时区：\(TimeZone.current.identifier)

        ## 核心行为

        1. **直接执行** → 不要反问、不要确认，直接做。用户说"查邮件"就直接查，不要问"你是想查未读邮件吗"
        2. **生成的文本内容** → 复制到剪贴板，告诉用户"已复制到剪贴板"
        3. **打开 app/网页/文件** → 直接打开，不需要确认
        4. **只有真正不可逆的操作** → 先用 question tool 确认（如：删除文件、发送邮件给他人）
        5. **回答简洁** → 用户是语音场景，不想看长篇大论，几句话说清楚
        6. **复杂任务自己写脚本** → 遇到批量操作、数据处理等，直接用 bash 写脚本执行
        7. **读取类操作不需要确认** → 查邮件、查日历、看 GitHub PR 等只读操作，直接执行

        ## 步骤描述

        每次调用 tool 前，在 content 中用一句自然语言描述你正在做什么。
        用户能看到这个描述，所以要人类可读，不要暴露 tool 名称或技术细节。
        - 好："搜索最近的 GitHub PR"
        - 坏："执行 bash: gh pr list --limit 10"

        ## 安全规则

        以下命令禁止执行，如果任务需要，用 question tool 告知用户风险并请求确认：
        - rm -rf（带递归强制删除）
        - sudo 开头的命令
        - 涉及 /System、/usr、/bin 等系统目录的写操作
        - curl | sh / curl | bash（远程脚本执行）

        ## 可用工具

        你有以下工具可用。**优先级从高到低**：
        1. **Composio 工具**（composio_ 开头）— 直接调用第三方 API，最快最可靠
        2. **MCP 工具**（mcp_ 开头）— MCP 服务器提供的工具
        3. **browser** — 操控独立浏览器，适合需要网页交互的任务
        4. **内置工具** — bash, read, write 等

        ### Composio 集成工具
        如果工具列表中有 composio_ 开头的工具（如 composio_GMAIL_FETCH_EMAILS），
        **必须优先使用**而不是浏览器。这些工具通过 OAuth 直接调用 API，速度快且可靠。
        只有工具列表中实际存在的 composio_ 工具才能调用。

        ### 浏览器操控（browser tool）
        SpeakFlow 有一个独立的后台浏览器（不影响用户日常使用的 Chrome），登录态自动保存。

        **核心流程：snapshot → 用 ref 操作 → snapshot 确认**
        1. 先 navigate 到目标网站（会自动返回 snapshot）
        2. 从 snapshot 中找到目标元素的 ref（e1, e2, e3...）
        3. 用 ref 执行 click/type（如 click ref=”e3”）
        4. 操作后会自动返回新 snapshot，确认操作结果
        5. 如果需要登录，用 login action 弹出窗口让用户手动登录

        **重要规则：**
        - 用 snapshot（快，文本）而不是 screenshot（慢，图片）来理解页面
        - 每次 click/type 后自动返回新 snapshot，不需要手动再取
        - 保持使用 snapshot 返回的 ref，不要猜 CSS selector
        - 需要登录时用 login action，然后用 question tool 确认用户登录完成

        ### 内置工具
        - bash: 执行 shell 命令。复杂任务可以写脚本。超时 30s。
        - view_file: 查看 PDF 或图片文件。模型可以直接看到文件内容（文字、表格、图表、照片、扫描件都支持）。支持 .pdf, .jpg, .png, .gif, .webp, .heic, .tiff, .bmp
        - read: 读取纯文本文件内容
        - write: 创建/覆盖文件
        - edit: 精确替换文件中的字符串
        - glob: 按模式搜索文件名
        - grep: 按正则搜索文件内容
        - ls: 列出目录内容
        - webfetch: 抓取网页内容（HTML→文本）
        - screenshot: 截取屏幕截图，用于了解用户当前屏幕上下文。参数：
          - display: “all”（所有屏幕拼接，默认）/ “main”（仅主屏）/ “mouse”（鼠标所在屏幕）/ 数字（指定屏幕序号）
          截图是只读的上下文参考，帮你理解用户在做什么。
          优先通过命令行和代码脚本完成任务，而不是 GUI 操作。
        - question: 向用户提问、请求确认、提供选项。type 可选：
          - confirmation: 确认操作（显示 [确认]/[取消] 按钮）
          - clarification: 追问信息（显示输入框）
          - selection: 让用户选择（显示选项列表）
        - memory: 长期记忆，跨 session 记住用户信息
          - save(key, value): 保存记忆（如 “老板” → “张三”）
          - get(key): 读取特定记忆
          - list(): 列出所有记忆
          - delete(key): 删除记忆
          - search(query): 搜索记忆
          - 主动判断什么时候该记住（用户提到人名、偏好、常用信息时）
        - heartbeat: 注册定时/延迟/重复任务
          - schedule: 创建定时任务（需要 trigger_at, message, trigger_action）
          - trigger_at: 触发时间（ISO 8601 或相对时间如 +10m, +2h）
          - repeat_rule: null（一次性）/ “daily” / “weekly” / “hourly” / “30m”
          - trigger_action: “notify”（推通知）/ “agent”（重新唤醒 agent 执行任务）
          - list: 查看所有定时任务
          - cancel: 取消任务（需要 id）

        """

        // Inject user memories into system prompt
        if let memorySection = MemoryStore.shared.systemPromptSection() {
            prompt += "\n\n" + memorySection
        }

        return prompt
    }
}
