#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# VoiceForge — Linux Backend Setup Script
# Creates a Python virtual environment and installs all backend dependencies.
# ─────────────────────────────────────────────────────────────────────────────

set -e
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "🔧 VoiceForge Backend Setup"
echo "📂 Directory: $SCRIPT_DIR"

# ── Create venv if it doesn't exist ──────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

# ── Activate venv ─────────────────────────────────────────────────────────────
source "$VENV_DIR/bin/activate"

# ── Upgrade pip ───────────────────────────────────────────────────────────────
echo "⬆️  Upgrading pip..."
pip install --upgrade pip --quiet

# ── Install deps ──────────────────────────────────────────────────────────────
echo "📦 Installing requirements..."
pip install -r "$SCRIPT_DIR/requirements.txt"

# ── CUDA check ────────────────────────────────────────────────────────────────
if python3 -c "import torch; print('CUDA:', torch.cuda.is_available())" 2>/dev/null | grep -q "True"; then
    echo "✅ CUDA is available — faster-whisper will use GPU acceleration"
else
    echo "⚠️  CUDA not detected — faster-whisper will run on CPU"
    echo "   Tip: set 'device': 'cpu' in voice_forge.json if errors occur"
fi

echo ""
echo "✅ VoiceForge backend dependencies installed."
echo "   Run with: ./run_backend.sh"
