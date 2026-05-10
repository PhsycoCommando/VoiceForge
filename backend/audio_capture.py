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

import ctypes
import os
import wave
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
      2. Best real hardware mic (avoids virtual/software audio)
      3. System default as last resort

    Virtual audio devices (Voicemod, Voicemeeter, VB-Cable, NVIDIA Broadcast, etc.)
    are explicitly BLACKLISTED because they process/modify audio in ways that
    destroy Whisper transcription accuracy.
    """
    global _selected_mic

    if _selected_mic is not None:
        return _selected_mic

    mics = sc.all_microphones(include_loopback=False)

    print("🔧 Available microphones (WASAPI):")
    for i, m in enumerate(mics):
        print(f"   [{i}] {m.name}")

    # --- Manual override from config ---
    if cfg.mic_device >= 0 and cfg.mic_device < len(mics):
        _selected_mic = mics[cfg.mic_device]
        print(f"🎤 Selected mic (config): {_selected_mic.name} [{cfg.mic_device}]")
        return _selected_mic

    # --- Blacklist: virtual/software audio devices ---
    _VIRTUAL_KEYWORDS = [
        "voicemod", "voicemeeter", "vb-audio", "virtual cable", "cable",
        "nvidia broadcast", "rtx voice", "krisp", "loopback", "vac ",
        "virtual audio", "soundflower", "blackhole",
    ]

    def _is_virtual(mic_name: str) -> bool:
        nl = mic_name.lower()
        return any(kw in nl for kw in _VIRTUAL_KEYWORDS)

    # --- Priority scoring for real mics ---
    # Higher = better candidate for live speech transcription
    _PREFERRED_KEYWORDS = ["barracuda", "razer", "blue", "yeti", "shure", "rode",
                           "sennheiser", "audio-technica", "hyperx", "steelseries",
                           "snowball", "cardioid", "condenser", "usb mic"]
    _GENERIC_KEYWORDS   = ["microphone", "mic", "input", "realtek", "headset"]

    def _score(mic_name: str) -> int:
        nl = mic_name.lower()
        if _is_virtual(nl):
            return -1          # never pick these
        for kw in _PREFERRED_KEYWORDS:
            if kw in nl:
                return 3       # branded hardware mic
        for kw in _GENERIC_KEYWORDS:
            if kw in nl:
                return 2       # generic real mic
        return 1               # unknown but real

    scored = [(m, _score(m.name)) for m in mics]
    scored.sort(key=lambda x: x[1], reverse=True)

    best_mic, best_score = scored[0] if scored else (None, -1)

    if best_score < 0:
        # All mics are virtual — fall back to system default and warn
        print("⚠️  All detected mics are virtual devices. Falling back to system default.")
        _selected_mic = sc.default_microphone()
    else:
        _selected_mic = best_mic

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
        # Shared mode (no exclusive flags) — blocksize=256 for fast stop response
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
                blocksize=256,
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
    global _is_recording, _recorder, _microphone, _capture_sr

    if _is_recording:
        return

    # In mock WAV mode we skip all WASAPI initialization — audio_stream()
    # reads from the file directly and never touches the soundcard.
    if os.environ.get("VOICEFORGE_MOCK_WAV"):
        _is_recording = True
        print("[Audio] MOCK MODE: start_recording() skipping WASAPI init")
        return

    # Initialize COM for this thread — Windows/WASAPI only, no-op on Linux
    if hasattr(ctypes, 'windll'):
        try:
            ctypes.windll.ole32.CoInitialize(None)
        except Exception:
            pass

    # 💥 Always ensure fresh valid recorder session
    if _recorder is not None:
        try:
            _recorder.__exit__(None, None, None)
        except Exception:
            pass

        _recorder = None
        _microphone = None
        _capture_sr = None

    # 🔁 Rebuild clean
    _init_recorder()

    try:
        _recorder.__enter__()
    except Exception as e:
        print(f"[Audio] Failed to enter recorder: {e}")
        return

    _is_recording = True
    print("🎤 Recording started (fresh session)")


def stop_recording():
    global _is_recording

    if not _is_recording:
        return

    _is_recording = False

    print("🎤 Recording stopped (soft stop)")


# ---------------------------------------------------------------------------
# Public: audio stream generator
# ---------------------------------------------------------------------------

def audio_stream(device_id=None, sample_rate=None):
    global _recorder, _microphone, _capture_sr

    """
    Generator that yields audio chunks as numpy arrays (N, 1) float32 at
    16 000 Hz, ready for the Whisper transcription pipeline.

    Captures at the device's native rate and resamples if necessary.

    IMPORTANT: start_recording() MUST be called before iterating this
    generator.  audio_stream() is a pure data pipe — it does NOT manage
    the recording lifecycle.
    """

    mock_wav = os.environ.get("VOICEFORGE_MOCK_WAV")
    if mock_wav and os.path.exists(mock_wav):
        print(f"[Audio] MOCK MODE: playing {mock_wav} instead of mic")
        try:
            with wave.open(mock_wav, "rb") as wf:
                framerate = wf.getframerate()
                n_channels = wf.getnchannels()
                sampwidth = wf.getsampwidth()
                frames = wf.readframes(wf.getnframes())
            if sampwidth == 2:
                audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
            elif sampwidth == 4:
                audio = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
            elif sampwidth == 1:
                audio = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
            else:
                print(f"[Audio] Mock WAV error: Unsupported sample width {sampwidth}")
                return

            if n_channels == 2:
                audio = audio.reshape(-1, 2).mean(axis=1)

            if framerate != _WHISPER_SR:
                num_samples = int(len(audio) * _WHISPER_SR / framerate)
                audio = resample_poly(audio, num_samples, len(audio)).astype(np.float32)

            chunk_size = 512
            idx = 0
            while _is_recording:
                if idx + chunk_size > len(audio):
                    idx = 0  # Loop back to beginning
                
                raw = audio[idx:idx + chunk_size]
                idx += chunk_size
                raw = raw[:, np.newaxis]
                
                time.sleep(chunk_size / _WHISPER_SR)
                yield raw
                
        except Exception as e:
            print(f"[Audio] MOCK WAV ERROR: {e}")
        return

    try:
        while _is_recording:

            # 🧠 Ensure recorder exists
            if _recorder is None:
                try:
                    _init_recorder()
                    _recorder.__enter__()
                    print("[Audio] Recorder reinitialized")
                except Exception as e:
                    print(f"[Audio] Failed to initialize recorder: {e}")
                    time.sleep(0.5)
                    continue

            try:
                # Pull audio in smaller chunks to reduce blocking delay
                raw = _recorder.record(numframes=1024)

            except Exception as e:
                print(f"[Audio] Recorder error: {e}")
                print("[Audio] Recorder lost — attempting recovery...")

                # Reset broken recorder state
                try:
                    _recorder.__exit__(None, None, None)
                except Exception:
                    pass

                _recorder = None
                _microphone = None
                _capture_sr = None

                time.sleep(0.5)

                try:
                    _init_recorder()
                    _recorder.__enter__()
                    print("[Audio] Recovery successful")
                    continue
                except Exception as e2:
                    print(f"[Audio] Recovery failed: {e2}")
                    print("[Audio] Stopping recording")
                    stop_recording()
                    time.sleep(0.5)
                    continue

            # Ensure (N, channels) float32
            if raw.ndim == 1:
                raw = raw[:, np.newaxis]
            raw = raw.astype(np.float32)

            # Resample to 16 kHz if needed
            if _capture_sr and _capture_sr != _WHISPER_SR:
                raw = _resample(raw, _capture_sr)

            # Collapse to mono if needed
            if raw.shape[1] > 1:
                raw = raw.mean(axis=1, keepdims=True)

            # Exit cleanly after processing — no partial pipeline push
            if not _is_recording:
                break

            yield raw

    except GeneratorExit:
        # Pipeline is tearing us down — just exit cleanly.
        # stop_recording() is called by the pipeline, not the generator.
        pass

    finally:
        # Nothing to clean up — lifecycle is owned by the pipeline.
        pass