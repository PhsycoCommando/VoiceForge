@echo off
setlocal

cd /d "%~dp0"

:: ── Dev-mode launcher ──────────────────────────────────────────────
:: Starts the Python backend (in a visible window so errors show up),
:: then launches the Flutter UI via "flutter run -d windows".
:: ──────────────────────────────────────────────────────────────────

:: 1. Start backend if port 8000 is not already listening
netstat -ano | findstr ":8000 " | findstr "LISTENING" >nul
if errorlevel 1 (
    echo [VoiceForge] Starting backend...
    start "VoiceForge Backend" cmd /k "cd /d "%~dp0backend" && venv\Scripts\python.exe server.py"
    timeout /t 3 /nobreak >nul
) else (
    echo [VoiceForge] Backend already running on port 8000.
)

:: 2. Launch Flutter UI in dev mode
echo [VoiceForge] Launching Flutter UI...
start "VoiceForge UI" cmd /k "cd /d "%~dp0ui" && flutter run -d windows"

exit /b 0
