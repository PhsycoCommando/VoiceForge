"""
main.py — VoiceForge CLI orchestrator.

Architecture: "Capture First, Transform Later"
  - Pipeline captures raw speech faithfully
  - Raw text grouped into paragraphs by natural pauses
  - Formatting is applied on-demand
"""

import sys
import os

from audio_capture import audio_stream, get_native_sample_rate
from speech_detector import extract_speech_segments
from transcriber import transcribe, transcribe_partial
from formatter import Formatter
from config import cfg
from ai_formatter import register_ai_modes

# Register AI-powered formatting modes (ai_dev, ai_summary)
register_ai_modes()


def _get_cols():
    """Get terminal width, with fallback."""
    try:
        return os.get_terminal_size().columns
    except (ValueError, OSError):
        return 80


def _clear_line():
    """Clear the current terminal line (for overwriting partials)."""
    cols = _get_cols()
    sys.stdout.write("\r" + " " * cols + "\r")
    sys.stdout.flush()


def _is_dup_partial(new_text, old_text):
    """Return True if new partial is too similar to old to display."""
    if not old_text:
        return False
    new_s, old_s = new_text.strip(), old_text.strip()
    if new_s == old_s:
        return True
    if new_s.startswith(old_s) and len(new_s[len(old_s):].strip()) < 4:
        return True
    if old_s.startswith(new_s):
        return True
    return False


def run(mode=None):
    """Main pipeline loop with paragraph grouping."""
    if mode is None:
        mode = cfg.default_mode

    native_sr = get_native_sample_rate()

    print(f"🎤 Listening... Speak naturally, I'll wait for you to finish.")
    print(f"📦 Available modes: {', '.join(Formatter.available_modes())}")
    print(f"⚡ Live partials: enabled")
    print(f"📝 Paragraphs: grouped by natural pauses (~2s)")
    print()

    chunks = audio_stream(sample_rate=native_sr)
    events = extract_speech_segments(chunks, native_sr)

    last_partial = ""
    paragraphs = []     # list of paragraph strings
    current_para = ""   # building current paragraph

    for event_type, audio_segment in events:

        if event_type == "partial":
            text = transcribe_partial(audio_segment)
            if text and not _is_dup_partial(text, last_partial):
                _clear_line()
                cols = _get_cols()
                display = f"🎤 LIVE: {text}"
                if len(display) > cols - 1:
                    display = display[:cols - 4] + "..."
                sys.stdout.write(display)
                sys.stdout.flush()
                last_partial = text

        elif event_type == "paragraph_break":
            # Finalize current paragraph
            if current_para.strip():
                paragraphs.append(current_para.strip())
                print(f"\n{'─' * 40}")  # visual separator
            current_para = ""

        elif event_type == "final":
            _clear_line()
            last_partial = ""

            text = transcribe(audio_segment)
            if text:
                # Append to current paragraph (merge, don't split)
                current_para += " " + text if current_para else text
                print(f"📝 {current_para.strip()}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else None

    try:
        run(mode=mode)
    except KeyboardInterrupt:
        print("\n🛑 Stopped.")