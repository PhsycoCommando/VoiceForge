"""
server.py — FastAPI server for VoiceForge.

Bridges the audio pipeline to a Flutter UI (or any HTTP/WebSocket client).

Endpoints:
    GET  /              — health check + config summary
    GET  /config        — current configuration as JSON
    POST /transcribe    — one-shot: upload audio file, get transcription
    WS   /stream        — real-time: live transcription via WebSocket
    POST /stream/start  — start the live mic pipeline
    POST /stream/stop   — stop the live mic pipeline
    POST /mode          — switch formatting mode on the fly

Run:
    python server.py
    # or: uvicorn server:app --host 0.0.0.0 --port 8000
"""

# --- PyInstaller compatibility fixes ---
# Must run BEFORE any imports that pull in torch/faster_whisper/ctranslate2.
import sys as _sys
import os

# Force stdout/stderr to UTF-8 to prevent emoji crash on Windows cp1252
if hasattr(_sys.stdout, 'reconfigure'):
    _sys.stdout.reconfigure(encoding='utf-8')
if hasattr(_sys.stderr, 'reconfigure'):
    _sys.stderr.reconfigure(encoding='utf-8')

# Disable PyTorch JIT & dynamic inspection (global)
os.environ["TORCH_JIT"] = "0"
os.environ["PYTORCH_JIT"] = "0"
os.environ["TORCH_DISABLE_DYNAMIC_MODULE"] = "1"

if getattr(_sys, 'frozen', False):
    # 1. Redirect stdout/stderr — noconsole mode uses cp1252 which chokes on emoji
    _sys.stdout = open(_os.devnull, 'w', encoding='utf-8')
    _sys.stderr = open(_os.devnull, 'w', encoding='utf-8')

    # 2. Disable torch compile/JIT/dynamic features that inspect source files
    _os.environ["PYTORCH_JIT"] = "0"
    _os.environ["TORCH_JIT"] = "0"
    _os.environ["TORCH_DISABLE_DYNAMIC_MODULE"] = "1"

    # 3. Monkey-patch ALL inspect source functions — torch._config_module calls
    #    findsource → getsourcelines → getsource chain. Must patch findsource
    #    since that's where the actual OSError originates.
    import inspect as _inspect

    _orig_findsource = _inspect.findsource
    _orig_getsourcelines = _inspect.getsourcelines
    _orig_getsource = _inspect.getsource

    def _safe_findsource(obj):
        try:
            return _orig_findsource(obj)
        except OSError:
            return ([""], 0)

    def _safe_getsourcelines(obj):
        try:
            return _orig_getsourcelines(obj)
        except OSError:
            return ([""], 0)

    def _safe_getsource(obj):
        try:
            return _orig_getsource(obj)
        except OSError:
            return ""

    _inspect.findsource = _safe_findsource
    _inspect.getsourcelines = _safe_getsourcelines
    _inspect.getsource = _safe_getsource

    # 4. Disable TorchScript source parsing completely —
    #    torch._sources.parse_def bypasses inspect and reads raw .py files,
    #    which don't exist inside PyInstaller bundles.
    try:
        import torch._sources as _torch_sources

        def _safe_parse_def(*args, **kwargs):
            return None

        _torch_sources.parse_def = _safe_parse_def
    except Exception:
        pass

import asyncio
import io
import json
import queue as _queue
import threading
import time
import wave
from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Optional

import numpy as np
from fastapi import FastAPI, File, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from scipy.signal import resample

from config import cfg
from formatter import Formatter
from transcriber import transcribe, transcribe_partial
from ai_formatter import register_ai_modes
from session_manager import session_mgr

# Register AI-powered formatting modes (ai_dev, ai_summary)
register_ai_modes()


# ==============================================================================
# EVENT BUS — thread-safe broadcast from pipeline → WebSocket clients
# ==============================================================================

