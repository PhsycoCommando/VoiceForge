# 🚀 VoiceForge

**Local AI Voice Transcription + Prompt Engine**

VoiceForge is a real-time voice-to-text system designed for developers, creators, and thinkers who want to capture ideas instantly — and structure them later using local AI.

## 🧠 Core Concept

> Speak freely → Capture raw → Transform later

VoiceForge treats your raw input as the source of truth, then lets you refine it into structured outputs using local models via Ollama.

## ✨ Features

* 🎤 Real-time voice transcription (push-to-talk)
* 📝 Editable RAW input (type, paste, or speak)
* ⚡ Dual-panel UI (Raw → Processed)
* 🧠 Local AI transformations (Ollama)
* 🔄 Reprocess pipeline (iterate instantly)
* 📄 Paragraph-aware transcription
* 📋 Copy-ready outputs

## 🧩 Output Modes

Transform your input into:

* **Clean** → Proper sentences & paragraphs
* **Bullet** → Structured key points
* **Summary** → Condensed overview
* **Prompt** → AI-ready structured prompt

## 🚀 Quick Start

```bash
git clone https://github.com/PhsycoCommando/VoiceForge.git
cd VoiceForge
chmod +x scripts/install.sh
./scripts/install.sh
```

Launch from system search:

```
VoiceForge
```

## 🧰 Requirements

* Linux (Ubuntu / Pop!_OS tested)
* Python 3.10+
* Ollama installed

👉 Install Ollama:
https://ollama.com

## 🤖 Recommended Models

| Use Case        | Model       |
| --------------- | ----------- |
| Fast / Light    | gemma3:4b   |
| Balanced        | qwen:7b     |
| Dev Structuring | deepseek-r1 |

## 🖥 Usage

Run manually:

```bash
./scripts/run.sh
```

Or launch via system app menu.

## 📁 Project Structure

```
backend/     Python transcription + API
ui/          Flutter desktop application
scripts/     install + run automation
assets/      icons and static resources
```

## 🧪 Status

v0.1.0 — First usable release
Actively being improved

## 💰 Support

If you find this useful and want to support development:

☕ [https://ko-fi.com/phsyco](https://ko-fi.com/phsyco)

More support options coming soon.

## 📜 License

This project is licensed under the MIT License.
See the [LICENSE](LICENSE) file for details.
