# 🚀 VoiceForge

🚀 **Latest Release: [v0.1.1](https://github.com/PhsycoCommando/VoiceForge/releases/tag/v0.1.1)**

**Local AI Voice Transcription + Prompt Engine**

VoiceForge is a real-time voice-to-text system designed for developers, creators, and thinkers who want to capture ideas instantly — and structure them later using local AI.

---

## 🪟 Windows (One-Click Version) 🔥 NEW

> Built 4/16/2026 — ~20 hours over 2 days

No setup. No Python. No dependencies.  
Just **download → extract → run.**

---

### 🔽 Download

👉 Go to **Releases** and download:

`VoiceForge_Windows_v1.zip`

---

### ▶️ Run

1. Extract the ZIP anywhere
2. Double-click:

`VoiceForge.exe`

3. Done. 🎤

---

### ⚙️ What Happens Automatically

- Backend server auto-launches
- Microphone initializes (WASAPI)
- UI connects instantly
- Ready for recording

---

### ⚠️ Notes

- First launch may take a few seconds (backend spin-up)
- Ensure your microphone works in Windows
- Voicemeeter users: select the correct device in the dropdown (top bar)

---

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

## 🪟 Windows (One-Click Version)

No setup. No Python. No dependencies.

### 🔽 Download

👉 Download the latest Windows build from Releases:  
https://github.com/PhsycoCommando/VoiceForge/releases

---

### ▶️ Run

1. Extract the ZIP
2. Double-click `VoiceForge.exe`
3. Done

---

### ⚡ What Just Works

- 🎤 Real-time transcription
- 🧠 Local AI formatting (Ollama)
- 🎛️ Microphone selection (built-in)
- ⚙️ Backend auto-launch (no manual setup)

---

### ⚠️ Notes

- First launch may take a few seconds (backend initializes)
- Make sure your microphone is available in Windows
- Works with virtual audio (Voicemod, Voicemeeter, etc.)

---

### 🧠 Architecture (Windows)

- Flutter Desktop UI
- Python backend (bundled via PyInstaller)
- WASAPI-native audio capture (no PortAudio instability)
- Local Whisper transcription + Ollama processing

---

💡 This version is designed for **zero-friction usage** — download → run → go.

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

🔥 **Latest Release: [v0.1.1](https://github.com/PhsycoCommando/VoiceForge/releases/tag/v0.1.1) — Stability Patch**

* Fixed dock/launcher relaunch on Pop!_OS (COSMIC / Wayland)
* Single-instance UI enforcement
* Improved process lifecycle handling
* Resolved intermittent connection issues on first launch

---

## 🧪 Development Notes (Windows Build)

**Build Date:** 4/16/2026  
**Dev Time:** ~20 hours (2-day push)

This release represents a major milestone:

- ✅ Full Windows standalone build (no Python required)
- ✅ Backend packaged with PyInstaller
- ✅ Audio system stabilized after extensive WASAPI / WDM debugging
- ✅ Microphone selection system implemented (UI + backend sync)
- ✅ Port conflict handling added for dev + production coexistence
- ✅ Cross-platform Flutter foundation expanded (Windows/Linux/macOS ready)

---

### ⚔️ Known Battle (Audio)

Audio capture on Windows required:

- Eliminating PortAudio instability
- Handling WASAPI device routing (including Voicemeeter / Voicemod)
- Preventing WDM-KS driver crashes (`-9999 WdmSyncIoctl`)
- Implementing persistent / singleton recording strategies

This build reflects a **fully stabilized workaround architecture**.

---

🚀 Future improvements will focus on:

- Setup installer (MSI / EXE installer)
- Model preloading & offline optimization
- UI/UX polish
- Multi-device / system audio capture expansion

## 💰 Support

If you find this useful and want to support development:

☕ [https://ko-fi.com/phsyco](https://ko-fi.com/phsyco)

More support options coming soon.

## 📜 License

This project is licensed under the MIT License.  
See the [LICENSE](./LICENSE) file for details.
