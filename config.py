"""
config.py — Centralized configuration for VoiceForge.

Uses a dataclass for structured, type-safe config with defaults.
Supports loading overrides from a JSON file.

Usage:
    from config import cfg

    print(cfg.mic_device)
    print(cfg.silence_threshold)
    print(cfg.get_model_for("ai_dev"))  # per-mode model routing

To customize without editing this file:
    1. Create voice_forge.json next to main.py
    2. Add only the values you want to override:
       {
           "mic_device": 10,
           "silence_threshold": 0.006,
           "model_size": "small",
           "ollama_models": {
               "ai_dev": "deepseek-r1:8b",
               "ai_summary": "mistral:7b"
           }
       }
"""

import json
import os
import sys
from dataclasses import dataclass, field, fields


@dataclass
class VoiceForgeConfig:
    """All tunable parameters for the VoiceForge pipeline."""

    # --- Whisper model ---
    model_size: str = "base"            # tiny, base, small, medium, large-v2
    device: str = "cpu"                 # cpu or cuda
    compute_type: str = "int8"          # int8, float16, float32

    # --- Microphone ---
    mic_device: int = -1                 # audio input device index (-1 = auto-detect)
    target_sample_rate: int = 16000     # Whisper expects 16kHz

    # --- Speech detection ---
    silence_threshold: float = 0.005    # volume below this = silence (tuned for room noise ~0.003)
    speech_threshold: float = 0.008     # must hit this to count as actual speech
    silence_limit: int = 25             # how many quiet chunks = "done talking" (~0.6s)
    paragraph_break_silence: int = 86   # chunks of silence = new paragraph (~2s at 44100/1024)
    min_buffer_size: int = 30           # minimum chunks to bother processing

    # --- Audio processing ---
    signal_boost: float = 2.5           # amplification factor after normalization
    max_idle_buffer: int = 500          # trim buffer after this many chunks with no speech
    idle_buffer_keep: int = 100         # how many chunks to keep when trimming

    # --- Streaming / partial transcription ---
    partial_interval: int = 50          # yield a partial every N chunks (~1.1s at 44100/1024)
    partial_min_chunks: int = 20        # minimum chunks before first partial

    # --- AI / Ollama ---
    ollama_url: str = "http://localhost:11434"   # Ollama API base URL
    ollama_model: str = "mistral:7b"            # default model (fallback)
    ollama_timeout: int = 30                     # max seconds to wait for response
    ollama_models: dict = field(default_factory=dict)  # per-mode model routing

    # --- Output ---
    default_mode: str = "clean"         # clean, bullet, dev, raw, ai_dev, ai_summary

    def __post_init__(self):
        """Validate config values after initialization."""
        assert self.silence_threshold > 0, "silence_threshold must be positive"
        assert self.speech_threshold > self.silence_threshold, \
            "speech_threshold must be greater than silence_threshold"
        assert self.silence_limit > 0, "silence_limit must be positive"
        assert self.target_sample_rate > 0, "target_sample_rate must be positive"
        assert self.signal_boost > 0, "signal_boost must be positive"
        assert self.partial_interval > 0, "partial_interval must be positive"

    def get_model_for(self, mode: str) -> str:
        """
        Get the Ollama model to use for a given mode.

        Checks ollama_models dict first, falls back to ollama_model.

        Args:
            mode: the formatting mode name (e.g. "ai_dev")

        Returns:
            str — model name to use
        """
        return self.ollama_models.get(mode, self.ollama_model)

    def summary(self):
        """Return a formatted summary of current config."""
        lines = ["⚙️  VoiceForge Configuration:"]
        for f in fields(self):
            val = getattr(self, f.name)
            lines.append(f"  {f.name}: {val}")
        return "\n".join(lines)


# ==============================================================================
# CONFIG LOADING
# ==============================================================================

_CONFIG_FILENAME = "voice_forge.json"


def _find_config_file():
    """Look for voice_forge.json next to main.py or in cwd."""
    # Check directory of this config.py file
    here = getattr(sys, '_MEIPASS', os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, _CONFIG_FILENAME)
    if os.path.isfile(path):
        return path

    # Check cwd
    cwd_path = os.path.join(os.getcwd(), _CONFIG_FILENAME)
    if os.path.isfile(cwd_path):
        return cwd_path

    return None


def load_config():
    """
    Load config with optional JSON overrides.

    1. Start with dataclass defaults
    2. If voice_forge.json exists, override matching fields
    3. Return the final config

    Returns:
        VoiceForgeConfig instance
    """
    config_path = _find_config_file()

    if config_path is None:
        return VoiceForgeConfig()

    print(f"📄 Loading config from: {config_path}")

    with open(config_path, "r") as f:
        overrides = json.load(f)

    # Only apply keys that match actual config fields
    valid_fields = {f.name for f in fields(VoiceForgeConfig)}
    filtered = {}
    for key, value in overrides.items():
        if key in valid_fields:
            filtered[key] = value
        else:
            print(f"⚠️  Unknown config key ignored: '{key}'")

    return VoiceForgeConfig(**filtered)


# ==============================================================================
# SINGLETON INSTANCE — import this everywhere
# ==============================================================================

cfg = load_config()
