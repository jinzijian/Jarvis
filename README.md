# Jarvis

**Open-source voice agent for macOS.**
Speak to type. Command your apps. Automate your workflow.

[中文文档](./README_CN.md)

---

Hold a key, speak naturally, and Jarvis does the rest — from clean dictation to sending emails, managing your calendar, and executing multi-step tasks across your Mac. All powered by your own OpenAI API key. No cloud accounts, no subscriptions, fully local.

<!-- TODO: Add demo GIF here -->
<!-- ![Demo](assets/demo.gif) -->

## Why Jarvis

Your Mac already has dictation. ChatGPT already has voice mode. So why Jarvis?

**Dictation tools** give you text. **Chatbots** give you answers. **Jarvis gives you actions.**

- Say "reply to Alice's email saying I'm free tomorrow" — it finds the email, drafts the reply, and asks you to confirm.
- Say "what's on my calendar today" — it checks and tells you.
- Say "translate this to Japanese" with text selected — it replaces it instantly.
- Say "fix this error" with a screenshot — it reads your screen and gives you the fix.

It's the difference between a transcription tool and an assistant that actually *does things*.

## Get Started

### 1. Backend

```bash
cd SpeakFlow
cp .env.example .env        # Then add your OPENAI_API_KEY
pip install -e .             # Python 3.12+
uvicorn app.main:app --port 8000
```

### 2. macOS App

Open `SpeakFlow-macOS/SpeakFlow.xcodeproj` in Xcode, build and run.

On first launch, Jarvis walks you through permissions, API key setup, and connecting your tools (Gmail, Calendar, Slack, etc.).

### 3. Docker (optional)

```bash
cd SpeakFlow
docker build -t jarvis .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... jarvis
```

## How It Works

```
You speak → Whisper transcribes → GPT understands → Agent acts → You get results
```

Three interaction modes:

| Mode | How | What happens |
|------|-----|-------------|
| **Dictation** | Hold `Option+Z`, speak | Clean text appears at your cursor |
| **Command** | Select text, then speak | Text is translated, rewritten, or transformed |
| **Agent** | Double-tap `Fn`, speak | Jarvis plans and executes multi-step tasks |

## What Jarvis Can Do

### Voice Input
Hold a key and speak. Jarvis gives you clean, punctuated text — fixing speech-to-text errors automatically. It learns your vocabulary over time (names, jargon, technical terms).

### Smart Commands
Select any text, then speak: "translate to English", "make this more formal", "summarize in 3 bullets". The result replaces your selection.

### Screen Understanding
Capture your screen (or a region), then ask about it. Jarvis reads everything visible — code, errors, emails, UI — and responds in context.

### AI Agent
This is where it gets interesting. Jarvis doesn't just transcribe — it *acts*:

- **Email** — Search, read, draft, reply, forward (Gmail)
- **Calendar** — Check schedule, create events, find free time (Google Calendar)
- **Messaging** — Send and read messages (Slack)
- **Files** — Read, write, search across your filesystem
- **Shell** — Execute commands, run scripts
- **Browser** — Navigate, click, extract content (Chrome CDP)
- **Screenshots** — Capture and analyze screen content
- **MCP** — Connect any MCP-compatible server for custom tools

The agent plans multi-step tasks, calls tools in sequence, handles errors, and reports results — all from a single voice command.

## Hotkeys

| Hotkey | Action |
|---|---|
| `Option+Z` (hold) | Push-to-talk dictation |
| `Fn` (tap) | Quick voice input |
| `Fn` (double-tap) | Start AI Agent |
| `Fn+Option` | Screenshot + voice command |
| `Fn+A` | Full-screen + voice command |

## Architecture

```
Jarvis/
├── SpeakFlow/          — Python FastAPI backend (Whisper + GPT, local SQLite)
└── SpeakFlow-macOS/    — Native macOS app (Swift, SwiftUI, menu bar)
```

The macOS app handles voice recording, hotkeys, screen capture, and the agent tool loop. The backend handles speech-to-text, LLM calls, and data persistence. Everything runs locally.

## Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `OPENAI_API_KEY` | Yes | — | Your OpenAI API key |
| `GPT_MODEL` | No | `gpt-5.4` | GPT model for processing |
| `WHISPER_MODEL` | No | `whisper-1` | Whisper model for transcription |
| `COMPOSIO_API_KEY` | No | — | For app integrations (Gmail, Slack, etc.) |

## Extending Jarvis

### MCP Servers
Connect any [Model Context Protocol](https://modelcontextprotocol.io) server to give Jarvis new capabilities. Configure in Settings > MCP Servers.

### Composio Integrations
Connect 100+ apps through Composio — Gmail, Slack, GitHub, Notion, and more. Authorize in Settings or during onboarding.

### Custom Tools
The agent tool system is modular. Add new tools in `SpeakFlow-macOS/SpeakFlow/Agent/Tools/`.

## Roadmap

- [ ] Local Whisper — On-device transcription, no API needed
- [ ] Multi-model — Claude, Gemini, local LLMs
- [ ] iOS app
- [ ] Plugin marketplace
- [ ] Proactive assistant — Jarvis suggests actions based on context
- [ ] Conversation memory across sessions

## Contributing

Contributions welcome. Open an issue or submit a PR.

## License

MIT