class EventBus:
    """
    Thread-safe pub/sub for streaming events to WebSocket clients.

    The pipeline thread calls publish() to broadcast events.
    Each WebSocket connection gets its own asyncio.Queue via subscribe().
    """

    def __init__(self):
        self._subscribers: dict[int, asyncio.Queue] = {}
        self._lock = threading.Lock()
        self._counter = 0

    def subscribe(self) -> tuple[int, asyncio.Queue]:
        """Register a new subscriber. Returns (id, queue)."""
        with self._lock:
            self._counter += 1
            sub_id = self._counter
            q = asyncio.Queue(maxsize=100)
            self._subscribers[sub_id] = q
            return sub_id, q

    def unsubscribe(self, sub_id: int):
        """Remove a subscriber."""
        with self._lock:
            self._subscribers.pop(sub_id, None)

    def publish(self, event: dict):
        """
        Broadcast an event dict to all subscribers.

        Called from the pipeline thread — uses put_nowait to avoid blocking.
        If a subscriber's queue is full, drains the oldest event to make room.
        This ensures high-priority events (finals, status) are never lost.
        """
        with self._lock:
            for q in self._subscribers.values():
                try:
                    q.put_nowait(event)
                except asyncio.QueueFull:
                    # Drain oldest event to make room
                    try:
                        q.get_nowait()
                    except asyncio.QueueEmpty:
                        pass
                    try:
                        q.put_nowait(event)
                    except asyncio.QueueFull:
                        pass

    def publish_except(self, event: dict, exclude_id: int):
        """
        Broadcast to all subscribers except the one with exclude_id.

        Used for text_update / clear so the originating client doesn't
        receive its own echo back.
        """
        with self._lock:
            for sub_id, q in self._subscribers.items():
                if sub_id == exclude_id:
                    continue
                try:
                    q.put_nowait(event)
                except asyncio.QueueFull:
                    try:
                        q.get_nowait()
                    except asyncio.QueueEmpty:
                        pass
                    try:
                        q.put_nowait(event)
                    except asyncio.QueueFull:
                        pass

    @property
    def subscriber_count(self) -> int:
        with self._lock:
            return len(self._subscribers)


event_bus = EventBus()


# ==============================================================================
# PIPELINE THREAD — runs mic → detection → transcription in background
# ==============================================================================

