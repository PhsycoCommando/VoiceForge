"""
speech_detector.py — Silence detection, speech thresholds, and buffering.

Accepts a stream of raw audio chunks and yields speech events:
  - ("partial", audio)          — periodically during speech for live preview
  - ("final", audio)            — after silence for cleaned transcription
  - ("paragraph_break", None)   — long pause detected (new thought/paragraph)
"""

import numpy as np
from scipy.signal import resample
from config import cfg


def extract_speech_segments(audio_chunks, native_sample_rate):
    """
    Generator that consumes raw audio chunks and yields speech events.

    Yields tuples of (event_type, audio_data):
      - ("partial", audio)        — during speech, every cfg.partial_interval chunks
      - ("final", audio)          — after silence detected
      - ("paragraph_break", None) — gap between finals exceeded paragraph threshold

    Args:
        audio_chunks: iterable of numpy arrays (raw mic chunks)
        native_sample_rate: the mic's native sample rate (e.g. 44100)

    Yields:
        tuple[str, numpy.ndarray | None] — (event_type, processed audio segment)
    """
    audio_buffer = []
    silence_counter = 0
    speech_detected = False
    chunks_since_partial = 0

    # Paragraph break tracking:
    # After emitting a final, count idle chunks until next speech.
    # If the gap exceeds paragraph_break_silence, emit paragraph_break
    # BEFORE the next final.
    chunks_since_last_final = 0
    has_emitted_final = False  # only break paragraphs after the first final

    # Hard cap: max chunks during active speech (~70s at 44100/1024).
    MAX_SPEECH_BUFFER = 3000

    for data in audio_chunks:
        audio_buffer.append(data)
        volume = np.max(np.abs(data))

        # Track silence vs speech
        if volume < cfg.silence_threshold:
            silence_counter += 1
        else:
            silence_counter = 0
            if volume >= cfg.speech_threshold:
                if not speech_detected:
                    print(f"🎙️ Speech detected! ({volume:.4f})")
                speech_detected = True

        # Count chunks since last partial (only while speaking)
        if speech_detected:
            chunks_since_partial += 1

        # Count chunks since last final (for paragraph break detection)
        if has_emitted_final and not speech_detected:
            chunks_since_last_final += 1

        # --- PARTIAL: emit live preview during speech ---
        if (speech_detected
                and chunks_since_partial >= cfg.partial_interval
                and len(audio_buffer) >= cfg.partial_min_chunks
                and silence_counter < cfg.silence_limit):
            audio_chunk = _prepare_audio(audio_buffer, native_sample_rate)
            yield ("partial", audio_chunk)
            chunks_since_partial = 0

        # --- FINAL: emit after silence + real speech was detected ---
        if silence_counter > cfg.silence_limit and speech_detected:
            # Check if we need a paragraph break BEFORE this final
            if (has_emitted_final
                    and chunks_since_last_final >= cfg.paragraph_break_silence):
                yield ("paragraph_break", None)

            audio_chunk = _prepare_audio(audio_buffer, native_sample_rate)
            yield ("final", audio_chunk)

            # Reset all state
            audio_buffer = []
            silence_counter = 0
            speech_detected = False
            chunks_since_partial = 0
            chunks_since_last_final = 0
            has_emitted_final = True

        # --- SAFETY: force-emit if buffer grows too large (long monologue) ---
        elif speech_detected and len(audio_buffer) >= MAX_SPEECH_BUFFER:
            print(f"⚠️ Buffer cap hit ({MAX_SPEECH_BUFFER} chunks), splitting segment")
            audio_chunk = _prepare_audio(audio_buffer, native_sample_rate)
            yield ("final", audio_chunk)

            # Reset but stay in speech mode (speaker hasn't stopped)
            audio_buffer = []
            silence_counter = 0
            chunks_since_partial = 0
            chunks_since_last_final = 0
            has_emitted_final = True

        # Prevent memory leak: trim buffer if it grows huge with no speech
        elif not speech_detected and len(audio_buffer) > cfg.max_idle_buffer:
            audio_buffer = audio_buffer[-cfg.idle_buffer_keep:]

    # ── End of stream: flush remaining buffered speech ───────────────────────
    # When stop_recording() is called, audio_stream() exits its while loop and
    # this generator's for loop ends via StopIteration. Any audio that was
    # accumulating but never hit a silence window would be silently dropped.
    # Emit it as a final now so nothing is lost.
    if speech_detected and len(audio_buffer) >= cfg.min_buffer_size:
        audio_chunk = _prepare_audio(audio_buffer, native_sample_rate)
        yield ("final", audio_chunk)



def _prepare_audio(buffer, native_sample_rate):
    """
    Concatenate buffered chunks, normalize, boost, flatten, and resample to 16kHz.

    Args:
        buffer: list of numpy arrays (raw audio chunks)
        native_sample_rate: the mic's native sample rate

    Returns:
        numpy array — processed audio, float32, resampled to cfg.target_sample_rate
    """
    audio_chunk = np.concatenate(buffer, axis=0)

    # Normalize
    max_val = np.max(np.abs(audio_chunk))
    if max_val > 0:
        audio_chunk = audio_chunk / max_val

    # Boost signal
    audio_chunk = audio_chunk * cfg.signal_boost
    audio_chunk = audio_chunk.flatten()

    # Resample to 16kHz
    num_samples = int(len(audio_chunk) * cfg.target_sample_rate / native_sample_rate)
    audio_chunk = resample(audio_chunk, num_samples)

    return audio_chunk.astype("float32")
