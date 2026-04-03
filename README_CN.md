# Jarvis

**开源 macOS 语音 Agent。**
说话打字。语音操控应用。自动化你的工作流。

[English](./README.md)

---

按住快捷键，自然说话，Jarvis 帮你搞定一切 —— 从精准听写到发邮件、管日历、跨应用执行多步任务。使用你自己的 OpenAI API Key，无需注册账号，无需订阅，数据完全本地。

<!-- TODO: 添加演示 GIF -->
<!-- ![Demo](assets/demo.gif) -->

## 为什么选 Jarvis

Mac 已经有听写功能。ChatGPT 也有语音模式。为什么还需要 Jarvis？

**听写工具**给你文本。**聊天机器人**给你回答。**Jarvis 给你行动。**

- 说 "回复 Alice 的邮件说我明天有空" — 它找到邮件、起草回复、等你确认。
- 说 "今天有什么安排" — 它查日历然后告诉你。
- 选中文本说 "翻译成日语" — 直接替换。
- 截屏说 "修复这个错误" — 它看懂你的屏幕，给出修复方案。

这就是转写工具和真正能**做事**的助手之间的区别。

## 快速开始

### 1. 后端

```bash
cd SpeakFlow
cp .env.example .env        # 填入你的 OPENAI_API_KEY
pip install -e .             # 需要 Python 3.12+
uvicorn app.main:app --port 8000
```

### 2. macOS 应用

用 Xcode 打开 `SpeakFlow-macOS/SpeakFlow.xcodeproj`，编译运行。

首次启动会引导你完成权限授予、API Key 配置、以及连接工具（Gmail、日历、Slack 等）。

### 3. Docker（可选）

```bash
cd SpeakFlow
docker build -t jarvis .
docker run -p 8000:8000 -e OPENAI_API_KEY=sk-... jarvis
```

## 工作原理

```
你说话 → Whisper 转写 → GPT 理解 → Agent 执行 → 返回结果
```

三种交互模式：

| 模式 | 操作 | 效果 |
|------|------|------|
| **听写** | 按住 `Option+Z` 说话 | 干净的文本出现在光标处 |
| **指令** | 选中文本后说话 | 文本被翻译、改写或变换 |
| **Agent** | 双击 `Fn` 后说话 | Jarvis 规划并执行多步任务 |

## Jarvis 能做什么

### 语音输入
按住快捷键说话，得到干净、标点正确的文本 —— 自动修正语音识别错误。它会学习你的个人词汇（人名、术语、行话），越用越准。

### 智能指令
选中任意文本，然后说："翻译成英文"、"改成更正式的语气"、"总结成三个要点"。结果直接替换选中内容。

### 屏幕理解
截取屏幕（或选取区域），然后提问。Jarvis 能读懂屏幕上的一切 —— 代码、报错、邮件、UI —— 并结合上下文回应。

### AI Agent
这才是重点。Jarvis 不只是转写 —— 它能**执行**：

- **邮件** — 搜索、阅读、起草、回复、转发（Gmail）
- **日历** — 查看日程、创建事件、查找空闲时间（Google Calendar）
- **消息** — 发送和阅读消息（Slack）
- **文件** — 读写、搜索文件系统
- **终端** — 执行命令、运行脚本
- **浏览器** — 导航、点击、提取内容（Chrome CDP）
- **截图** — 截取并分析屏幕内容
- **MCP** — 连接任何 MCP 兼容服务器，扩展能力

Agent 能规划多步任务、按顺序调用工具、处理错误、汇报结果 —— 全程只需一句语音指令。

## 快捷键

| 快捷键 | 操作 |
|---|---|
| `Option+Z`（按住） | 按住说话听写 |
| `Fn`（单击） | 快速语音输入 |
| `Fn`（双击） | 启动 AI Agent |
| `Fn+Option` | 截图 + 语音指令 |
| `Fn+A` | 全屏 + 语音指令 |

## 架构

```
Jarvis/
├── SpeakFlow/          — Python FastAPI 后端（Whisper + GPT，本地 SQLite）
└── SpeakFlow-macOS/    — 原生 macOS 应用（Swift, SwiftUI, 菜单栏）
```

macOS 应用负责录音、快捷键、截屏和 Agent 工具循环。后端负责语音转文字、LLM 调用和数据持久化。一切都在本地运行。

## 配置

| 变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `OPENAI_API_KEY` | 是 | — | 你的 OpenAI API Key |
| `GPT_MODEL` | 否 | `gpt-5.4` | GPT 模型 |
| `WHISPER_MODEL` | 否 | `whisper-1` | Whisper 模型 |
| `COMPOSIO_API_KEY` | 否 | — | 应用集成（Gmail, Slack 等） |

## 扩展 Jarvis

### MCP 服务器
连接任何 [Model Context Protocol](https://modelcontextprotocol.io) 服务器来扩展 Jarvis 的能力。在设置 > MCP 服务器中配置。

### Composio 集成
通过 Composio 连接 100+ 应用 —— Gmail、Slack、GitHub、Notion 等。在设置或首次引导中授权。

### 自定义工具
Agent 工具系统是模块化的。在 `SpeakFlow-macOS/SpeakFlow/Agent/Tools/` 中添加新工具。

## 路线图

- [ ] 本地 Whisper — 设备端转写，无需 API
- [ ] 多模型 — Claude、Gemini、本地模型
- [ ] iOS 应用
- [ ] 插件市场
- [ ] 主动助理 — Jarvis 根据上下文主动建议
- [ ] 跨会话对话记忆

## 贡献

欢迎贡献。提 issue 或提交 PR。

## 许可证

MIT