class PipelineManager:
    """
    Manages the background audio pipeline thread.

    Architecture: "Capture First, Transform Later"
    - Streaming path emits RAW text only (no formatting)
    - Session text accumulates for on-demand transformation via /transform
    - Thread-safe: all public methods use a lock
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._running = False
        self._mode = cfg.default_mode
        self._paragraphs: list[str] = []  # accumulated paragraphs

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def mode(self) -> str:
        return self._mode

    @property
    def session_text(self) -> str:
        """Get session text with paragraphs joined by double newlines."""
        with self._lock:
            return "\n\n".join(p.strip() for p in self._paragraphs if p.strip())

    @property
    def paragraphs(self) -> list[str]:
        """Get the raw list of paragraphs."""
        with self._lock:
            return [p.strip() for p in self._paragraphs if p.strip()]

    def set_mode(self, mode: str):
        """Switch formatting mode (thread-safe)."""
        with self._lock:
            Formatter(mode=mode)
            self._mode = mode

    def clear_session(self):
        """Clear the accumulated session text."""
        with self._lock:
            self._paragraphs = []

    def set_session_text(self, text: str):
        """Replace session text with manually edited content (typed edit or phone final)."""
        with self._lock:
            self._paragraphs = [text] if text.strip() else []

    def set_formatted_output(self, mode: str, formatted: str):
        """Store the latest formatted result so reconnecting clients can restore it."""
        with self._lock:
            self._formatted_output = formatted
            self._formatted_mode   = mode

    @property
    def formatted_output(self) -> str:
        with self._lock:
            return getattr(self, '_formatted_output', '')

    @property
    def formatted_mode(self) -> str:
        with self._lock:
            return getattr(self, '_formatted_mode', '')

    def start(self):
        """Start the background pipeline thread. No-op if already running."""
        with self._lock:
            if self._running:
                return

            self._stop_event.clear()
            self._paragraphs = []  # fresh session
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
            self._running = True

    def stop(self):
        """Stop the background pipeline thread and wait for it to finish."""
        with self._lock:
            if not self._running:
                return

            self._stop_event.set()
            self._running = False
            thread = self._thread
            self._thread = None

        # Join outside the lock to avoid deadlock if _run tries to acquire
        if thread is not None and thread.is_alive():
            thread.join(timeout=5.0)

    def _run(self):
        """
        Hybrid pipeline — live partials during recording, final batch on stop.

        Audio read loop never blocks (no transcription on the hot path).
        A background thread wakes every PARTIAL_INTERVAL seconds, transcribes
        new audio since the last partial, and emits it so the UI shows live text.
        On stop, a final high-quality pass transcribes the whole session and
        replaces the partials with the definitive result.
        """
        from audio_capture import audio_stream, get_native_sample_rate, \
            start_recording, stop_recording
        from speech_detector import _prepare_audio
        import numpy as np
        import threading

        all_chunks  = []          # every chunk collected, in order
        native_sr   = 16000       # updated once mic is ready
        partial_stop = threading.Event()

        CHUNKS_PER_SEC       = 47    # native 48kHz / blocksize 1024
        PARTIAL_INTERVAL     = 3.0   # seconds between worker wakeups
        MIN_CHUNKS_FOR_PARTIAL = 20  # ~0.4 s minimum before attempting
        MIN_PAUSE_SECS       = 3.0   # silence shorter than this → no dots
        SILENCE_TAIL_SECS    = 1.5   # keep last N secs when advancing cursor

        partial_text   = ""
        partial_cursor = 0
        dots_shown     = 0   # how many dot-seconds we've already emitted

        def worker():
            nonlocal partial_text, partial_cursor, dots_shown

            while not partial_stop.wait(PARTIAL_INTERVAL):
                try:
                    snapshot = list(all_chunks)
                    total    = len(snapshot)

                    # ── Count trailing silent chunks ───────────────────────
                    trailing_silent = 0
                    for c in reversed(snapshot):
                        if np.max(np.abs(c)) < cfg.silence_threshold:
                            trailing_silent += 1
                        else:
                            break
                    silent_secs = trailing_silent / CHUNKS_PER_SEC

                    # ── Pause branch ───────────────────────────────────────
                    if silent_secs >= MIN_PAUSE_SECS and partial_text:
                        # How many new dot-seconds since we last updated?
                        total_dot_secs = int(silent_secs)
                        new_dots = total_dot_secs - dots_shown
                        if new_dots > 0:
                            partial_text = partial_text.rstrip() + ("." * new_dots)
                            dots_shown   = total_dot_secs
                            # Advance cursor through silence (keep a tail so
                            # the start of the next sentence isn't clipped)
                            keep = int(SILENCE_TAIL_SECS * CHUNKS_PER_SEC)
                            partial_cursor = max(partial_cursor, total - keep)
                            event_bus.publish({
                                "type": "partial",
                                "raw": partial_text,
                                "formatted": partial_text,
                                "mode": self._mode,
                                "timestamp": time.time(),
                            })
                        continue

                    # ── Speech branch — reset dot counter ─────────────────
                    dots_shown = 0

                    new_chunks = snapshot[partial_cursor:total]
                    if len(new_chunks) < MIN_CHUNKS_FOR_PARTIAL:
                        continue

                    audio = _prepare_audio(new_chunks, native_sr)
                    text  = transcribe_partial(audio)

                    if text:
                        partial_cursor = total
                        partial_text   = (partial_text + " " + text).strip()
                        event_bus.publish({
                            "type": "partial",
                            "raw": partial_text,
                            "formatted": partial_text,
                            "mode": self._mode,
                            "timestamp": time.time(),
                        })

                except Exception as e:
                    print(f"[Partial worker] {e}")


        t = threading.Thread(target=worker, daemon=True)
        t.start()

        try:
            native_sr = get_native_sample_rate()
            start_recording()

            event_bus.publish({
                "type": "status",
                "status": "started",
                "sample_rate": native_sr,
                "mode": self._mode,
            })

            # ── Tight read loop — never blocks for transcription ─────────
            for chunk in audio_stream(sample_rate=native_sr):
                if self._stop_event.is_set():
                    break
                all_chunks.append(chunk)

        except Exception as e:
            event_bus.publish({"type": "error", "message": str(e)})

        finally:
            # Stop partial worker first
            partial_stop.set()
            t.join(timeout=10.0)

            stop_recording()

            # ── Final high-quality transcription ─────────────────────────
            if all_chunks:
                try:
                    audio = _prepare_audio(all_chunks, native_sr)
                    text  = transcribe(audio)
                    if text:
                        # Persist WAV for this recording
                        session_mgr.save_audio(audio, source="wasapi")
                        with self._lock:
                            self._paragraphs = [text]
                        event_bus.publish({
                            "type": "final",
                            "raw": text,
                            "formatted": text,
                            "mode": self._mode,
                            "timestamp": time.time(),
                        })
                except Exception as e:
                    event_bus.publish({"type": "error", "message": f"Transcription failed: {e}"})

            with self._lock:
                self._running = False
            event_bus.publish({"type": "status", "status": "stopped"})





pipeline = PipelineManager()


# ==============================================================================
# PHONE AUDIO PIPELINE — receives PCM from phone mic via binary WS frames
# ==============================================================================

class PhoneAudioPipeline:
    """
    Hybrid pipeline fed by binary PCM frames from the phone mic.

    Audio flows in via push_audio() (called from the WS binary frame handler).
    The partial worker and final pass are identical to PipelineManager._run
    but use a push-based audio queue instead of WASAPI.

    Expected PCM format: 16kHz, mono, int16 (same as Whisper target).
    """

    SAMPLE_RATE      = 16000
    CHUNK_SIZE       = 2048    # samples per binary frame from phone
    CHUNKS_PER_SEC   = SAMPLE_RATE / CHUNK_SIZE   # ~7.8
    PARTIAL_INTERVAL = 3.0
    MIN_CHUNKS_FOR_PARTIAL = 6   # ~0.75 s
    MIN_PAUSE_SECS   = 3.0
    SILENCE_TAIL_SECS = 1.5

    def __init__(self):
        self._lock        = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop_event  = threading.Event()
        self._running     = False
        self._all_chunks: list = []   # float32 numpy arrays

    @property
    def is_running(self) -> bool:
        return self._running

    def push_audio(self, data: bytes):
        """Receive a binary PCM int16 frame and enqueue it for transcription."""
        if self._running:
            chunk = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
            self._all_chunks.append(chunk)

    def start(self):
        """Start the phone pipeline thread. No-op if already running."""
        with self._lock:
            if self._running:
                return
            self._stop_event.clear()
            self._all_chunks = []
            self._thread = threading.Thread(target=self._run, daemon=True)
            self._thread.start()
            self._running = True

    def stop(self):
        """Signal stop and wait for final transcription to complete."""
        with self._lock:
            if not self._running:
                return
            self._stop_event.set()
            self._running = False
            thread = self._thread
            self._thread = None
        if thread and thread.is_alive():
            thread.join(timeout=15.0)   # allow time for final Whisper pass

    def _run(self):
        from speech_detector import _prepare_audio

        partial_text   = ""
        partial_cursor = 0
        dots_shown     = 0
        partial_stop   = threading.Event()
        cps            = self.CHUNKS_PER_SEC

        def worker():
            nonlocal partial_text, partial_cursor, dots_shown

            while not partial_stop.wait(self.PARTIAL_INTERVAL):
                try:
                    snapshot = list(self._all_chunks)
                    total    = len(snapshot)

                    # Trailing silence
                    trailing_silent = 0
                    for c in reversed(snapshot):
                        if np.max(np.abs(c)) < cfg.silence_threshold:
                            trailing_silent += 1
                        else:
                            break
                    silent_secs = trailing_silent / cps

                    # Pause branch
                    if silent_secs >= self.MIN_PAUSE_SECS and partial_text:
                        total_dot_secs = int(silent_secs)
                        new_dots = total_dot_secs - dots_shown
                        if new_dots > 0:
                            partial_text = partial_text.rstrip() + ("." * new_dots)
                            dots_shown   = total_dot_secs
                            keep = int(self.SILENCE_TAIL_SECS * cps)
                            partial_cursor = max(partial_cursor, total - keep)
                            event_bus.publish({
                                "type": "partial",
                                "raw": partial_text,
                                "formatted": partial_text,
                                "mode": pipeline.mode,
                                "timestamp": time.time(),
                            })
                        continue

                    dots_shown = 0
                    new_chunks = snapshot[partial_cursor:total]
                    if len(new_chunks) < self.MIN_CHUNKS_FOR_PARTIAL:
                        continue

                    audio = np.concatenate(new_chunks).astype(np.float32)
                    text  = transcribe_partial(audio)
                    if text:
                        partial_cursor = total
                        partial_text   = (partial_text + " " + text).strip()
                        event_bus.publish({
                            "type": "partial",
                            "raw": partial_text,
                            "formatted": partial_text,
                            "mode": pipeline.mode,
                            "timestamp": time.time(),
                        })

                except Exception as e:
                    print(f"[PhonePartialWorker] {e}")

        t = threading.Thread(target=worker, daemon=True)
        t.start()

        # Announce recording started
        event_bus.publish({
            "type": "status",
            "status": "started",
            "source": "phone",
            "mode": pipeline.mode,
        })

        # Block until stop() signals — audio arrives via push_audio()
        self._stop_event.wait()

        # Stop partial worker
        partial_stop.set()
        t.join(timeout=10.0)

        # Final high-quality pass over all accumulated phone audio
        all_chunks = list(self._all_chunks)
        if all_chunks:
            try:
                audio = np.concatenate(all_chunks).astype(np.float32)
                max_val = np.max(np.abs(audio))
                if max_val > 0:
                    audio = audio / max_val
                audio = audio * cfg.signal_boost
                text  = transcribe(audio)
                if text:
                    # Persist WAV for this phone recording
                    session_mgr.save_audio(audio, source="phone")
                    pipeline.set_session_text(text)
                    event_bus.publish({
                        "type": "final",
                        "raw": text,
                        "formatted": text,
                        "mode": pipeline.mode,
                        "timestamp": time.time(),
                    })
            except Exception as e:
                event_bus.publish({"type": "error", "message": f"Phone transcription failed: {e}"})

        with self._lock:
            self._running = False
        event_bus.publish({"type": "status", "status": "stopped"})


phone_pipeline = PhoneAudioPipeline()


def _is_duplicate_partial(new_text: str, old_text: str) -> bool:
    """
    Diff-based partial dedup.

    Returns True if the new partial is too similar to the old one
    to be worth sending to clients. Prevents near-identical updates
    like "I see" → "I see " → "I see i" that spam the WebSocket.

    A partial is considered duplicate if:
      - It's identical to the previous partial
      - It starts with the old text and only adds < 4 characters

    NOTE: We deliberately do NOT suppress regressions (shorter re-transcriptions).
    Suppressing them caused the partial to freeze at the first word Whisper caught.
    """
    if not old_text:
        return False

    new_stripped = new_text.strip()
    old_stripped = old_text.strip()

    # Identical
    if new_stripped == old_stripped:
        return True

    # New text is just old text + tiny addition (< 4 chars of new content)
    if new_stripped.startswith(old_stripped):
        added = new_stripped[len(old_stripped):].strip()
        if len(added) < 4:
            return True

    return False


# ==============================================================================
# FASTAPI APP
# ==============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown lifecycle."""
    print("🚀 VoiceForge API server starting...")
    yield
    print("🛑 Shutting down pipelines...")
    pipeline.stop()
    phone_pipeline.stop()


