"""
test_sessions.py — VoiceForge session persistence verification.

Simulates 2 full sessions with mock audio, text edits, and multiple
formatted outputs. Verifies folder structure at each step.

Run from the backend directory with the venv:
    python test_sessions.py
"""

import json
import sys
import time
import wave
from pathlib import Path

import numpy as np

# Ensure backend is importable
sys.path.insert(0, str(Path(__file__).parent))

from session_manager import SessionManager

PASS = "PASS"
FAIL = "FAIL"
_failures = []


def check(label: str, condition: bool):
    if condition:
        print(f"  [PASS]  {label}")
    else:
        print(f"  [FAIL]  {label}")
        _failures.append(label)


def make_audio(duration_secs: float = 2.0, sr: int = 16000) -> np.ndarray:
    """Generate a 440 Hz sine wave for testing."""
    t = np.linspace(0, duration_secs, int(sr * duration_secs), endpoint=False)
    return (np.sin(2 * np.pi * 440 * t) * 0.5).astype(np.float32)


def verify_wav(path: Path, expected_sr: int = 16000) -> bool:
    """Verify a WAV file is valid and at the expected sample rate."""
    try:
        with wave.open(str(path), "rb") as wf:
            assert wf.getnchannels() == 1, "not mono"
            assert wf.getsampwidth() == 2, "not int16"
            assert wf.getframerate() == expected_sr, f"wrong rate {wf.getframerate()}"
            assert wf.getnframes() > 0, "no frames"
        return True
    except Exception as e:
        print(f"    WAV error: {e}")
        return False


