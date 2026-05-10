#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# VoiceForge — Linux Backend Runner
# Activates the venv and starts the FastAPI backend server.
# ─────────────────────────────────────────────────────────────────────────────

set -e
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "❌ Virtual environment not found. Run setup.sh first."
    exit 1
fi

source "$VENV_DIR/bin/activate"

echo "🚀 Starting VoiceForge backend..."
cd "$SCRIPT_DIR"
exec uvicorn server:app --host 127.0.0.1 --port 8765 --log-level warning
