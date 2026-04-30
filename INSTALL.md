# VoiceForge — Installation Guide

> Real-time voice-to-text transcription with AI-powered formatting.  
> Free & open source — [GitHub](https://github.com/PhsycoCommando/VoiceForge) | [Ko-fi](https://ko-fi.com/)

---

## What You Need

| Requirement | Details |
|---|---|
| **Windows 10/11** | 64-bit |
| **Python 3.12+** | [Download](https://www.python.org/downloads/) — check "Add to PATH" during install |
| **Ollama** | [Download](https://ollama.com/download) — local AI engine (free) |
| **Disk Space** | ~8 GB (models + backend) |
| **Microphone** | Any USB or built-in mic |

---

## Quick Start (3 Steps)

### Step 1: Install the Python Backend

Double-click **`install_backend.bat`**

This will:
- ✅ Check that Python is installed
- ✅ Create an isolated virtual environment
- ✅ Install all required Python packages

> **Tip:** If you don't have Python, the script will tell you. Download it from [python.org](https://www.python.org/downloads/) — make sure to check **"Add Python to PATH"** during installation.

---

### Step 2: Install Ollama + AI Models

Double-click **`install_ollama.bat`**

This will:
- ✅ Check if Ollama is installed (opens download page if not)
- ✅ Start the Ollama server
- ✅ Download two recommended AI models:

| Model | Size | Used For |
|---|---|---|
| **gemma3:4b** | 3.3 GB | Markdown formatting |
| **mistral:7b** | 4.4 GB | Summary, Prompt, Speech modes |

> **Note:** Model downloads are one-time only. They run entirely on your computer — no cloud, no API keys, no subscriptions.

---

### Step 3: Launch VoiceForge

Double-click **`VoiceForge.exe`**

The app will:
1. Start the Python backend automatically
2. Load the transcription engine (first launch takes ~10 seconds)
3. Show a **"Ready"** status when everything is connected

**That's it — start talking!**

---

## How to Use

| Action | How |
|---|---|
| **Record** | Click the mic button (or press it again to stop) |
| **Format** | Click a mode tab at the bottom: Clean, Bullet, Summary, etc. |
| **Edit** | Both panels are editable — type directly to fix anything |
| **Copy** | Click the copy icon on either panel |
| **Clear** | Click "Clear" in the top bar to start fresh |

### Formatting Modes

| Mode | What It Does | AI? |
|---|---|---|
| **Clean** | Removes filler words, fixes punctuation, adds paragraphs | No |
| **Bullet** | Converts speech into bullet points | No |
| **Summary** | AI-powered concise summary | ✅ mistral:7b |
| **Prompt** | Converts speech into a structured AI prompt | ✅ mistral:7b |
| **Markdown** | Formats as raw Markdown (headers, bullets, bold) | ✅ gemma3:4b |
| **Speech** | Polishes speech for delivery — keeps your voice | ✅ mistral:7b |

> Modes marked with ✅ require Ollama to be running. Without Ollama, they fall back to basic text cleanup.

---

## Troubleshooting

### "Backend not connecting" / Stuck on "Disconnected"

1. Make sure Python is installed and in PATH
2. Try clicking the refresh button (🔄) next to the status indicator
3. Check if port 8000 is free: open a terminal and run `netstat -ano | findstr :8000`

### "Formatted output is just cleaned text, not AI-formatted"

Ollama might not be running. Start it:
```
ollama serve
```

### "Model not found" errors in the console

Pull the models manually:
```
ollama pull gemma3:4b
ollama pull mistral:7b
```

### App won't launch (nothing happens when clicking the exe)

A previous instance may be stuck. Open Task Manager, find any `VoiceForge` or `pythonw` processes, and end them. Then try again.

---

## Customizing AI Models

You can change which models are used for each formatting mode by editing `backend\voice_forge.json`:

```json
{
    "ollama_models": {
        "markdown": "gemma3:4b",
        "summary": "mistral:7b",
        "prompt": "mistral:7b",
        "speech": "mistral:7b"
    }
}
```

Any model available in Ollama can be used. Smaller models are faster; larger models produce better output.

To see your installed models:
```
ollama list
```

---

## Uninstalling

1. Delete the VoiceForge folder
2. (Optional) Uninstall Ollama from Windows Settings → Apps
3. (Optional) Uninstall Python if you don't need it

No registry entries or system modifications are made.

---

*Built with ❤️ by PhsycoCommando*
