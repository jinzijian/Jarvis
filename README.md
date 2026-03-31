# SpeakFlow

Open-source voice input method for macOS — speak naturally, get processed text back.

Supports dictation, translation, rewriting, screenshot-based commands, and an AI agent with tool use.

## How It Works

```
User speaks → Audio uploaded → Whisper STT → GPT processes → Final text returned
```

**Three input modes:**
- **Dictation** — speak and get clean text, fixing speech-to-text errors
- **Text Selection** — select text, then speak a command ("translate to English", "rewrite formally")
- **Screenshot** — capture screen region, then speak ("fix this error", "what's wrong here")

**Plus an AI Agent** that can execute multi-step tasks using tools (bash, file ops, browser, MCP servers).

## Architecture

```
SpeakFlow/          — Python FastAPI backend (OpenAI Whisper + GPT)
SpeakFlow-macOS/    — Native macOS app (Swift, menu bar, global hotkeys)
```

## Quick Start

### 1. Backend Setup

```bash
cd SpeakFlow

# Create .env with your OpenAI API key
cp .env.example .env
# Edit .env and add your OPENAI_API_KEY

# Install dependencies (requires Python 3.12+)
pip install -e .
# or with uv:
uv pip install -e .

# Run the server
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

The API will be available at `http://localhost:8000`.

### 2. macOS App

Open `SpeakFlow-macOS/SpeakFlow.xcodeproj` in Xcode and build.

The app defaults to connecting to `http://localhost:8000/api/v1`. You can change the backend URL in the app settings.

### 3. Docker (optional)

```bash
cd SpeakFlow
docker build -t speakflow .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... speakflow
```

## Configuration

All configuration is via environment variables (`.env` file):

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | Yes | Your OpenAI API key |
| `GPT_MODEL` | No | GPT model to use (default: `gpt-4o`) |
| `WHISPER_MODEL` | No | Whisper model (default: `whisper-1`) |
| `COMPOSIO_API_KEY` | No | For third-party app integrations (Gmail, Slack, etc.) |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/api/v1/process` | Audio upload → transcription + result |
| `GET` | `/api/v1/history` | Processing history |
| `GET` | `/api/v1/usage` | Usage statistics |
| `GET` | `/api/v1/vocabulary` | Vocabulary corrections |
| `POST` | `/api/v1/agent/chat` | AI agent chat with tool use |
| `POST` | `/api/v1/composio/*` | Third-party integrations |

### Process Audio

```bash
curl -X POST http://localhost:8000/api/v1/process \
  -F "audio=@recording.wav" \
  -F "language=zh"
```

With streaming:
```bash
curl -X POST "http://localhost:8000/api/v1/process?stream=true" \
  -F "audio=@recording.wav"
```

## Tech Stack

- **Backend:** Python, FastAPI, SQLite
- **STT:** OpenAI Whisper
- **LLM:** OpenAI GPT
- **macOS App:** Swift, SwiftUI
- **Integrations:** Composio (optional)

## License

MIT
