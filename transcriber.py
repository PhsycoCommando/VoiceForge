"""
transcriber.py — Whisper transcription wrapper.

Loads the faster-whisper model once and exposes two interfaces:
  - transcribe()         — high quality, for final results
  - transcribe_partial() — fast, for live preview during speech
"""

from faster_whisper import WhisperModel
from config import cfg


# Load model once at import time
print("Loading Whisper model...")
_model = WhisperModel(cfg.model_size, device=cfg.device, compute_type=cfg.compute_type)
print("✅ Model loaded.")


def transcribe(audio_chunk):
    """
    High-quality transcription for final results.

    Uses beam_size=5, best_of=5, VAD filter for best accuracy.

    Args:
        audio_chunk: numpy array, float32, 16kHz mono

    Returns:
        str — transcribed text, or empty string if nothing useful detected
    """
    return _run_whisper(audio_chunk, beam_size=5, best_of=5, vad_filter=True)


def transcribe_partial(audio_chunk):
    """
    Fast transcription for live partial preview.

    Uses beam_size=1, best_of=1, no VAD filter for speed.
    Lower quality is acceptable since this gets replaced by the final pass.

    Args:
        audio_chunk: numpy array, float32, 16kHz mono

    Returns:
        str — transcribed text, or empty string if nothing detected
    """
    return _run_whisper(audio_chunk, beam_size=1, best_of=1, vad_filter=False)


def _run_whisper(audio_chunk, beam_size, best_of, vad_filter):
    """
    Internal: run Whisper with the given settings.

    Returns:
        str — transcribed text, or empty string
    """
    try:
        segments, _ = _model.transcribe(
            audio_chunk,
            language="en",
            beam_size=beam_size,
            best_of=best_of,
            vad_filter=vad_filter,
        )

        full_text = " ".join([seg.text.strip() for seg in segments])

        # Filter out hallucinations (dots, empty results)
        if full_text and full_text.strip(".").strip():
            # Minimal raw cleanup: ensure trailing punctuation
            text = full_text.strip()
            if text and text[-1] not in ".!?,;:":
                text += "."
            return text

        return ""

    except Exception as e:
        print(f"❌ Whisper error: {e}")
        return ""