app = FastAPI(
    title="VoiceForge API",
    description="Real-time voice transcription backend for Flutter UI",
    version="1.0.0",
    lifespan=lifespan,
)

# Allow Flutter to connect from any origin during development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- Request/Response models ---

class ModeRequest(BaseModel):
    mode: str


class TransformRequest(BaseModel):
    text: str
    mode: str = "clean"


class TranscribeResponse(BaseModel):
    raw: str
    clean: str
    mode: str


class StatusResponse(BaseModel):
    status: str
    pipeline_running: bool
    current_mode: str
    connected_clients: int
    available_modes: list[str]
    config: dict


# ==============================================================================
# ENDPOINTS
# ==============================================================================

@app.get("/")
async def health_check():
    """Health check + current status."""
    return {
        "status": "ok",
        "pipeline_running": pipeline.is_running or phone_pipeline.is_running,
        "current_mode": pipeline.mode,
        "connected_clients": event_bus.subscriber_count,
        "available_modes": Formatter.available_modes(),
        "current_session": session_mgr.current_session_id,
        "sessions_dir": str(session_mgr.sessions_dir),
    }


@app.get("/config")
async def get_config():
    """Return current configuration as JSON."""
    return asdict(cfg)


@app.post("/mode")
async def set_mode(req: ModeRequest):
    """Switch formatting mode dynamically."""
    try:
        pipeline.set_mode(req.mode)
        return {"status": "ok", "mode": req.mode}
    except ValueError as e:
        return JSONResponse(status_code=400, content={"error": str(e)})


