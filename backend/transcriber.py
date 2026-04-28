"""
transcriber.py — Whisper transcription wrapper for live streaming.

Uses faster-whisper directly for live mic transcription.

Design philosophy (raw mode):
  - NO blocklists. NO filtering. NO post-processing.
  - Return exactly what Whisper heard, word for word.
  - Formatting (punctuation, cleanup) is handled at the UI layer on demand.

Two public interfaces:
  - transcribe()         — final results (vad_filter=True to reject silent chunks)
  - transcribe_partial() — fast live preview (beam_size=1, no vad for low latency)
"""

import warnings
warnings.filterwarnings("ignore", message="torchcodec is not installed")
warnings.filterwarnings("ignore", category=UserWarning, module="pyannote")

import numpy as np
from faster_whisper import WhisperModel
from config import cfg


# ---------------------------------------------------------------------------
# Model loading — once at import time
# ---------------------------------------------------------------------------

print("Loading Whisper model...")

_model = WhisperModel(
    cfg.model_size,
    device=cfg.device,
    compute_type=cfg.compute_type,
)
print(f"[Transcriber] Ready: {cfg.model_size} / {cfg.device} / {cfg.compute_type}")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def transcribe(audio_chunk) -> str:
    """
    Transcribe a committed audio segment (after silence detected).

    vad_filter=True: Whisper's built-in Silero VAD rejects silent chunks
    so we don't transcribe silence and get phantom words.

    Returns raw text exactly as Whisper heard it. No filtering, no blocklist.
    """
    return _run(audio_chunk, beam_size=5, best_of=5, vad_filter=True)


def transcribe_partial(audio_chunk) -> str:
    """
    Fast live preview transcription during active speech.

    beam_size=1 for speed. vad_filter=False so short partial chunks
    aren't incorrectly rejected.

    Returns raw text as-is.
    """
    return _run(audio_chunk, beam_size=1, best_of=1, vad_filter=False)


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

def _run(audio_chunk, beam_size: int, best_of: int, vad_filter: bool) -> str:
    """
    Run faster-whisper and return joined segment text.

    No post-processing. No blocklist. No punctuation stripping.
    The raw text exactly as Whisper produced it.
    """
    try:
        # Minimum length guard: less than ~0.1s of audio will produce garbage
        if len(audio_chunk) < 1600:  # 0.1s at 16kHz
            return ""

        segments, _info = _model.transcribe(
            audio_chunk,
            language="en",
            beam_size=beam_size,
            best_of=best_of,
            vad_filter=vad_filter,
        )

        # Materialise the generator — faster-whisper streams lazily
        text = " ".join(seg.text.strip() for seg in segments).strip()
        return text

    except Exception as e:
        print(f"[Transcriber] Error: {e}")
        return ""
