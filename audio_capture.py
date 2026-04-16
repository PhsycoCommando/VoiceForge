"""
audio_capture.py — Microphone input handler.

Uses the `soundcard` library (WASAPI-native on Windows).
No PortAudio, no WDM-KS, no PaErrorCode -9999.

Key design principles:
  - Singleton recorder: opened ONCE, never reopened between sessions.
  - Only reopened when the user explicitly changes devices.
  - Records at the device's NATIVE sample rate then resamples to 16 kHz
    for Whisper, avoiding WASAPI rejections caused by forcing 16 kHz on
    devices running at 44100 / 48000 Hz.
  - Shared mode only — never exclusive. Compatible with Voicemeter,
    Voicemod, and other virtual routing software.
  - 300 ms delay before opening WASAPI to let virtual drivers settle.
"""

import time
import numpy as np
import soundcard as sc
from scipy.signal import resample_poly
from math import gcd
from config import cfg

# ---------------------------------------------------------------------------
# Globals — singleton state
# ---------------------------------------------------------------------------

_MAX_QUEUE_SIZE = 2000

_recorder    = None   # soundcard Recorder context manager (open once)
_microphone  = None   # soundcard Microphone object
_capture_sr  = None   # sample rate the device was actually opened at
_is_recording = False
_selected_mic = None  # cached mic object (survives stop/start cycles)


# ---------------------------------------------------------------------------
# Public: device listing & manual selection
# ---------------------------------------------------------------------------

def list_microphones():
    """
    Return all available WASAPI input devices.

    Returns:
        list[dict]  [{\"id\": 0, \"name\": \"Microphone (Realtek)\"}, ...]
    """
    mics = sc.all_microphones(include_loopback=False)
    return [{"id": i, "name": m.name} for i, m in enumerate(mics)]


def set_microphone(device_id: int):
    """
    Manually select a microphone by index.

    Tears down any existing open recorder safely, then pre-initialises
    the new device so it is ready for the next recording session.

    Args:
        device_id: Index from list_microphones()

    Returns:
        dict  {\"id\": ..., \"name\": ...}

    Raises:
        ValueError if device_id is out of range.
    """
    global _recorder, _microphone, _selected_mic, _capture_sr

    mics = sc.all_microphones(include_loopback=False)
    if device_id < 0 or device_id >= len(mics):
        raise ValueError(
            f"Invalid mic index {device_id}. Available: 0–{len(mics) - 1}"
        )

    # --- tear down existing open recorder safely ---
    if _recorder is not None:
        try:
            _recorder.__exit__(None, None, None)
        except Exception:
            pass
        _recorder = None

    _microphone  = None
    _capture_sr  = None
    _selected_mic = mics[device_id]

    # Pre-initialise so the device is ready immediately
    _init_recorder()

    print(f"🎤 Mic manually set: {_selected_mic.name} (index: {device_id})")
    return {"id": device_id, "name": _selected_mic.name}


def get_selected_microphone_info():
    """Return the currently selected mic's name, or None if not yet chosen."""
    if _selected_mic is None:
        return None
    return {"name": _selected_mic.name}


# ---------------------------------------------------------------------------
# Private: device auto-selection
# ---------------------------------------------------------------------------

def _auto_select_mic():
    """
    Choose the best available mic using the priority order:
      1. cfg.mic_device if set (>= 0)
      2. "Voicemod" device
      3. "Microphone" device
      4. System default
    """
    global _selected_mic

    if _selected_mic is not None:
        return _selected_mic

    mics = sc.all_microphones(include_loopback=False)

    print("🔧 Available microphones (WASAPI):")
    for i, m in enumerate(mics):
        print(f"   [{i}] {m.name}")

    if cfg.mic_device >= 0 and cfg.mic_device < len(mics):
        _selected_mic = mics[cfg.mic_device]
        print(f"🎤 Selected mic (config): {_selected_mic.name} [{cfg.mic_device}]")
        return _selected_mic

    voicemod_mic   = None
    microphone_mic = None
    for m in mics:
        nl = m.name.lower()
        if "voicemod" in nl and voicemod_mic is None:
            voicemod_mic = m
        elif "microphone" in nl and microphone_mic is None:
            microphone_mic = m

    _selected_mic = voicemod_mic or microphone_mic or sc.default_microphone()
    print(f"🎤 Selected mic (auto): {_selected_mic.name}")
    return _selected_mic


# ---------------------------------------------------------------------------
# Private: native-rate detection
# ---------------------------------------------------------------------------

def _get_native_rate(mic) -> int:
    """
    Return the device's preferred sample rate.

    soundcard exposes `default_samplerate` on the underlying CoreAudio /
    WASAPI device.  We use that so we never force an unsupported rate onto
    the driver (the root cause of WDM-KS -9999 errors).

    Falls back to 48000 (the most common Windows default) if the attribute
    is unavailable or reports 0.
    """
    try:
        rate = int(getattr(mic, "default_samplerate", 0))
        if rate > 0:
            return rate
    except Exception:
        pass
    return 48000   # safe universal fallback


