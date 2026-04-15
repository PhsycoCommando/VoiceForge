"""
audio_capture.py — Microphone input handler.

Provides a streaming interface to the mic via sounddevice.
Yields raw audio chunks as numpy arrays.
"""

import queue
import sounddevice as sd
from config import cfg

# Cap the audio queue to prevent unbounded memory growth.
# If Whisper transcription falls behind, old chunks are dropped
# rather than letting the queue grow forever.
_MAX_QUEUE_SIZE = 2000  # ~46s of audio at 44100/1024


def get_native_sample_rate(device_id=None):
    """Query the native sample rate of the given input device."""
    if device_id is None:
        device_id = cfg.mic_device
    device_info = sd.query_devices(device_id, 'input')
    return int(device_info['default_samplerate'])


def audio_stream(device_id=None, sample_rate=None):
    """
    Generator that yields raw audio chunks from the microphone.

    Each chunk is a numpy array of shape (frames, 1), dtype float32.
    Blocks until a new chunk is available.

    The internal queue is capped to prevent unbounded memory growth.
    If the consumer falls behind, the oldest chunks are dropped.

    Usage:
        for chunk in audio_stream():
            process(chunk)
    """
    if device_id is None:
        device_id = cfg.mic_device
    if sample_rate is None:
        sample_rate = get_native_sample_rate(device_id)

    q = queue.Queue(maxsize=_MAX_QUEUE_SIZE)

    def callback(indata, frames, time, status):
        if status:
            print(f"⚠️ Audio status: {status}")
        try:
            q.put_nowait(indata.copy())
        except queue.Full:
            # Drop oldest chunk to make room — consumer is too slow
            try:
                q.get_nowait()
            except queue.Empty:
                pass
            try:
                q.put_nowait(indata.copy())
            except queue.Full:
                pass  # still full somehow, just drop this chunk

    print(f"🎤 Using device {device_id}")
    print(f"🎤 Native sample rate: {sample_rate}")

    with sd.InputStream(
        samplerate=sample_rate,
        channels=1,
        dtype="float32",
        device=device_id,
        callback=callback,
    ):
        while True:
            yield q.get()
