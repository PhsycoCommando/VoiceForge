@echo off
setlocal
cd /d "%~dp0"

echo.
echo  ╔══════════════════════════════════════════╗
echo  ║   VoiceForge — Ollama AI Setup           ║
echo  ╚══════════════════════════════════════════╝
echo.

:: ── Check if Ollama is installed ─────────────────────────────────────
echo [1/3] Checking for Ollama...
ollama --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ❌ Ollama is not installed.
    echo.
    echo  Opening the Ollama download page...
    start https://ollama.com/download
    echo.
    echo  1. Download and install Ollama from the page that just opened.
    echo  2. After installation, close this window and run this script again.
    echo.
    pause
    exit /b 1
)
echo  ✅ Ollama is installed.

:: ── Check if Ollama is running ───────────────────────────────────────
echo.
echo [2/3] Checking if Ollama is running...
curl -s http://localhost:11434/api/tags >nul 2>&1
if errorlevel 1 (
    echo  ⏳ Starting Ollama...
    start "" ollama serve
    timeout /t 3 /nobreak >nul
)
echo  ✅ Ollama is running.

:: ── Pull Recommended Models ──────────────────────────────────────────
echo.
echo [3/3] Pulling recommended AI models...
echo.
echo  These models power VoiceForge's formatting features.
echo  Each model only needs to download once.
echo.

echo  ── Model 1/2: gemma3:4b (3.3 GB) ──
echo  Used for: Markdown formatting
echo.
ollama pull gemma3:4b

echo.
echo  ── Model 2/2: mistral:7b (4.4 GB) ──
echo  Used for: Summary, Prompt, Speech, Dev modes
echo.
ollama pull mistral:7b

echo.
echo  ╔══════════════════════════════════════════╗
echo  ║  ✅ Ollama setup complete!               ║
echo  ║                                          ║
echo  ║  Models installed:                       ║
echo  ║    • gemma3:4b  — Markdown formatting    ║
echo  ║    • mistral:7b — Summary, Prompt, etc.  ║
echo  ║                                          ║
echo  ║  You can now launch VoiceForge.exe!      ║
echo  ╚══════════════════════════════════════════╝
echo.
pause
