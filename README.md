---

# VoiceForge

**Local AI Voice Transcription System**

VoiceForge is a real-time voice-to-text system designed for developers, creators, and thinkers who want to capture ideas instantly and structure them later using local AI models.

---

## 🧠 Core Concept

> Speak freely → Capture raw → Transform later

VoiceForge preserves your original speech as the **source of truth**, then allows optional AI-powered formatting using local models via Ollama.

---

## ✨ Features

* 🎤 Real-time voice transcription
* 📝 Raw + formatted dual-panel UI
* ⚡ Push-to-talk recording system
* 🧠 Local AI formatting (Ollama)
* 🔀 Multi-model routing support
* 📄 Paragraph-aware transcription
* 🔄 Post-processing on demand

---

## 🚀 Quick Start

```bash
git clone https://github.com/PhsycoCommando/VoiceForge
cd VoiceForge
chmod +x scripts/install.sh
./scripts/install.sh
```

Launch from system search:

```
VoiceForge
```

---

## 🧰 Requirements

* Linux (Ubuntu / Pop!_OS recommended)
* Python 3.10+
* Ollama installed

Install Ollama:

https://ollama.com

---

## 🤖 Recommended Models

| Use Case        | Model       |
| --------------- | ----------- |
| Fast / Light    | gemma3:4b   |
| Balanced        | qwen:7b     |
| Dev Structuring | deepseek-r1 |

---

## 🖥 Usage

Run manually:

```bash
./scripts/run.sh
```

Or launch via system app menu.

---

## 📁 Project Structure

```
backend/     Python transcription + API
ui/          Flutter desktop application
scripts/     install + run automation
assets/      icons and static resources
```

---

## 🧪 Status

Early release — actively being improved

---

## ❤️ Support

Ko-fi and Discord coming soon.

---

## 📜 License

MIT (to be added)

---
