#!/bin/bash
# ============================================================================
# VoiceForge Runner
# Starts backend (hidden) -> launches UI (foreground) -> cleanup on exit
# ============================================================================

set -euo pipefail

# ── Resolve project root ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VENV_DIR="$PROJECT_DIR/venv"
SERVER_SCRIPT="$PROJECT_DIR/server.py"
UI_BINARY="$PROJECT_DIR/ui/build/linux/x64/release/bundle/voice_forge_ui"
LOG_DIR="$PROJECT_DIR/.tmp"
LOG_FILE="$LOG_DIR/backend.log"
UI_PID_FILE="/tmp/voiceforge_ui.pid"
BACKEND_PID=""
BACKEND_STARTED_BY_US=false

# ── Cleanup function ─────────────────────────────────────────────────────
cleanup() {
    if [ "$BACKEND_STARTED_BY_US" = true ] && [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null
        for i in {1..10}; do
            kill -0 "$BACKEND_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$BACKEND_PID" 2>/dev/null && kill -9 "$BACKEND_PID" 2>/dev/null
    fi
    rm -f "$UI_PID_FILE"
}

trap cleanup EXIT INT TERM HUP

# ── Ensure log directory ─────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

# ── Kill stale backend (scoped to this project) ─────────────────────────
STALE_BACKEND=$(pgrep -f "voice_forge/server\.py" 2>/dev/null || true)
if [ -n "$STALE_BACKEND" ]; then
    kill $STALE_BACKEND 2>/dev/null || true
    sleep 0.3
fi

# ── Start backend ────────────────────────────────────────────────────────
if pgrep -f "voice_forge/server\.py" > /dev/null 2>&1; then
    BACKEND_PID=$(pgrep -f "voice_forge/server\.py" | head -1)
else
    source "$VENV_DIR/bin/activate"
    python "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
    BACKEND_PID=$!
    BACKEND_STARTED_BY_US=true

    # Wait for readiness (up to 5s)
    for i in {1..10}; do
        if curl -s http://localhost:8000/ > /dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
            exit 1
        fi
        sleep 0.5
    done
fi

# ── Launch UI ────────────────────────────────────────────────────────────
if [ ! -f "$UI_BINARY" ]; then
    echo "Error: UI binary not found at $UI_BINARY" >&2
    echo "Run: ./scripts/install.sh" >&2
    exit 1
fi

# Check for existing UI instance
if [ -f "$UI_PID_FILE" ]; then
    EXISTING_UI_PID=$(cat "$UI_PID_FILE" 2>/dev/null || true)
    if [ -n "$EXISTING_UI_PID" ] && kill -0 "$EXISTING_UI_PID" 2>/dev/null; then
        exit 0
    fi
    rm -f "$UI_PID_FILE"
fi

echo $$ > "$UI_PID_FILE"
cd "$(dirname "$UI_BINARY")" && exec "$UI_BINARY"
