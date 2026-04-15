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

BACKEND_PID=""

# ── Cleanup function ─────────────────────────────────────────────────────
cleanup() {
    if [ -n "$BACKEND_PID" ] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null
        for i in {1..10}; do
            kill -0 "$BACKEND_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$BACKEND_PID" 2>/dev/null && kill -9 "$BACKEND_PID" 2>/dev/null
    fi
}

trap cleanup EXIT INT TERM HUP

# ── Ensure log directory ─────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

# ── Kill stale backend ───────────────────────────────────────────────────
pkill -f "python.*server\.py" 2>/dev/null || true
sleep 0.3

# ── Start backend ────────────────────────────────────────────────────────
source "$VENV_DIR/bin/activate"
python "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
BACKEND_PID=$!

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

# ── Launch UI ────────────────────────────────────────────────────────────
if [ ! -f "$UI_BINARY" ]; then
    echo "Error: UI binary not found at $UI_BINARY" >&2
    echo "Run: ./scripts/install.sh" >&2
    exit 1
fi

(cd "$(dirname "$UI_BINARY")" && exec "$UI_BINARY")