def run():
    # Use a temp dir so tests don't pollute real sessions
    import tempfile
    tmp = Path(tempfile.mkdtemp(prefix="vf_test_sessions_"))
    print(f"\nTest sessions dir: {tmp}\n")

    mgr = SessionManager(sessions_dir=tmp)

    # ===========================================================
    # SESSION 1 — Full content: 2 recordings + 3 formatted outputs
    # ===========================================================
    print("=" * 60)
    print("SESSION 1 — 2 recordings, edits, 3 formatted outputs")
    print("=" * 60)

    # Recording 1 (WASAPI)
    audio1 = make_audio(3.0)
    p1 = mgr.save_audio(audio1, source="wasapi")
    check("Audio file returned", p1 is not None)
    check("Audio file exists", p1 is not None and p1.exists())
    check("Audio 1 is valid WAV", p1 is not None and verify_wav(p1))
    check("Audio filename is rec_001_wasapi.wav", p1 is not None and p1.name == "rec_001_wasapi.wav")

    # Recording 2 (phone)
    audio2 = make_audio(1.5)
    p2 = mgr.save_audio(audio2, source="phone")
    check("Audio 2 returned", p2 is not None)
    check("Audio 2 is rec_002_phone.wav", p2 is not None and p2.name == "rec_002_phone.wav")
    check("Audio 2 is valid WAV", p2 is not None and verify_wav(p2))

    # Formatted output 1 — clean
    raw_text = (
        "This is a simulated recording session for VoiceForge. "
        "We are testing the session persistence layer to make sure "
        "everything gets saved correctly. This is a full content session "
        "with multiple recordings and formatted outputs."
    )
    pf1 = mgr.save_formatted("clean", "Cleaned: " + raw_text)
    check("Formatted clean_001.txt saved", pf1 is not None and pf1.exists())
    check("Formatted filename clean_001.txt", pf1 is not None and pf1.name == "clean_001.txt")

    # Formatted output 2 — bullet
    pf2 = mgr.save_formatted("bullet", "• Point one\n• Point two\n• Point three")
    check("Formatted bullet_001.txt saved", pf2 is not None and pf2.exists())

    # Formatted output 3 — clean again (re-run)
    pf3 = mgr.save_formatted("clean", "Cleaned version 2: " + raw_text)
    check("Re-run clean saved as clean_002.txt", pf3 is not None and pf3 is not None and pf3.name == "clean_002.txt")

    # Simulate user edit then finalize (clear)
    raw_with_edits = raw_text + "\n\n[User added this manually during editing]"
    sid1 = mgr.finalize(raw_with_edits)
    print(f"\n  Session ID after finalize: {sid1}")
    check("Session finalized (not None)", sid1 is not None)
    check("Not flagged low-content", sid1 is not None and "_low_" not in sid1)

    # Verify folder structure
    s1_dir = tmp / sid1 if sid1 and not sid1.startswith("_low_") else tmp / sid1
    check("Session dir exists", s1_dir.exists())
    check("raw.txt saved", (s1_dir / "raw.txt").exists())
    check("raw.txt contains user edit", "[User added" in (s1_dir / "raw.txt").read_text())
    check("session.json exists", (s1_dir / "session.json").exists())

    meta1 = json.loads((s1_dir / "session.json").read_text())
    check("audio_recordings = 2", meta1.get("audio_recordings") == 2)
    check("formatted_outputs = 3", meta1.get("formatted_outputs") == 3)
    check("formatted_modes has clean=2, bullet=1", meta1.get("formatted_modes") == {"clean": 2, "bullet": 1})
    check("low_content = False", meta1.get("low_content") is False)
    check("finalized timestamp set", meta1.get("finalized") is not None)

    audio_files = sorted(f.name for f in (s1_dir / "audio").iterdir())
    check("2 audio files", len(audio_files) == 2)
    check("rec_001_wasapi.wav present", "rec_001_wasapi.wav" in audio_files)
    check("rec_002_phone.wav present", "rec_002_phone.wav" in audio_files)

    fmt_files = sorted(f.name for f in (s1_dir / "formatted").iterdir())
    check("3 formatted files", len(fmt_files) == 3)
    check("clean_001.txt present", "clean_001.txt" in fmt_files)
    check("clean_002.txt present", "clean_002.txt" in fmt_files)
    check("bullet_001.txt present", "bullet_001.txt" in fmt_files)

    # ===========================================================
    # SESSION 2 — Low-content: a few words, no formatted output
    # ===========================================================
    print()
    print("=" * 60)
    print("SESSION 2 — Low-content (few words, no formatted output)")
    print("=" * 60)

    time.sleep(0.05)  # ensure different timestamp

    audio3 = make_audio(0.5)
    mgr.save_audio(audio3, source="wasapi")  # record briefly

    short_text = "Oops accidentally cleared"
    sid2 = mgr.finalize(short_text)
    print(f"\n  Session ID after finalize: {sid2}")
    check("Session 2 finalized", sid2 is not None)
    check("Flagged _low_ (low-content)", sid2 is not None and sid2.startswith("_low_"))

    # Find low dir
    low_dirs = [d for d in tmp.iterdir() if d.is_dir() and d.name.startswith("_low_")]
    check("_low_ folder exists", len(low_dirs) == 1)
    if low_dirs:
        low_meta = json.loads((low_dirs[0] / "session.json").read_text())
        check("low_content = True in meta", low_meta.get("low_content") is True)
        check("audio_recordings = 1", low_meta.get("audio_recordings") == 1)
        check("formatted_outputs = 0", low_meta.get("formatted_outputs") == 0)

    # ===========================================================
    # SESSION 3 — Browse API: list_sessions and get_session_detail
    # ===========================================================
    print()
    print("=" * 60)
    print("SESSION 3 — Browse API (list + detail)")
    print("=" * 60)

    sessions = mgr.list_sessions()
    check("list_sessions returns 2 entries", len(sessions) == 2)

    # Detail for session 1
    detail = mgr.get_session_detail(sid1)
    check("get_session_detail not None", detail is not None)
    if detail:
        check("has_raw = True", detail.get("has_raw") is True)
        check("2 audio files in detail", len(detail.get("audio_files", [])) == 2)
        check("3 formatted files in detail", len(detail.get("formatted_files", [])) == 3)

    # raw path
    raw_path = mgr.get_raw_path(sid1)
    check("get_raw_path returns path", raw_path is not None and raw_path.exists())

    # file path for audio
    af = mgr.get_file_path(sid1, "audio", "rec_001_wasapi.wav")
    check("get_file_path for audio works", af is not None and af.exists())

    # file path for formatted
    ff = mgr.get_file_path(sid1, "formatted", "clean_001.txt")
    check("get_file_path for formatted works", ff is not None and ff.exists())

    # ===========================================================
    # SESSION 4 — Empty session (no audio, no text) → should still finalize
    # ===========================================================
    print()
    print("=" * 60)
    print("SESSION 4 — Empty clear (no audio, no text)")
    print("=" * 60)

    # Trigger session creation via save_formatted then finalize empty
    mgr.save_formatted("markdown", "# Test\n\nSome markdown content here for testing purposes only.")
    sid4 = mgr.finalize("")  # empty raw text
    check("Empty session finalized", sid4 is not None)
    # Has formatted output → not _low_
    check("Not low (has formatted output)", sid4 is not None and "_low_" not in sid4)

    # ===========================================================
    # SUMMARY
    # ===========================================================
    print()
    print("=" * 60)
    if _failures:
        print(f"{len(_failures)} check(s) FAILED:")
        for f in _failures:
            print(f"  [FAIL] {f}")
        sys.exit(1)
    else:
        print("All checks passed [PASS]")

    # Cleanup
    import shutil
    shutil.rmtree(tmp)
    print(f"Cleaned up: {tmp}")


if __name__ == "__main__":
    run()
