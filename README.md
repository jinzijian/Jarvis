# Jarvis — Your Personal AI Assistant

**Jarvis** is an open-source, voice-first personal assistant for macOS. Speak naturally, and Jarvis transcribes, translates, rewrites, answers questions, controls your apps, and executes multi-step tasks — all powered by your own OpenAI API key.

**Jarvis** 是一个开源的语音优先 macOS 个人助理。自然说话，Jarvis 就能帮你转写、翻译、改写、回答问题、操控应用、执行多步骤任务 —— 完全使用你自己的 OpenAI API Key。

---

## Vision / 愿景

We believe the future of human-computer interaction is **voice + AI agent**. Instead of clicking through menus and typing commands, you should be able to simply *say* what you want and have an intelligent assistant execute it.

我们相信人机交互的未来是 **语音 + AI Agent**。你不再需要点击菜单、敲击命令，只需说出你的需求，智能助理就能帮你完成。

Jarvis is built to be:

- **Local-first** — Your data stays on your machine. No cloud accounts, no subscriptions, no tracking.
- **Open-source** — Fully transparent, community-driven, and extensible.
- **Voice-native** — Designed from the ground up for voice interaction, not retrofitted.
- **Agent-capable** — Not just a dictation tool, but a full AI agent that can use tools, browse the web, read/write files, and integrate with your apps.

Jarvis 的设计理念：

- **本地优先** —— 数据留在你的机器上。无需云端账号、无需订阅、无追踪。
- **开源透明** —— 完全透明，社区驱动，可自由扩展。
- **语音原生** —— 从底层为语音交互设计，而非事后改造。
- **Agent 能力** —— 不只是听写工具，而是一个能使用工具、浏览网页、读写文件、连接应用的完整 AI Agent。

---

## Features / 功能

### Voice Input / 语音输入
- **Dictation** — Speak and get clean, punctuated text. Jarvis fixes speech-to-text errors automatically.
- **听写** —— 说话即可获得整洁、标点正确的文本。Jarvis 自动修正语音识别错误。

### Smart Commands / 智能指令
- **Translation** — "Translate this to English" / "翻译成英文"
- **Rewriting** — "Rewrite this more formally" / "帮我润色一下"
- **Any instruction** — Just say what you want done with the text.
- **任意指令** —— 只需说出你想对文本做的操作。

### Context-Aware Modes / 上下文模式
- **Text Selection Mode** — Select text in any app, then speak a command to transform it.
- **Screenshot Mode** — Capture a screen region, then ask about it ("fix this error", "what does this mean").
- **Full-Screen Mode** — Jarvis sees your entire screen and responds accordingly.
- **文本选中模式** —— 在任意应用中选中文本，然后说出变换指令。
- **截图模式** —— 截取屏幕区域，然后提问（"修复这个错误"、"这是什么意思"）。
- **全屏模式** —— Jarvis 看到你的整个屏幕并据此回应。

### AI Agent / AI 代理
- **Multi-step task execution** — Jarvis can plan and execute complex tasks autonomously.
- **Tool use** — Shell commands, file operations, web browsing, screen capture.
- **MCP integration** — Connect any MCP-compatible server for extended capabilities.
- **App integrations** — Gmail, Slack, GitHub, Google Calendar via Composio.
- **多步骤任务执行** —— Jarvis 能自主规划和执行复杂任务。
- **工具调用** —— Shell 命令、文件操作、网页浏览、屏幕截图。
- **MCP 集成** —— 连接任何 MCP 兼容服务器以扩展能力。
- **应用集成** —— 通过 Composio 连接 Gmail、Slack、GitHub、Google Calendar。

### Vocabulary Learning / 词汇学习
- Jarvis learns your personal vocabulary — names, jargon, technical terms — and improves transcription accuracy over time.
- Jarvis 会学习你的个人词汇 —— 人名、行话、术语 —— 并逐步提升转写准确度。

---

## Architecture / 架构

