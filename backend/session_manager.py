"""
session_manager.py — VoiceForge session persistence layer.

Each session creates a folder:
  ~/Documents/VoiceForge/sessions/YYYY-MM-DD_Snnn_HHMM/
    session.json          metadata
    raw.txt               final raw transcript (saved on clear)
    audio/
      rec_001_wasapi.wav
      rec_002_phone.wav
    formatted/
      clean_001.txt
      bullet_001.txt
      ...

Low-content sessions (< 30 words AND 0 formatted outputs) are renamed
with a _low_ prefix so they stand out in the folder.
"""

import json
import threading
import wave
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np

LOW_WORD_THRESHOLD = 30  # words below this + 0 formatted = low-content


class SessionManager:
    """Thread-safe manager for VoiceForge session folders."""

    def __init__(self, sessions_dir: Optional[Path] = None):
        if sessions_dir is None:
            sessions_dir = Path.home() / "Documents" / "VoiceForge" / "sessions"
        self._base = Path(sessions_dir)
        self._base.mkdir(parents=True, exist_ok=True)

        self._lock = threading.Lock()
        self._session_dir: Optional[Path] = None
        self._session_id: Optional[str] = None
        self._audio_count: int = 0
        self._formatted_counts: dict[str, int] = {}
        self._total_formatted: int = 0
        self._started: Optional[datetime] = None

    # ── Properties ────────────────────────────────────────────────────────────

    @property
    def sessions_dir(self) -> Path:
        return self._base

    @property
    def current_session_id(self) -> Optional[str]:
        with self._lock:
            return self._session_id

    # ── Internal ──────────────────────────────────────────────────────────────

    def _ensure_session(self) -> Path:
        """Return active session dir, opening a new one if needed."""
        with self._lock:
            if self._session_dir is None:
                self._open_session()
            return self._session_dir  # type: ignore[return-value]

    def _open_session(self):
        """Create a new session folder. Must be called with lock held."""
        now = datetime.now()
        date_str = now.strftime("%Y-%m-%d")
        hhmm = now.strftime("%H%M")

        # Next sequential number for today
        prefix = date_str
        existing = [d for d in self._base.iterdir() if d.is_dir() and prefix in d.name]
        num = len(existing) + 1

        sid = f"{date_str}_S{num:03d}_{hhmm}"
        sdir = self._base / sid
        sdir.mkdir(parents=True, exist_ok=True)
        (sdir / "audio").mkdir(exist_ok=True)
        (sdir / "formatted").mkdir(exist_ok=True)

        self._session_dir = sdir
        self._session_id = sid
        self._audio_count = 0
        self._formatted_counts = {}
        self._total_formatted = 0
        self._started = now

        self._write_meta_locked(finalized=False, word_count=0)
        print(f"[Session] Opened: {sid}")

    def _write_meta_locked(self, finalized: bool, word_count: int):
        """Write session.json. Must be called with lock held."""
        if self._session_dir is None:
            return
        is_low = word_count < LOW_WORD_THRESHOLD and self._total_formatted == 0
        meta = {
            "session_id": self._session_id,
            "started": self._started.isoformat() if self._started else None,
            "finalized": datetime.now().isoformat() if finalized else None,
            "audio_recordings": self._audio_count,
            "formatted_outputs": self._total_formatted,
            "formatted_modes": dict(self._formatted_counts),
            "raw_word_count": word_count,
            "low_content": is_low,
        }
        (self._session_dir / "session.json").write_text(
            json.dumps(meta, indent=2), encoding="utf-8"
        )

    # ── Public API ────────────────────────────────────────────────────────────

    def save_audio(
        self,
        audio: np.ndarray,
        source: str = "wasapi",
        sample_rate: int = 16000,
    ) -> Optional[Path]:
        """
        Save a float32 numpy array as a 16-bit mono WAV file.

        Args:
            audio:       1-D float32 array, values in roughly [-1, 1].
            source:      'wasapi' or 'phone' — appears in filename.
            sample_rate: sample rate in Hz (default 16000).

        Returns:
            Path to saved WAV, or None on failure.
        """
        if audio is None or len(audio) == 0:
            return None

        session_dir = self._ensure_session()
        with self._lock:
            self._audio_count += 1
            count = self._audio_count

        filename = f"rec_{count:03d}_{source}.wav"
        out_path = session_dir / "audio" / filename

        try:
            peak = float(np.max(np.abs(audio)))
            audio_int16 = (
                (audio / peak * 32767).astype(np.int16)
                if peak > 0
                else audio.astype(np.int16)
            )
            with wave.open(str(out_path), "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(sample_rate)
                wf.writeframes(audio_int16.tobytes())
            duration = len(audio) / sample_rate
            print(f"[Session] Audio saved: {filename} ({duration:.1f}s)")
            return out_path
        except Exception as exc:
            print(f"[Session] Audio save failed: {exc}")
            return None

    def save_formatted(self, mode: str, text: str) -> Optional[Path]:
        """
        Save a formatted output to formatted/{mode}_NNN.txt.

        Returns the saved path, or None if text is empty or save fails.
        """
        if not text or not text.strip():
            return None

        session_dir = self._ensure_session()
        with self._lock:
            self._formatted_counts[mode] = self._formatted_counts.get(mode, 0) + 1
            count = self._formatted_counts[mode]
            self._total_formatted += 1

        filename = f"{mode}_{count:03d}.txt"
        out_path = session_dir / "formatted" / filename
        try:
            out_path.write_text(text, encoding="utf-8")
            print(f"[Session] Formatted saved: {filename}")
            return out_path
        except Exception as exc:
            print(f"[Session] Formatted save failed: {exc}")
            return None

    def finalize(self, raw_text: str = "") -> Optional[str]:
        """
        Close the active session: write raw.txt, update session.json,
        optionally rename to _low_ prefix for sparse sessions.

        Returns the final session_id, or None if no session was open.
        """
        with self._lock:
            if self._session_dir is None:
                return None

            sdir = self._session_dir
            sid = self._session_id

            # Save raw transcript
            stripped = raw_text.strip()
            if stripped:
                (sdir / "raw.txt").write_text(raw_text, encoding="utf-8")

            word_count = len(stripped.split()) if stripped else 0
            is_low = word_count < LOW_WORD_THRESHOLD and self._total_formatted == 0

            meta = {
                "session_id": sid,
                "started": self._started.isoformat() if self._started else None,
                "finalized": datetime.now().isoformat(),
                "audio_recordings": self._audio_count,
                "formatted_outputs": self._total_formatted,
                "formatted_modes": dict(self._formatted_counts),
                "raw_word_count": word_count,
                "low_content": is_low,
            }
            (sdir / "session.json").write_text(
                json.dumps(meta, indent=2), encoding="utf-8"
            )

            # Rename to _low_ if sparse
            if is_low:
                new_dir = sdir.parent / f"_low_{sdir.name}"
                try:
                    sdir.rename(new_dir)
                    sid = f"_low_{sid}"
                    print(f"[Session] Flagged low-content: {sid}")
                except Exception as exc:
                    print(f"[Session] Could not rename to _low_: {exc}")

            print(
                f"[Session] Finalized: {sid} | "
                f"words={word_count} formatted={self._total_formatted} low={is_low}"
            )

            # Reset state
            self._session_dir = None
            self._session_id = None
            self._audio_count = 0
            self._formatted_counts = {}
            self._total_formatted = 0
            self._started = None

            return sid

    # ── Browse API helpers ────────────────────────────────────────────────────

    def list_sessions(self) -> list[dict]:
        """Return all sessions sorted newest-first."""
        results = []
        try:
            dirs = sorted(self._base.iterdir(), key=lambda d: d.name, reverse=True)
        except Exception:
            return []
        for d in dirs:
            if not d.is_dir():
                continue
            meta_path = d / "session.json"
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text(encoding="utf-8"))
                    meta["folder"] = d.name
                    results.append(meta)
                except Exception:
                    results.append({"folder": d.name, "session_id": d.name})
            else:
                results.append({"folder": d.name, "session_id": d.name})
        return results

    def get_session_detail(self, session_id: str) -> Optional[dict]:
        """Return metadata + file lists for a session."""
        d = self._find_dir(session_id)
        if d is None:
            return None
        meta: dict = {}
        mp = d / "session.json"
        if mp.exists():
            try:
                meta = json.loads(mp.read_text(encoding="utf-8"))
            except Exception:
                pass
        meta["folder"] = d.name
        meta["has_raw"] = (d / "raw.txt").exists()
        meta["audio_files"] = (
            sorted(f.name for f in (d / "audio").iterdir())
            if (d / "audio").exists() else []
        )
        meta["formatted_files"] = (
            sorted(f.name for f in (d / "formatted").iterdir())
            if (d / "formatted").exists() else []
        )
        return meta

    def get_file_path(self, session_id: str, sub: str, filename: str) -> Optional[Path]:
        d = self._find_dir(session_id)
        if d is None:
            return None
        p = d / sub / filename
        return p if p.exists() else None

    def get_raw_path(self, session_id: str) -> Optional[Path]:
        d = self._find_dir(session_id)
        if d is None:
            return None
        p = d / "raw.txt"
        return p if p.exists() else None

    def _find_dir(self, session_id: str) -> Optional[Path]:
        exact = self._base / session_id
        if exact.exists():
            return exact
        try:
            for d in self._base.iterdir():
                if d.is_dir() and (d.name == session_id or d.name.endswith(session_id)):
                    return d
        except Exception:
            pass
        return None


# Module-level singleton — imported by server.py
session_mgr = SessionManager()