@app.post("/stream/start")
async def start_stream():
    """Start the live mic → transcription pipeline."""
    if pipeline.is_running:
        return {"status": "already_running"}

    pipeline.start()
    return {"status": "started", "mode": pipeline.mode}


@app.post("/stream/stop")
async def stop_stream():
    """Stop the live pipeline."""
    if not pipeline.is_running:
        return {"status": "already_stopped"}

    pipeline.stop()
    return {"status": "stopped"}


# ---------------------------------------------------------------------------
# Device selection
# ---------------------------------------------------------------------------

class MicSelectRequest(BaseModel):
    device_id: int


@app.get("/devices/microphones")
async def list_microphones():
    """Return all available WASAPI microphones."""
    from audio_capture import list_microphones as _list_mics
    return _list_mics()


@app.post("/devices/microphone")
async def select_microphone(req: MicSelectRequest):
    """Select a microphone by index. Takes effect on next recording start."""
    from audio_capture import set_microphone
    try:
        result = set_microphone(req.device_id)
        return {"status": "ok", **result}
    except ValueError as e:
        return JSONResponse(status_code=400, content={"error": str(e)})


@app.get("/devices/microphone")
async def get_current_microphone():
    """Return the currently selected microphone, or null."""
    from audio_capture import get_selected_microphone_info
    info = get_selected_microphone_info()
    if info is None:
        return {"name": None, "status": "auto"}
    return {"status": "manual", **info}


