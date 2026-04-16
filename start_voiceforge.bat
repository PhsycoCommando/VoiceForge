@echo off
setlocal

:: Ensure script runs from its own directory
cd /d "%~dp0"

echo [VoiceForge] Checking backend status...

:: Check if backend already running (port 8000)
netstat -ano | findstr :8000 >nul
if %errorlevel%==0 (
    echo [VoiceForge] Backend already running.
) else (
    echo [VoiceForge] Starting Backend Server...

    pushd backend
    start "VoiceForge Backend" /MIN "venv\Scripts\python.exe" "server.py"
    popd

    echo [VoiceForge] Waiting for backend to initialize...
    timeout /t 2 /nobreak >nul
)

echo [VoiceForge] Launching User Interface...
start "" "VoiceForge.exe"

exit