# ---------------------------------------------------------------------------
# Private: resampling
# ---------------------------------------------------------------------------

_WHISPER_SR = 16000

def _resample(data: np.ndarray, from_sr: int) -> np.ndarray:
    """
    Resample `data` from `from_sr` Hz to 16 000 Hz using scipy polyphase
    resampling (high quality, no external deps beyond scipy).

    data shape: (N, channels) float32
    Returns:    (M, channels) float32
    """
    if from_sr == _WHISPER_SR:
        return data

    g  = gcd(from_sr, _WHISPER_SR)
    up = _WHISPER_SR // g
    dn = from_sr    // g

    if data.ndim == 1:
        return resample_poly(data, up, dn).astype(np.float32)

    # resample each channel
    channels = [
        resample_poly(data[:, ch], up, dn) for ch in range(data.shape[1])
    ]
    return np.stack(channels, axis=1).astype(np.float32)


# ---------------------------------------------------------------------------
# Private: singleton recorder initialisation
# ---------------------------------------------------------------------------

def _init_recorder():
    """
    Create the WASAPI recorder exactly once.

    Chooses the device's native sample rate to avoid WASAPI rejections,
    validates the device, and falls back to the system default on failure.
    """
    global _recorder, _microphone, _capture_sr, _selected_mic

    if _recorder is not None:
        return   # already open — nothing to do

    mic = _auto_select_mic()

    native_sr = _get_native_rate(mic)
    channels  = 1

    print(f"🔧 Device: {mic.name}")
    print(f"   Native sample rate : {native_sr} Hz")
    print(f"   Channels           : {channels}")

    # Device validation
    if native_sr <= 0:
        print("⚠️  Invalid sample rate — falling back to default mic")
        mic       = sc.default_microphone()
        native_sr = _get_native_rate(mic)
        _selected_mic = mic

    # --- 300 ms start delay: allows Voicemeter / Voicemod to release locks ---
    print("⏳ Waiting 300 ms for virtual audio drivers to settle...")
    time.sleep(0.3)

    try:
        _microphone = mic
        _capture_sr = native_sr
        # Shared mode (no exclusive flags) — blocksize=1024 ≈ 64 ms @ 16 kHz
        _recorder = _microphone.recorder(
            samplerate=native_sr,
            channels=channels,
            blocksize=1024,
        )
        print(f"✅ Recorder created: {mic.name} @ {native_sr} Hz (shared mode)")
    except Exception as e:
        print(f"⚠️  Failed to open {mic.name}: {e}")
        print("⚠️  Falling back to system default microphone")
        try:
            fallback     = sc.default_microphone()
            fb_rate      = _get_native_rate(fallback)
            time.sleep(0.3)
            _microphone  = fallback
            _capture_sr  = fb_rate
            _selected_mic = fallback
            _recorder    = fallback.recorder(
                samplerate=fb_rate,
                channels=1,
                blocksize=1024,
            )
            print(f"✅ Fallback recorder: {fallback.name} @ {fb_rate} Hz")
        except Exception as e2:
            raise RuntimeError(f"Cannot open any audio input device: {e2}") from e2


# ---------------------------------------------------------------------------
# Public: recording lifecycle
# ---------------------------------------------------------------------------

def get_native_sample_rate(device_id=None) -> int:
    """
    Return Whisper's required 16 kHz.
    (Actual capture may be at a higher rate; audio_stream resamples.)
    """
    return _WHISPER_SR


def start_recording(device=None):
    global _is_recording

    _init_recorder()

    if _is_recording:
        return

    _recorder.__enter__()
    _is_recording = True
    print("🎤 Recording started")


def stop_recording():
    global _is_recording

    if not _is_recording:
        return

    _is_recording = False
    try:
        _recorder.__exit__(None, None, None)
    except Exception:
        pass
    print("🎤 Recording stopped")


# ---------------------------------------------------------------------------
# Public: audio stream generator
# ---------------------------------------------------------------------------

def audio_stream(device_id=None, sample_rate=None):
    """
    Generator that yields audio chunks as numpy arrays (N, 1) float32 at
    16 000 Hz, ready for the Whisper transcription pipeline.

    Captures at the device's native rate and resamples if necessary.
    """
    start_recording(device_id)

    try:
        while True:
            if _is_recording:
                raw = _recorder.record(numframes=1024)

                # Ensure (N, channels) float32
                if raw.ndim == 1:
                    raw = raw[:, np.newaxis]
                raw = raw.astype(np.float32)

                # Resample to 16 kHz if device runs at a different rate
                if _capture_sr and _capture_sr != _WHISPER_SR:
                    raw = _resample(raw, _capture_sr)

                # Collapse to mono (N, 1) if multi-channel
                if raw.shape[1] > 1:
                    raw = raw.mean(axis=1, keepdims=True)

                yield raw
            else:
                time.sleep(0.05)
    except GeneratorExit:
        stop_recording()
        raise
    finally:
        stop_recording()
