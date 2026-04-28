"""
ai_formatter.py — AI-powered formatting via local LLM (Ollama).

Supports multi-model routing: different AI modes can use different models.
Configure per-mode models in config via ollama_models dict.

Falls back to the rule-based formatter if the LLM is unavailable or fails.
"""

import json
import re
import urllib.request
import urllib.error
from datetime import datetime
from typing import Optional

from config import cfg


# ==============================================================================
# OLLAMA CLIENT
# ==============================================================================

class OllamaClient:
    """
    Lightweight Ollama HTTP client — no external dependencies.

    Uses urllib to hit the local Ollama API.
    Thread-safe and non-blocking (runs in caller's thread).
    Supports per-call model override for multi-model routing.
    """

    def __init__(self, base_url=None, timeout=None):
        self.base_url = base_url or cfg.ollama_url
        self.timeout = timeout or cfg.ollama_timeout
        self._available = None  # cached availability check

    def is_available(self) -> bool:
        """Check if Ollama is reachable (cached after first check)."""
        if self._available is not None:
            return self._available

        try:
            req = urllib.request.Request(f"{self.base_url}/api/tags")
            with urllib.request.urlopen(req, timeout=3) as resp:
                self._available = resp.status == 200
        except (urllib.error.URLError, OSError, TimeoutError):
            self._available = False

        return self._available

    def generate(self, prompt: str, model: Optional[str] = None) -> Optional[str]:
        """
        Send a prompt to Ollama and return the response text.

        Args:
            prompt: the full prompt string
            model: model name to use (overrides default). If None, uses cfg.ollama_model.

        Returns:
            str — model response, or None if request failed
        """
        model = model or cfg.ollama_model

        payload = json.dumps({
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {
                "temperature": 0.3,     # low temp for structured output
                "num_predict": 512,     # cap response length
            },
        }).encode("utf-8")

        req = urllib.request.Request(
            f"{self.base_url}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return data.get("response", "").strip()
        except (urllib.error.URLError, OSError, TimeoutError, json.JSONDecodeError) as e:
            print(f"⚠️ Ollama error ({model}): {e}")
            return None


# Singleton client
_client = OllamaClient()


# ==============================================================================
# PROMPT TEMPLATES
# ==============================================================================

AI_DEV_PROMPT = """You are a developer's voice assistant. Transform the following spoken thoughts into structured developer notes.

Rules:
- Extract actionable items and categorize them
- Be concise — use short bullet points
- Only include categories that have content
- Do NOT add items that weren't mentioned
- Do NOT include any preamble or explanation — output ONLY the structured notes
- Remove filler words (um, uh, like, okay, so, basically)

Text:
"{input}"

Output format (use exactly this structure, skip empty categories):
🎯 Goals:
  • [goal items]

📋 Tasks:
  • [task items]

📝 Notes:
  • [note items]"""


AI_SUMMARIZE_PROMPT = """Summarize the following spoken text into a clean, concise paragraph. Remove filler words and fix grammar. Do NOT add information that wasn't mentioned. Output ONLY the summary.

Text:
"{input}"
"""


AI_PROMPT_PROMPT = """You are a prompt engineer. Transform the following spoken thoughts into a clear, well-structured AI prompt.

Rules:
- Preserve the user's original intent completely
- Structure the output so it's ready to paste into an AI tool
- Improve clarity and remove filler words
- Do NOT hallucinate or add requirements that weren't mentioned
- Do NOT include any preamble or explanation — output ONLY the prompt
- Use clear sections if the input covers multiple aspects

Text:
"{input}"
"""


AI_SPEECH_PROMPT = """You are a speech editor. The speaker recorded themselves thinking out loud. Your job is to refine it into clean, delivery-ready speech — the kind a real person would actually give.

CRITICAL RULES — BREAK ANY OF THESE AND YOU HAVE FAILED:
- NEVER use these AI phrases: "certainly", "absolutely", "of course", "I'd be happy to", "it's worth noting", "in conclusion", "in summary", "delve", "leverage", "robust", "at the end of the day", "moving forward", "it's important to note"
- Do NOT add motivational fluff, filler transitions, or corporate speak that wasn't in the original
- Do NOT make the speaker sound like a TED talk unless they already sound like one
- Do NOT add content that was not in the original — not a single new idea
- Preserve the speaker's tone, rhythm, and vocabulary — if they're casual, keep it casual
- If there are pause markers (...... or multiple dots), treat them as intentional pauses in delivery — you may convert them to a natural pause phrase like "..." or remove them if they break flow, but do NOT explain or label them
- Fix grammar and filler words (um, uh, like, you know) silently
- Keep the output structured as flowing speech paragraphs — not bullets, not headers
- Output ONLY the refined speech text. No preamble, no "Here is your speech:", nothing extra.

Raw transcript:
"{input}"
"""


def _clean_response(result: str) -> str:
    """Strip <think>...</think> blocks from reasoning models."""
    return re.sub(r'<think>.*?</think>', '', result, flags=re.DOTALL).strip()


# ==============================================================================
# AI FORMATTING FUNCTIONS
# ==============================================================================

def ai_format_dev(text: str) -> str:
    """
    Format text using AI into structured dev notes.

    Uses the model configured for "ai_dev" mode (or default).
    Falls back to rule-based dev formatter if AI is unavailable.

    Args:
        text: raw transcription

    Returns:
        str — structured dev notes
    """
    timestamp = datetime.now().strftime("%H:%M:%S")
    model = cfg.get_model_for("ai_dev")

    if _client.is_available():
        print(f"🤖 Using model: {model} for ai_dev")
        prompt = AI_DEV_PROMPT.format(input=text)
        result = _client.generate(prompt, model=model)

        if result:
            result = _clean_response(result)

            # Validate it looks like structured output
            if any(marker in result for marker in ['🎯', '📋', '📝', 'Goals', 'Tasks', 'Notes']):
                return f"[{timestamp}] 🤖 AI Dev Note ({model})\n{result}"

            # Model returned something but not structured — still use it
            if len(result) > 10:
                return f"[{timestamp}] 🤖 AI Dev Note ({model})\n  📝 Notes:\n    • {result}"

    # Fallback to rule-based
    print(f"⚠️ AI unavailable ({model}), using rule-based formatter")
    from formatter import Formatter
    fallback = Formatter(mode="dev")
    return fallback.format(text)


def ai_format_summary(text: str) -> str:
    """
    AI-powered clean summary of spoken text.

    Uses the model configured for "ai_summary" mode (or default).
    Falls back to 'clean' mode if AI is unavailable.

    Args:
        text: raw transcription

    Returns:
        str — clean summary
    """
    model = cfg.get_model_for("ai_summary")

    if _client.is_available():
        print(f"🤖 Using model: {model} for ai_summary")
        prompt = AI_SUMMARIZE_PROMPT.format(input=text)
        result = _client.generate(prompt, model=model)

        if result:
            result = _clean_response(result)
            if result:
                return f"🤖 {result}"

    # Fallback
    from formatter import Formatter
    fallback = Formatter(mode="clean")
    return fallback.format(text)


def ai_format_prompt(text: str) -> str:
    """
    Convert spoken text into a structured AI prompt.

    Uses the model configured for "prompt" mode (or default).
    Falls back to 'clean' mode if AI is unavailable.

    Args:
        text: raw transcription

    Returns:
        str — structured prompt ready to paste into AI tools
    """
    model = cfg.get_model_for("prompt")

    if _client.is_available():
        print(f"🤖 Using model: {model} for prompt")
        prompt = AI_PROMPT_PROMPT.format(input=text)
        result = _client.generate(prompt, model=model)

        if result:
            result = _clean_response(result)
            if result:
                return result

    # Fallback: just clean it up
    from formatter import Formatter
    fallback = Formatter(mode="clean")
    return fallback.format(text)


def ai_format_speech(text: str) -> str:
    """
    Refine spoken transcript into delivery-ready speech text.

    Preserves the speaker's voice and tone. Strips AI clichés.
    Uses higher temperature than other modes to keep it natural.
    Falls back to 'clean' mode if AI is unavailable.

    Args:
        text: raw transcription

    Returns:
        str — polished speech-ready text in the speaker's own voice
    """
    model = cfg.get_model_for("speech")

    if _client.is_available():
        print(f"🤖 Using model: {model} for speech")
        prompt = AI_SPEECH_PROMPT.format(input=text)

        # Slightly higher temperature keeps the output feeling human, not robotic
        payload_override = {"temperature": 0.55, "num_predict": 1024}

        # Build request manually so we can override options
        import json
        import urllib.request
        model_to_use = model or cfg.ollama_model
        payload = json.dumps({
            "model": model_to_use,
            "prompt": prompt,
            "stream": False,
            "options": payload_override,
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{_client.base_url}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            import urllib.request as _ur
            with _ur.urlopen(req, timeout=cfg.ollama_timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                result = data.get("response", "").strip()
                result = _clean_response(result)
                if result:
                    return result
        except Exception as e:
            print(f"⚠️ Speech mode Ollama error: {e}")

    # Fallback: rule-based clean
    from formatter import Formatter
    fallback = Formatter(mode="clean")
    return fallback.format(text)


# ==============================================================================
# REGISTER MODES
# ==============================================================================

def register_ai_modes():
    """
    Register AI-powered formatting modes with the Formatter registry.

    Call this after formatter.py is loaded.
    Modes registered:
        - "ai_dev"     — AI-structured dev notes (Goals/Tasks/Notes)
        - "ai_summary" — AI-cleaned summary
        - "summary"    — Alias for ai_summary (user-friendly name)
        - "prompt"     — Convert speech into structured AI prompts
    """
    from formatter import Formatter

    @Formatter.register("ai_dev")
    def _ai_dev(text):
        return ai_format_dev(text)

    @Formatter.register("ai_summary")
    def _ai_summary(text):
        return ai_format_summary(text)

    @Formatter.register("summary")
    def _summary(text):
        return ai_format_summary(text)

    @Formatter.register("prompt")
    def _prompt(text):
        return ai_format_prompt(text)

    @Formatter.register("speech")
    def _speech(text):
        return ai_format_speech(text)

    # Log availability and model routing
    if _client.is_available():
        default = cfg.ollama_model
        routing = cfg.ollama_models
        if routing:
            routes = ", ".join(f"{mode}→{model}" for mode, model in routing.items())
            print(f"🤖 AI formatter: Ollama connected (default: {default}, routes: {routes})")
        else:
            print(f"🤖 AI formatter: Ollama connected (model: {default})")
    else:
        print(f"⚠️ AI formatter: Ollama not available — AI modes will fallback to rule-based")
