@echo off
setlocal
cd /d "%~dp0"

echo.
echo  ╔══════════════════════════════════════════╗
echo  ║   VoiceForge Backend Installer           ║
echo  ╚══════════════════════════════════════════╝
echo.

:: ── Check Python ─────────────────────────────────────────────────────
echo [1/3] Checking for Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ❌ Python is not installed or not in PATH.
    echo.
    echo  Please install Python 3.12 or newer from:
    echo  https://www.python.org/downloads/
    echo.
    echo  IMPORTANT: Check "Add Python to PATH" during installation!
    echo.
    pause
    exit /b 1
)
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do (
    echo  ✅ Found Python %%v
)

:: ── Create Virtual Environment ───────────────────────────────────────
echo.
echo [2/3] Setting up virtual environment...
if not exist "backend\venv" (
    echo  Creating backend\venv...
    python -m venv backend\venv
    if errorlevel 1 (
        echo  ❌ Failed to create virtual environment.
        pause
        exit /b 1
    )
    echo  ✅ Virtual environment created.
) else (
    echo  ✅ Virtual environment already exists.
)

:: ── Install Dependencies ─────────────────────────────────────────────
echo.
echo [3/3] Installing Python packages...
echo  This may take a few minutes on first install...
echo.
call backend\venv\Scripts\pip.exe install -r backend\requirements.txt --quiet
if errorlevel 1 (
    echo.
    echo  ❌ Package installation failed. Check the output above.
    pause
    exit /b 1
)

echo.
echo  ╔══════════════════════════════════════════╗
echo  ║  ✅ Backend installed successfully!      ║
echo  ║                                          ║
echo  ║  Next: Run install_ollama.bat for AI     ║
echo  ║  Then: Double-click VoiceForge.exe       ║
echo  ╚══════════════════════════════════════════╝
echo.
pause
