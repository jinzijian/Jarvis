# Jarvis — 你的个人 AI 助理

> [English](./README.md)

**Jarvis** 是一个开源的语音优先 macOS 个人助理。自然说话，Jarvis 就能帮你转写、翻译、改写、回答问题、操控应用、执行多步骤任务 —— 完全使用你自己的 OpenAI API Key，数据全部保留在本地。

---

## 愿景

我们相信人机交互的未来是 **语音 + AI Agent**。你不再需要点击菜单、敲击命令，只需说出你的需求，智能助理就能帮你完成。

Jarvis 的设计理念：

- **本地优先** —— 数据留在你的机器上。无需云端账号、无需订阅、无追踪。
- **开源透明** —— 完全透明，社区驱动，可自由扩展。
- **语音原生** —— 从底层为语音交互设计，而非事后改造。
- **Agent 能力** —— 不只是听写工具，而是一个能使用工具、浏览网页、读写文件、连接应用的完整 AI Agent。

---

## 功能

### 语音输入
说话即可获得整洁、标点正确的文本。Jarvis 自动修正语音识别错误。

### 智能指令
- **翻译** —— "翻译成英文"、"translate to Japanese"
- **改写** —— "帮我润色一下"、"改成更正式的语气"
- **任意指令** —— 只需说出你想对文本做的操作。

### 上下文模式
- **文本选中模式** —— 在任意应用中选中文本，然后说出变换指令。
- **截图模式** —— 截取屏幕区域，然后提问（"修复这个错误"、"这是什么意思"）。
- **全屏模式** —— Jarvis 看到你的整个屏幕并据此回应。

### AI Agent
- **多步骤任务执行** —— Jarvis 能自主规划和执行复杂任务。
- **工具调用** —— Shell 命令、文件操作、网页浏览、屏幕截图。
- **MCP 集成** —— 连接任何 MCP 兼容服务器以扩展能力。
- **应用集成** —— 通过 Composio 连接 Gmail、Slack、GitHub、Google Calendar。

### 词汇学习
Jarvis 会学习你的个人词汇 —— 人名、行话、术语 —— 并逐步提升转写准确度。

---

## 架构

```
Jarvis/
├── SpeakFlow/          — Python FastAPI 后端 (Whisper + GPT, 本地 SQLite)
└── SpeakFlow-macOS/    — 原生 macOS 应用 (Swift, 菜单栏, 全局快捷键)
```

```
用户说话 → Whisper 语音转文字 → GPT 处理 → 返回结果
```

---

## 快速开始

### 1. 后端

```bash
cd SpeakFlow

# 创建 .env 填入你的 API Key
cp .env.example .env
# 编辑 .env → 设置 OPENAI_API_KEY

# 安装依赖 (需要 Python 3.12+)
pip install -e .

# 启动
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 2. macOS 应用

用 Xcode 打开 `SpeakFlow-macOS/SpeakFlow.xcodeproj` 并编译运行。

应用默认连接 `http://localhost:8000`。

### 3. Docker（可选）

```bash
cd SpeakFlow
docker build -t jarvis .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... jarvis
```

---

## 配置

| 变量 | 必填 | 说明 |
|---|---|---|
| `OPENAI_API_KEY` | 是 | 你的 OpenAI API Key |
| `GPT_MODEL` | 否 | GPT 模型（默认: `gpt-4o`） |
| `WHISPER_MODEL` | 否 | Whisper 模型（默认: `whisper-1`） |
| `COMPOSIO_API_KEY` | 否 | 用于应用集成（Gmail, Slack 等） |

---

## API 接口

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 健康检查 |
| `POST` | `/api/v1/process` | 语音转写 + 处理 |
| `POST` | `/api/v1/agent/chat` | AI Agent 对话 |
| `GET` | `/api/v1/history` | 处理历史 |
| `GET` | `/api/v1/usage` | 使用统计 |
| `GET` | `/api/v1/vocabulary` | 词汇表 |
| `POST` | `/api/v1/composio/*` | 应用集成 |

---

## 快捷键

| 快捷键 | 操作 |
|---|---|
| `Option + Z`（按住） | 按住说话听写 |
| `Fn`（单击） | 快速语音输入 |
| `Fn`（双击） | 启动 AI Agent |
| `Fn + Option` | 截图 + 语音指令 |
| `Fn + A` | 全屏 + 语音指令 |

---

## 路线图

- [ ] 本地 STT —— 设备端 Whisper，离线转写
- [ ] 多模型支持 —— Claude、Gemini、本地模型
- [ ] iOS / iPad 应用
- [ ] 插件系统 —— 社区插件扩展
- [ ] 对话记忆 —— 跨会话长期上下文
- [ ] 主动助理 —— Jarvis 根据上下文主动建议操作

---

## 技术栈

- **后端:** Python, FastAPI, SQLite, OpenAI (Whisper + GPT)
- **macOS 应用:** Swift, SwiftUI, AppKit
- **Agent 工具:** Bash, 文件读写, Chrome CDP, MCP 协议
- **集成:** Composio (Gmail, Slack, GitHub, Google Calendar)

---

## 贡献

欢迎贡献！请随时提 issue 或提交 pull request。

## 许可证

MIT