@app.post("/transform")
async def transform_text(req: TransformRequest):
    """
    Transform raw text using the specified formatting mode.
    Saves the output to the active session folder and broadcasts
    the result to all connected WebSocket clients so every device
    shows the same formatted panel immediately.
    """
    try:
        fmt = Formatter(mode=req.mode)
        formatted = fmt.format(req.text)
        # Persist formatted output so reconnecting clients can restore it.
        pipeline.set_formatted_output(req.mode, formatted)
        # Persist every formatted output to the session archive
        session_mgr.save_formatted(req.mode, formatted)
        # Broadcast so desktop/phone both update their formatted panel
        event_bus.publish({
            "type": "formatted",
            "formatted": formatted,
            "mode": req.mode,
            "timestamp": time.time(),
        })
        return {
            "raw": req.text,
            "formatted": formatted,
            "mode": req.mode,
        }
    except ValueError as e:
        return JSONResponse(status_code=400, content={"error": str(e)})
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/session")
async def get_session():
    """Get the accumulated raw session text from the pipeline."""
    return {
        "text": pipeline.session_text,
        "paragraphs": pipeline.paragraphs,
        "mode": pipeline.mode,
        "pipeline_running": pipeline.is_running,
    }


@app.post("/session/clear")
async def clear_session_http():
    """Clear accumulated session text (HTTP fallback; WS clear also finalizes session)."""
    session_mgr.finalize(pipeline.session_text)
    pipeline.clear_session()
    return {"status": "cleared"}


# ==============================================================================
# SESSION BROWSE API — read-only access to saved session archive
# ==============================================================================

@app.get("/sessions")
async def list_sessions_api():
    """List all saved sessions, newest first."""
    return {"sessions": session_mgr.list_sessions()}


@app.get("/sessions/open-folder")
async def open_sessions_folder():
    """Open the sessions folder in the OS file explorer (PC-side action)."""
    import os
    import subprocess
    import sys
    path = str(session_mgr.sessions_dir)
    try:
        if sys.platform == "win32":
            os.startfile(path)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])
        return {"status": "ok", "path": path}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/sessions/{session_id}")
async def get_session_api(session_id: str):
    """Get metadata and file list for a specific session."""
    detail = session_mgr.get_session_detail(session_id)
    if detail is None:
        return JSONResponse(status_code=404, content={"error": "Session not found"})
    return detail


@app.get("/sessions/{session_id}/raw")
async def get_session_raw(session_id: str):
    """Return raw.txt content for a session."""
    from fastapi.responses import PlainTextResponse
    p = session_mgr.get_raw_path(session_id)
    if p is None:
        return JSONResponse(status_code=404, content={"error": "raw.txt not found"})
    return PlainTextResponse(p.read_text(encoding="utf-8"))


@app.get("/sessions/{session_id}/formatted/{filename}")
async def get_formatted_file(session_id: str, filename: str):
    """Return a specific formatted output file."""
    from fastapi.responses import FileResponse
    p = session_mgr.get_file_path(session_id, "formatted", filename)
    if p is None:
        return JSONResponse(status_code=404, content={"error": "File not found"})
    return FileResponse(str(p), media_type="text/plain")


@app.get("/sessions/{session_id}/audio/{filename}")
async def get_audio_file(session_id: str, filename: str):
    """Return a specific audio WAV file."""
    from fastapi.responses import FileResponse
    p = session_mgr.get_file_path(session_id, "audio", filename)
    if p is None:
        return JSONResponse(status_code=404, content={"error": "File not found"})
    return FileResponse(str(p), media_type="audio/wav")


