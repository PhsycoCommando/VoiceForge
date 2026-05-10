# 🚀 VoiceForge

🚀 **Latest Release: [v1.4.0](https://github.com/PhsycoCommando/VoiceForge/releases/tag/v1.4.0)**

**Local AI Voice Transcription + Formatting Engine**

VoiceForge is a real-time voice-to-text system designed for developers, creators, and thinkers who want to capture ideas instantly — and structure them later using local AI.

> Free & open source — pay what you want on [Ko-fi](https://ko-fi.com/phsyco)

---

## 🧠 Core Concept

> Speak freely → Capture raw → Transform later

VoiceForge treats your raw input as the source of truth, then lets you refine it into structured outputs using local AI models via [Ollama](https://ollama.com).

---

## ✨ Features

- 🎤 Real-time voice transcription with live preview
- 📝 Dual-panel UI — editable raw transcript + formatted output
- 🧠 Local AI transformations (Ollama) — no cloud, no API keys
- ⚡ Near-instant stop — fast tail-flush architecture
- 📂 Session history with folder access
- 🔄 Reprocess pipeline — iterate and refine instantly
- 📋 Copy-ready outputs for all modes

---

## 🧩 Output Modes

| Mode | What It Does | Engine |
|---|---|---|
| **Clean** | Removes filler words, fixes punctuation, adds paragraphs | Rule-based |
| **Bullet** | Converts speech into structured bullet points | Rule-based |
| **Markdown** | Raw `.md` syntax — headers, bullets, bold | AI (gemma3:4b) |
| **Summary** | Concise overview of your speech | AI (mistral:7b) |
| **Prompt** | Converts speech into structured AI prompts | AI (mistral:7b) |
| **Speech** | Polishes speech for delivery — keeps your voice | AI (mistral:7b) |

> AI modes require Ollama. Without it, they fall back to rule-based cleanup.

---

## 🔽 Download

### Option A: GitHub Release

👉 Download `VoiceForge.zip` from [Releases](https://github.com/PhsycoCommando/VoiceForge/releases)

### Option B: Clone & Build

```bash
git clone https://github.com/PhsycoCommando/VoiceForge.git
cd VoiceForge
```

---

## 🚀 Quick Start (3 Steps)

### Step 1: Install Python Backend

Double-click **`install_backend.bat`**

- Checks for Python 3.12+
- Creates an isolated virtual environment
- Installs all dependencies

> Don't have Python? Download from [python.org](https://www.python.org/downloads/) — check **"Add to PATH"** during install.

### Step 2: Install Ollama + AI Models

Double-click **`install_ollama.bat`**

- Installs [Ollama](https://ollama.com/download) if needed
- Pulls recommended models:

| Model | Size | Purpose |
|---|---|---|
| **gemma3:4b** | 3.3 GB | Markdown formatting |
| **mistral:7b** | 4.4 GB | Summary, Prompt, Speech modes |

> Models run entirely on your machine — no cloud, no subscriptions.

### Step 3: Launch

Double-click **`VoiceForge.exe`** — done. 🎤

---

## 🧰 Requirements

| Requirement | Details |
|---|---|
| **Windows 10/11 & Linux (KDE/GNOME)** | 64-bit |
| **Python 3.12+** | [Download](https://www.python.org/downloads/) |
| **Ollama** | [Download](https://ollama.com/download) |
| **Disk Space** | ~8 GB (models + backend) |
| **Microphone** | Any USB or built-in mic |

---

## 🤖 Recommended Models

| Model | Size | Use Case |
|---|---|---|
| **gemma3:4b** | 3.3 GB | Fast & lightweight formatting |
| **mistral:7b** | 4.4 GB | Balanced quality for all AI modes |
| **deepseek-r1:7b** | 4.7 GB | Alternative for dev/technical content |

Install manually:
```bash
ollama pull gemma3:4b
ollama pull mistral:7b
```

---

## 🏗 Architecture

```
VoiceForge/
├── VoiceForge.exe              Flutter Desktop UI (Windows)
├── backend/                    Python server (FastAPI + Whisper + Ollama)
│   ├── server.py               WebSocket + REST API
│   ├── transcriber.py          faster-whisper engine
│   ├── formatter.py            Rule-based formatters (Clean, Bullet)
│   ├── ai_formatter.py         AI-powered formatters (Markdown, Summary, etc.)
│   └── voice_forge.json        Runtime configuration
├── install_backend.bat         One-click Python setup
├── install_ollama.bat          One-click Ollama + model setup
└── INSTALL.md                  Full installation guide
```

**How it works:**
1. Flutter UI launches the Python backend automatically
2. WASAPI-native audio capture feeds real-time audio chunks
3. faster-whisper transcribes live with partial previews
4. On stop, accumulated text is instantly finalized (no re-processing)
5. Formatting modes transform raw text on demand

---

## ⚙️ Customization

Edit `backend/voice_forge.json` to change AI model routing:

```json
{
    "ollama_models": {
        "markdown": "gemma3:4b",
        "summary": "mistral:7b",
        "speech": "mistral:7b"
    }
}
```

See [INSTALL.md](./INSTALL.md) for full configuration options.

---

## 💰 Support

Free to use. If you find it useful:

☕ [ko-fi.com/phsyco](https://ko-fi.com/phsyco) — Pay what you want

---

## 📜 License

This project is licensed under the MIT License.
See the [LICENSE](./LICENSE) file for details.
