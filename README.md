# Jarvis — Your Personal AI Assistant

> [中文文档](./README_CN.md)

**Jarvis** is an open-source, voice-first personal assistant for macOS. Speak naturally, and Jarvis transcribes, translates, rewrites, answers questions, controls your apps, and executes multi-step tasks — all powered by your own OpenAI API key.

---

## Vision

We believe the future of human-computer interaction is **voice + AI agent**. Instead of clicking through menus and typing commands, you should be able to simply *say* what you want and have an intelligent assistant execute it.

Jarvis is built to be:

- **Local-first** — Your data stays on your machine. No cloud accounts, no subscriptions, no tracking.
- **Open-source** — Fully transparent, community-driven, and extensible.
- **Voice-native** — Designed from the ground up for voice interaction, not retrofitted.
- **Agent-capable** — Not just a dictation tool, but a full AI agent that can use tools, browse the web, read/write files, and integrate with your apps.

---

## Features

### Voice Input
Speak and get clean, punctuated text. Jarvis fixes speech-to-text errors automatically.

### Smart Commands
- **Translation** — "Translate this to English"
- **Rewriting** — "Rewrite this more formally"
- **Any instruction** — Just say what you want done with the text.

### Context-Aware Modes
- **Text Selection** — Select text in any app, then speak a command to transform it.
- **Screenshot** — Capture a screen region, then ask about it ("fix this error", "what does this mean").
- **Full-Screen** — Jarvis sees your entire screen and responds accordingly.

### AI Agent
- **Multi-step task execution** — Jarvis can plan and execute complex tasks autonomously.
- **Tool use** — Shell commands, file operations, web browsing, screen capture.
- **MCP integration** — Connect any MCP-compatible server for extended capabilities.
- **App integrations** — Gmail, Slack, GitHub, Google Calendar via Composio.

### Vocabulary Learning
Jarvis learns your personal vocabulary — names, jargon, technical terms — and improves transcription accuracy over time.

---

## Architecture

```
Jarvis/
├── SpeakFlow/          — Python FastAPI backend (Whisper + GPT, local SQLite)
└── SpeakFlow-macOS/    — Native macOS app (Swift, menu bar, global hotkeys)
```

```
User speaks → Whisper STT → GPT processes → Result returned
```

---

## Quick Start

### 1. Backend

```bash
cd SpeakFlow

# Create .env with your API key
cp .env.example .env
# Edit .env → set OPENAI_API_KEY

# Install dependencies (Python 3.12+)
pip install -e .

# Run
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 2. macOS App

Open `SpeakFlow-macOS/SpeakFlow.xcodeproj` in Xcode and build.

The app connects to `http://localhost:8000` by default.

### 3. Docker (optional)

```bash
cd SpeakFlow
docker build -t jarvis .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... jarvis
```

---

## Configuration

| Variable | Required | Description |
|---|---|---|
| `OPENAI_API_KEY` | Yes | Your OpenAI API key |
| `GPT_MODEL` | No | GPT model (default: `gpt-4o`) |
| `WHISPER_MODEL` | No | Whisper model (default: `whisper-1`) |
| `COMPOSIO_API_KEY` | No | For app integrations (Gmail, Slack, etc.) |

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/api/v1/process` | Voice → transcription + result |
| `POST` | `/api/v1/agent/chat` | AI agent with tool use |
| `GET` | `/api/v1/history` | Processing history |
| `GET` | `/api/v1/usage` | Usage stats |
| `GET` | `/api/v1/vocabulary` | Vocabulary list |
| `POST` | `/api/v1/composio/*` | App integrations |

---

## Hotkeys

| Hotkey | Action |
|---|---|
| `Option + Z` (hold) | Push-to-talk dictation |
| `Fn` (tap) | Quick voice input |
| `Fn` (double-tap) | Start AI Agent |
| `Fn + Option` | Screenshot + voice command |
| `Fn + A` | Full-screen + voice command |

---

## Roadmap

- [ ] Local STT — On-device Whisper for offline transcription
- [ ] Multi-model support — Claude, Gemini, local LLMs
- [ ] iOS / iPad app
- [ ] Plugin system — Community-built extensions
- [ ] Conversation memory — Long-term context across sessions
- [ ] Proactive assistant — Jarvis suggests actions based on context

---

## Tech Stack

- **Backend:** Python, FastAPI, SQLite, OpenAI (Whisper + GPT)
- **macOS App:** Swift, SwiftUI, AppKit
- **Agent Tools:** Bash, file I/O, Chrome CDP, MCP protocol
- **Integrations:** Composio (Gmail, Slack, GitHub, Google Calendar)

---

## Contributing

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

MIT