@app.post("/transcribe")
async def transcribe_file(file: UploadFile = File(...)):
    """
    One-shot transcription: upload an audio file, get back JSON.

    Accepts: WAV, MP3, MP4, M4A, OGG, FLAC, WEBM, OPUS, AAC
    Automatically converts to 16kHz mono WAV via ffmpeg if needed.

    Returns:
        {
            "raw": "original transcription",
            "clean": "formatted transcription",
            "mode": "current mode"
        }
    """
    import tempfile
    import subprocess
    import pathlib

    audio_bytes = await file.read()
    filename = file.filename or "upload.wav"
    ext = pathlib.Path(filename).suffix.lower()

    # ── Convert non-WAV formats via ffmpeg ────────────────────────────────────
    wav_bytes = None
    if ext != ".wav":
        try:
            with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp_in:
                tmp_in.write(audio_bytes)
                tmp_in_path = tmp_in.name
            tmp_out_path = tmp_in_path + ".wav"
            result = subprocess.run(
                [
                    "ffmpeg", "-y", "-i", tmp_in_path,
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                    tmp_out_path,
                ],
                capture_output=True,
                timeout=120,
            )
            if result.returncode != 0:
                return JSONResponse(
                    status_code=400,
                    content={"error": f"ffmpeg conversion failed: {result.stderr.decode(errors='replace')}"},
                )
            with open(tmp_out_path, "rb") as f_out:
                wav_bytes = f_out.read()
        except FileNotFoundError:
            return JSONResponse(
                status_code=400,
                content={"error": f"ffmpeg not found. Only WAV files are supported without ffmpeg installed. Got: {ext}"},
            )
        except subprocess.TimeoutExpired:
            return JSONResponse(status_code=408, content={"error": "ffmpeg conversion timed out"})
        except Exception as e:
            return JSONResponse(status_code=500, content={"error": f"Conversion error: {e}"})
        finally:
            for p in [tmp_in_path, tmp_out_path]:
                try:
                    import os as _os; _os.unlink(p)
                except Exception:
                    pass
    else:
        wav_bytes = audio_bytes

    # ── Parse WAV and transcribe ───────────────────────────────────────────────
    try:
        with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
            n_channels = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            framerate = wf.getframerate()
            frames = wf.readframes(wf.getnframes())

        if sampwidth == 2:
            audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        elif sampwidth == 4:
            audio = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            return JSONResponse(
                status_code=400,
                content={"error": f"Unsupported sample width: {sampwidth} bytes"},
            )

        if n_channels == 2:
            audio = audio.reshape(-1, 2).mean(axis=1)

        if framerate != cfg.target_sample_rate:
            num_samples = int(len(audio) * cfg.target_sample_rate / framerate)
            audio = resample(audio, num_samples).astype(np.float32)

        max_val = np.max(np.abs(audio))
        if max_val > 0:
            audio = audio / max_val
        audio = audio * cfg.signal_boost

        raw_text = transcribe(audio)
        if not raw_text:
            return {"raw": "", "clean": "", "mode": pipeline.mode}

        fmt = Formatter(mode=pipeline.mode)
        formatted_text = fmt.format(raw_text)

        return {
            "raw": raw_text,
            "clean": formatted_text,
            "mode": pipeline.mode,
        }

    except wave.Error as e:
        return JSONResponse(status_code=400, content={"error": f"Invalid WAV file: {e}"})
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.websocket("/stream")
async def websocket_stream(websocket: WebSocket):
    """
    WebSocket endpoint for real-time transcription streaming.

    Handles two client types:
      - Desktop: sends start/stop commands, receives events
      - Mobile:  also sends binary PCM frames when phone mic is recording

    Events sent to client (JSON):
        {"type": "partial",     "raw": "...", "timestamp": ...}
        {"type": "final",       "raw": "...", "timestamp": ...}
        {"type": "status",      "status": "started"|"stopped"|"connected"|"cleared", ...}
        {"type": "text_update", "raw": "..."}  — another client edited the raw text
        {"type": "ping"}        — keepalive
        {"type": "error",       "message": "..."}

    Commands from client (JSON):
        {"command": "start",       "source": "wasapi"|"phone"}  — source defaults to wasapi
        {"command": "stop"}
        {"command": "set_mode",    "mode": "clean"}
        {"command": "text_update", "text": "..."}  — raw panel edit, broadcast to others
        {"command": "clear"}       — clear session, broadcast to all

    Binary frames (bytes):
        Raw int16 PCM audio from phone mic @ 16kHz mono
    """
    await websocket.accept()

    sub_id, queue = event_bus.subscribe()
    print(f"WebSocket client connected (id={sub_id}, total={event_bus.subscriber_count})")

    # Send handshake — Flutter waits for this before marking connected.
    # Include current session_text AND formatted_output so any reconnecting
    # client (desktop joining an active mobile session, or vice versa)
    # immediately restores both panels without needing to re-run a transform.
    await websocket.send_json({
        "type": "status",
        "status": "connected",
        "pipeline_running": pipeline.is_running or phone_pipeline.is_running,
        "current_mode": pipeline.mode,
        "available_modes": Formatter.available_modes(),
        "session_text": pipeline.session_text,
        "formatted_output": pipeline.formatted_output,
        "formatted_mode":   pipeline.formatted_mode,
    })

    async def send_events():
        """Forward events from the bus to the WebSocket client."""
        try:
            while True:
                event = await queue.get()
                await websocket.send_json(event)
        except (WebSocketDisconnect, RuntimeError):
            pass

    async def receive_commands():
        """
        Handle incoming messages — either JSON commands or binary PCM frames.
        Binary frames are PCM audio from the phone mic.
        """
        loop = asyncio.get_event_loop()
        try:
            while True:
                try:
                    raw = await websocket.receive()
                except WebSocketDisconnect:
                    # If phone disconnects mid-recording, stop it cleanly
                    if phone_pipeline.is_running:
                        await loop.run_in_executor(None, phone_pipeline.stop)
                    return
                except Exception:
                    continue

                # ── Binary frame → phone PCM audio ────────────────────────
                if raw.get("bytes"):
                    phone_pipeline.push_audio(raw["bytes"])
                    continue

                # ── Text frame → JSON command ──────────────────────────────
                text = raw.get("text")
                if not text:
                    continue
                try:
                    data = json.loads(text)
                except Exception:
                    continue

                command = data.get("command")

                if command == "text_update":
                    # Another client edited the raw panel — sync to session
                    # and broadcast to everyone else (not the sender).
                    new_text = data.get("text", "")
                    pipeline.set_session_text(new_text)
                    event_bus.publish_except({
                        "type": "text_update",
                        "raw": new_text,
                    }, exclude_id=sub_id)

                elif command == "formatted_update":
                    # A client manually edited the formatted panel —
                    # broadcast to all OTHER clients so they mirror it.
                    fmt_text = data.get("text", "")
                    fmt_mode = data.get("mode", "clean")
                    event_bus.publish_except({
                        "type": "formatted",
                        "formatted": fmt_text,
                        "mode": fmt_mode,
                        "timestamp": time.time(),
                    }, exclude_id=sub_id)

                elif command == "clear":
                    # Finalize the session (saves raw.txt, renames if low-content)
                    session_mgr.finalize(pipeline.session_text)
                    pipeline.clear_session()
                    event_bus.publish({
                        "type": "status",
                        "status": "cleared",
                    })

                elif command == "set_mode":
                    mode = data.get("mode", "clean")
                    try:
                        pipeline.set_mode(mode)
                        await websocket.send_json({
                            "type": "status",
                            "status": "mode_changed",
                            "mode": mode,
                        })
                    except ValueError as e:
                        await websocket.send_json({
                            "type": "error",
                            "message": str(e),
                        })

                elif command == "start":
                    source = data.get("source", "wasapi")
                    if source == "phone":
                        if pipeline.is_running:
                            await websocket.send_json({
                                "type": "error",
                                "message": "PC mic is already recording",
                            })
                        elif phone_pipeline.is_running:
                            await websocket.send_json({
                                "type": "error",
                                "message": "Phone recording already in progress",
                            })
                        else:
                            phone_pipeline.start()
                            # status: started is published by phone_pipeline._run
                    else:  # wasapi (desktop)
                        if phone_pipeline.is_running:
                            await websocket.send_json({
                                "type": "error",
                                "message": "Phone mic is already recording",
                            })
                        elif not pipeline.is_running:
                            pipeline.start()
                            await websocket.send_json({
                                "type": "status",
                                "status": "started",
                            })

                elif command == "stop":
                    if phone_pipeline.is_running:
                        # Run in executor — final Whisper pass can take seconds
                        await loop.run_in_executor(None, phone_pipeline.stop)
                    elif pipeline.is_running:
                        await loop.run_in_executor(None, pipeline.stop)
                        await websocket.send_json({
                            "type": "status",
                            "status": "stopped",
                        })

        except (WebSocketDisconnect, RuntimeError):
            pass

    async def keepalive():
        """Send a ping every 20s to prevent idle connection drops."""
        try:
            while True:
                await asyncio.sleep(20)
                await websocket.send_json({"type": "ping"})
        except Exception:
            pass

    send_task      = asyncio.create_task(send_events())
    recv_task      = asyncio.create_task(receive_commands())
    keepalive_task = asyncio.create_task(keepalive())

    try:
        done, pending = await asyncio.wait(
            [send_task, recv_task, keepalive_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
    except Exception:
        pass
    finally:
        event_bus.unsubscribe(sub_id)
        print(f"WebSocket client disconnected (id={sub_id}, remaining={event_bus.subscriber_count})")


# ==============================================================================
# RUN (HARDENED STARTUP)
# ==============================================================================

if __name__ == "__main__":
    import uvicorn
    import argparse
    import socket
    import sys

    try:
        import requests
    except ImportError:
        print("⚠️ 'requests' not installed. Install with: pip install requests")
        sys.exit(1)

    def is_backend_running(port):
        try:
            r = requests.get(f"http://localhost:{port}", timeout=0.5)
            return r.status_code == 200
        except:
            return False

    def find_available_port(start_port=8000, max_tries=4):
        for i in range(max_tries):
            port = start_port + i

            # If backend already running → exit clean
            if is_backend_running(port):
                print(f"⚠️ Backend already running on port {port}, skipping startup")
                return None

            # Check if port is free
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                try:
                    s.bind(("0.0.0.0", port))
                    return port
                except OSError:
                    print(f"⚠️ Port {port} in use, trying next...")
                    continue

        raise RuntimeError("❌ No available ports (8000–8003)")

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()

    selected_port = find_available_port(args.port)

    if selected_port is None:
        print("🛑 Startup skipped (already running)")
        sys.exit(0)

    print("\n" + cfg.summary() + "\n")
    print(f"🚀 Starting VoiceForge backend on port {selected_port}")

    uvicorn.run(app, host="0.0.0.0", port=selected_port)