```
Jarvis/
├── SpeakFlow/          — Python FastAPI backend (Whisper + GPT, local SQLite)
└── SpeakFlow-macOS/    — Native macOS app (Swift, menu bar, global hotkeys)
```

```
User speaks → Whisper STT → GPT processes → Result returned
用户说话 → Whisper 语音转文字 → GPT 处理 → 返回结果
```

---

## Quick Start / 快速开始

### 1. Backend / 后端

```bash
cd SpeakFlow

# Create .env with your API key / 创建 .env 填入你的 API Key
cp .env.example .env
# Edit .env → set OPENAI_API_KEY

# Install dependencies / 安装依赖 (Python 3.12+)
pip install -e .

# Run / 启动
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 2. macOS App / macOS 应用

Open `SpeakFlow-macOS/SpeakFlow.xcodeproj` in Xcode and build.

The app connects to `http://localhost:8000` by default.

用 Xcode 打开 `SpeakFlow-macOS/SpeakFlow.xcodeproj` 并编译运行。应用默认连接 `http://localhost:8000`。

### 3. Docker (optional / 可选)

```bash
cd SpeakFlow
docker build -t jarvis .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... jarvis
```

---

## Configuration / 配置

| Variable / 变量 | Required / 必填 | Description / 说明 |
|---|---|---|
| `OPENAI_API_KEY` | Yes / 是 | Your OpenAI API key / 你的 OpenAI API Key |
| `GPT_MODEL` | No / 否 | GPT model (default: `gpt-4o`) / GPT 模型 |
| `WHISPER_MODEL` | No / 否 | Whisper model (default: `whisper-1`) / Whisper 模型 |
| `COMPOSIO_API_KEY` | No / 否 | For app integrations / 用于应用集成 (Gmail, Slack, etc.) |

---

## API Endpoints / API 接口

| Method | Path | Description / 说明 |
|--------|------|-----|
| `GET` | `/health` | Health check / 健康检查 |
| `POST` | `/api/v1/process` | Voice → transcription + result / 语音转写+处理 |
| `POST` | `/api/v1/agent/chat` | AI agent with tool use / AI Agent 对话 |
| `GET` | `/api/v1/history` | Processing history / 处理历史 |
| `GET` | `/api/v1/usage` | Usage stats / 使用统计 |
| `GET` | `/api/v1/vocabulary` | Vocabulary list / 词汇表 |
| `POST` | `/api/v1/composio/*` | App integrations / 应用集成 |

---

## Hotkeys / 快捷键

| Hotkey / 快捷键 | Action / 操作 |
|---|---|
| `Option + Z` (hold) | Push-to-talk dictation / 按住说话听写 |
| `Fn` (tap) | Quick voice input / 快速语音输入 |
| `Fn` (double-tap) | Start AI Agent / 启动 AI Agent |
| `Fn + Option` | Screenshot + voice command / 截图+语音指令 |
| `Fn + A` | Full-screen + voice command / 全屏+语音指令 |

---

## Roadmap / 路线图

- [ ] **Local STT** — On-device Whisper for offline transcription / 本地 Whisper 离开线转写
- [ ] **Multi-model support** — Claude, Gemini, local LLMs / 支持 Claude、Gemini、本地模型
- [ ] **iOS / iPad app** — Mobile companion / 移动端应用
- [ ] **Plugin system** — Community-built extensions / 社区插件系统
- [ ] **Conversation memory** — Long-term context across sessions / 跨会话长期记忆
- [ ] **Proactive assistant** — Jarvis suggests actions based on context / 主动建议操作

---

## Tech Stack / 技术栈

- **Backend:** Python, FastAPI, SQLite, OpenAI (Whisper + GPT)
- **macOS App:** Swift, SwiftUI, AppKit
- **Agent Tools:** Bash, file I/O, Chrome CDP, MCP protocol
- **Integrations:** Composio (Gmail, Slack, GitHub, Google Calendar)

---

## Contributing / 贡献

Contributions are welcome! Feel free to open issues or submit pull requests.

欢迎贡献！请随时提 issue 或提交 pull request。

## License / 许可证

MIT
