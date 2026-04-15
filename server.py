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

import asyncio
import io
import json
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
        """Pipeline loop — captures raw speech, NO formatting."""
        from audio_capture import audio_stream, get_native_sample_rate
        from speech_detector import extract_speech_segments

        last_partial_text = ""

        try:
            native_sr = get_native_sample_rate()

            event_bus.publish({
                "type": "status",
                "status": "started",
                "sample_rate": native_sr,
                "mode": self._mode,
            })

            chunks = audio_stream(sample_rate=native_sr)
            events = extract_speech_segments(chunks, native_sr)

            for event_type, audio_segment in events:
                if self._stop_event.is_set():
                    break

                if event_type == "paragraph_break":
                    # Long pause — start a new paragraph
                    with self._lock:
                        if self._paragraphs and self._paragraphs[-1]:
                            self._paragraphs.append("")
                    event_bus.publish({
                        "type": "paragraph_break",
                        "timestamp": time.time(),
                    })

                elif event_type == "partial":
                    text = transcribe_partial(audio_segment)
                    if text and not _is_duplicate_partial(text, last_partial_text):
                        last_partial_text = text
                        event_bus.publish({
                            "type": "partial",
                            "raw": text,
                            "formatted": text,
                            "mode": self._mode,
                            "timestamp": time.time(),
                        })

                elif event_type == "final":
                    last_partial_text = ""
                    text = transcribe(audio_segment)
                    if text:
                        # Append to current paragraph
                        with self._lock:
                            if not self._paragraphs:
                                self._paragraphs.append(text)
                            else:
                                current = self._paragraphs[-1]
                                self._paragraphs[-1] = (
                                    f"{current} {text}" if current else text
                                )

                        event_bus.publish({
                            "type": "final",
                            "raw": text,
                            "formatted": text,
                            "mode": self._mode,
                            "timestamp": time.time(),
                        })

        except Exception as e:
            event_bus.publish({
                "type": "error",
                "message": str(e),
            })
        finally:
            with self._lock:
                self._running = False
            event_bus.publish({
                "type": "status",
                "status": "stopped",
            })


pipeline = PipelineManager()


def _is_duplicate_partial(new_text: str, old_text: str) -> bool:
    """
    Diff-based partial dedup.

    Returns True if the new partial is too similar to the old one
    to be worth sending to clients. Prevents near-identical updates
    like "I see" → "I see " → "I see i" that spam the WebSocket.

    A partial is considered duplicate if:
      - It's identical to the previous partial
      - It starts with the old text and only adds < 4 characters
      - The old text starts with it (regression / truncation)
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

    # Regression: new text is a subset of old (model re-transcribed shorter)
    if old_stripped.startswith(new_stripped):
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
    print("🛑 Shutting down pipeline...")
    pipeline.stop()


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
        "pipeline_running": pipeline.is_running,
        "current_mode": pipeline.mode,
        "connected_clients": event_bus.subscriber_count,
        "available_modes": Formatter.available_modes(),
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


@app.post("/transform")
async def transform_text(req: TransformRequest):
    """
    Transform raw text using the specified formatting mode.

    This is the "Transform Later" half of the architecture.
    Call this after capturing raw speech to format it on demand.

    Returns:
        {"raw": "original text", "formatted": "transformed text", "mode": "mode used"}
    """
    try:
        fmt = Formatter(mode=req.mode)
        formatted = fmt.format(req.text)
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
async def clear_session():
    """Clear the accumulated session text."""
    pipeline.clear_session()
    return {"status": "cleared"}


@app.post("/transcribe")
async def transcribe_file(file: UploadFile = File(...)):
    """
    One-shot transcription: upload an audio file, get back JSON.

    Accepts WAV files (16kHz mono preferred, will resample if needed).

    Returns:
        {
            "raw": "original transcription",
            "clean": "formatted transcription",
            "mode": "current mode"
        }
    """
    try:
        audio_bytes = await file.read()

        # Parse WAV
        with wave.open(io.BytesIO(audio_bytes), "rb") as wf:
            n_channels = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            framerate = wf.getframerate()
            frames = wf.readframes(wf.getnframes())

        # Convert to float32 numpy array
        if sampwidth == 2:
            audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        elif sampwidth == 4:
            audio = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            return JSONResponse(
                status_code=400,
                content={"error": f"Unsupported sample width: {sampwidth} bytes"},
            )

        # Convert stereo to mono
        if n_channels == 2:
            audio = audio.reshape(-1, 2).mean(axis=1)

        # Resample to 16kHz if needed
        if framerate != cfg.target_sample_rate:
            num_samples = int(len(audio) * cfg.target_sample_rate / framerate)
            audio = resample(audio, num_samples).astype(np.float32)

        # Normalize + boost
        max_val = np.max(np.abs(audio))
        if max_val > 0:
            audio = audio / max_val
        audio = audio * cfg.signal_boost

        # Transcribe
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

    Flutter connects here to receive live events.

    Events sent to client (JSON):
        {"type": "partial",  "raw": "...", "formatted": "...", "mode": "...", "timestamp": ...}
        {"type": "final",    "raw": "...", "formatted": "...", "mode": "...", "timestamp": ...}
        {"type": "status",   "status": "started"|"stopped", ...}
        {"type": "error",    "message": "..."}

    Client can send commands (JSON):
        {"command": "set_mode", "mode": "dev"}
        {"command": "start"}
        {"command": "stop"}
    """
    await websocket.accept()

    sub_id, queue = event_bus.subscribe()
    print(f"🔌 WebSocket client connected (id={sub_id}, total={event_bus.subscriber_count})")

    # Send initial status
    await websocket.send_json({
        "type": "status",
        "status": "connected",
        "pipeline_running": pipeline.is_running,
        "current_mode": pipeline.mode,
        "available_modes": Formatter.available_modes(),
    })

    async def send_events():
        """Forward events from the bus to the WebSocket client."""
        try:
            while True:
                event = await queue.get()
                await websocket.send_json(event)
        except (WebSocketDisconnect, RuntimeError, Exception):
            pass

    async def receive_commands():
        """Listen for client commands."""
        try:
            while True:
                data = await websocket.receive_json()
                command = data.get("command")

                if command == "set_mode":
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
                    pipeline.start()
                    await websocket.send_json({
                        "type": "status",
                        "status": "started",
                    })

                elif command == "stop":
                    pipeline.stop()
                    await websocket.send_json({
                        "type": "status",
                        "status": "stopped",
                    })

        except (WebSocketDisconnect, RuntimeError, Exception):
            pass

    # Run both concurrently — when one exits (disconnect), cancel the other
    send_task = asyncio.create_task(send_events())
    recv_task = asyncio.create_task(receive_commands())

    try:
        done, pending = await asyncio.wait(
            [send_task, recv_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
    except Exception:
        pass
    finally:
        event_bus.unsubscribe(sub_id)
        print(f"🔌 WebSocket client disconnected (id={sub_id}, remaining={event_bus.subscriber_count})")


# ==============================================================================
# RUN
# ==============================================================================

if __name__ == "__main__":
    import uvicorn

    print("\n" + cfg.summary() + "\n")
    uvicorn.run(app, host="0.0.0.0", port=8000)
