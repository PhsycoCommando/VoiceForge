#!/bin/bash
# ============================================================================
# VoiceForge Installer
# Sets up Python venv, installs dependencies, builds Flutter UI,
# and registers the desktop launcher.
# ============================================================================

set -euo pipefail

# ── Resolve project root (directory containing this script's parent) ──────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VENV_DIR="$PROJECT_DIR/venv"
REQUIREMENTS="$PROJECT_DIR/requirements.txt"
ICON_SOURCE="$PROJECT_DIR/assets/voiceforge.png"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"
RUN_SCRIPT="$SCRIPT_DIR/run.sh"

# ── Colors ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC}   $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; }

# ── Header ────────────────────────────────────────────────────────────────
echo ""
echo "  VoiceForge Installer"
echo "  ────────────────────"
echo "  Project: $PROJECT_DIR"
echo ""

# ── 1. Check system dependencies ─────────────────────────────────────────
echo "Checking system dependencies..."

MISSING=""

if ! command -v python3 &>/dev/null; then
    MISSING="$MISSING python3"
fi

if ! python3 -c "import venv" &>/dev/null; then
    MISSING="$MISSING python3-venv"
fi

if ! command -v curl &>/dev/null; then
    MISSING="$MISSING curl"
fi

# Check for PortAudio (required by sounddevice)
if ! ldconfig -p 2>/dev/null | grep -q libportaudio; then
    if ! dpkg -l libportaudio2 &>/dev/null 2>&1; then
        MISSING="$MISSING libportaudio2"
    fi
fi

if [ -n "$MISSING" ]; then
    fail "Missing system packages:$MISSING"
    echo "  Install them with:"
    echo "    sudo apt install$MISSING"
    exit 1
fi

info "System dependencies OK"

# ── 2. Create Python virtual environment ─────────────────────────────────
if [ -d "$VENV_DIR" ]; then
    info "Virtual environment exists ($VENV_DIR)"
else
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    info "Virtual environment created"
fi

# ── 3. Install Python dependencies ───────────────────────────────────────
echo "Installing Python dependencies..."
source "$VENV_DIR/bin/activate"

pip install --upgrade pip --quiet
pip install -r "$REQUIREMENTS" --quiet

info "Python dependencies installed"

# ── 4. Check for Ollama ──────────────────────────────────────────────────
echo "Checking for Ollama..."

if command -v ollama &>/dev/null; then
    if curl -s http://localhost:11434/api/tags &>/dev/null; then
        MODEL_COUNT=$(curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "0")
        info "Ollama is running ($MODEL_COUNT models available)"
    else
        warn "Ollama is installed but not running"
        echo "       Start it with: ollama serve"
        echo "       Then pull a model: ollama pull gemma3:4b"
    fi
else
    warn "Ollama is not installed (AI formatting modes will use fallback)"
    echo "       Install from: https://ollama.ai"
    echo "       Then pull a model: ollama pull gemma3:4b"
fi

# ── 5. Build Flutter UI (if not already built) ───────────────────────────
UI_BINARY="$PROJECT_DIR/ui/build/linux/x64/release/bundle/voice_forge_ui"

if [ -f "$UI_BINARY" ]; then
    info "Flutter UI binary exists (skipping build)"
else
    echo "Building Flutter UI..."

    # Find flutter
    FLUTTER_BIN=""
    if command -v flutter &>/dev/null; then
        FLUTTER_BIN="flutter"
    elif [ -f "$HOME/flutter/bin/flutter" ]; then
        FLUTTER_BIN="$HOME/flutter/bin/flutter"
    elif [ -f "/opt/flutter/bin/flutter" ]; then
        FLUTTER_BIN="/opt/flutter/bin/flutter"
    fi

    if [ -z "$FLUTTER_BIN" ]; then
        warn "Flutter SDK not found -- skipping UI build"
        echo "       Install Flutter and run:"
        echo "         cd $PROJECT_DIR/ui && flutter build linux --release"
    else
        (cd "$PROJECT_DIR/ui" && $FLUTTER_BIN build linux --release)

        if [ -f "$UI_BINARY" ]; then
            info "Flutter UI built successfully"
        else
            fail "Flutter build failed -- binary not found"
            echo "       Try manually: cd $PROJECT_DIR/ui && flutter build linux --release"
        fi
    fi
fi

# ── 6. Install desktop launcher ──────────────────────────────────────────
echo "Installing desktop launcher..."

mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_DIR/voiceforge.desktop" <<EOF
[Desktop Entry]
Name=VoiceForge
Comment=Local AI Voice Transcription System
Exec=bash -c "cd $PROJECT_DIR && ./scripts/run.sh"
Icon=$PROJECT_DIR/assets/voiceforge.png
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=false
EOF

info "Desktop entry installed"

# ── 7. Install icon ─────────────────────────────────────────────────────
echo "Installing icon..."

if [ -f "$ICON_SOURCE" ]; then
    SIZES=(16 32 48 64 128 256 512)

    # Check if we have ImageMagick for resizing
    if command -v convert &>/dev/null; then
        for SIZE in "${SIZES[@]}"; do
            ICON_DIR="$ICON_BASE/${SIZE}x${SIZE}/apps"
            mkdir -p "$ICON_DIR"
            convert "$ICON_SOURCE" -resize "${SIZE}x${SIZE}" "$ICON_DIR/voiceforge.png"
        done
        info "Icons installed (${#SIZES[@]} sizes)"
    else
        # No ImageMagick -- just copy the full-size icon to common sizes
        for SIZE in "${SIZES[@]}"; do
            ICON_DIR="$ICON_BASE/${SIZE}x${SIZE}/apps"
            mkdir -p "$ICON_DIR"
            cp "$ICON_SOURCE" "$ICON_DIR/voiceforge.png"
        done
        info "Icons installed (single source, no resize -- install imagemagick for proper scaling)"
    fi

    # Also copy to generic fallback location
    mkdir -p "$HOME/.local/share/icons"
    cp "$ICON_SOURCE" "$HOME/.local/share/icons/voiceforge.png"

    # Update icon cache
    gtk-update-icon-cache -f "$ICON_BASE" 2>/dev/null || true
else
    warn "Icon source not found at $ICON_SOURCE"
fi

# ── 8. Update desktop database ───────────────────────────────────────────
update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

# ── 9. Make scripts executable ───────────────────────────────────────────
chmod +x "$RUN_SCRIPT" 2>/dev/null || true
chmod +x "${BASH_SOURCE[0]}" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo "  ────────────────────"
echo "  Installation complete."
echo ""
echo "  Launch VoiceForge:"
echo "    - Search 'VoiceForge' in your application menu"
echo "    - Or run: ./scripts/run.sh"
echo ""
