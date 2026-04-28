"""
formatter.py — Extensible text output formatting.

Provides a Formatter class with a registry-based mode system.
New modes can be added via the @Formatter.register decorator.

Built-in modes:
    "clean"  — Proper sentence formatting
    "bullet" — Bullet points per phrase
    "dev"    — Structured dev notes (Goals / Tasks / Notes)
    "raw"    — Unmodified transcription
"""

import re
from datetime import datetime


class Formatter:
    """
    Extensible transcription formatter with dynamic mode switching.

    Usage:
        fmt = Formatter(mode="clean")
        output = fmt.format("some transcription text")
        fmt.set_mode("dev")
        output = fmt.format("we need to fix the login bug")

    Adding custom modes:
        @Formatter.register("mymode")
        def my_formatter(text):
            return f"[CUSTOM] {text}"
    """

    _registry = {}

    def __init__(self, mode="clean"):
        self._mode = None
        self.set_mode(mode)

    @property
    def mode(self):
        return self._mode

    @classmethod
    def available_modes(cls):
        """Return list of all registered mode names."""
        return list(cls._registry.keys())

    @classmethod
    def register(cls, name):
        """
        Decorator to register a new formatting mode.

        The decorated function receives a single string argument
        and must return a formatted string.

        Args:
            name: mode name (string)

        Usage:
            @Formatter.register("custom")
            def custom_format(text):
                return f">> {text}"
        """
        def decorator(func):
            cls._registry[name] = func
            return func
        return decorator

    def set_mode(self, mode):
        """
        Switch to a different formatting mode.

        Args:
            mode: one of the registered mode names

        Raises:
            ValueError: if mode is not registered
        """
        if mode not in self._registry:
            available = ", ".join(f"'{m}'" for m in self._registry)
            raise ValueError(f"Unknown mode: '{mode}'. Available: {available}")
        self._mode = mode

    def format(self, text):
        """
        Format text using the current mode.

        Args:
            text: raw transcription string

        Returns:
            str — formatted output, or empty string if input is empty
        """
        text = text.strip()
        if not text:
            return ""
        return self._registry[self._mode](text)


# ==============================
# BACKWARD COMPATIBILITY
# ==============================

def format_text(text, mode="clean"):
    """
    Functional interface (backward compatible).

    Prefer using Formatter class for new code.
    """
    fmt = Formatter(mode=mode)
    return fmt.format(text)


# ==============================================================================
# BUILT-IN MODES
# ==============================================================================


@Formatter.register("raw")
def _format_raw(text):
    """Return unmodified transcription."""
    return text


@Formatter.register("clean")
def _format_clean(text):
    """
    Light human-quality cleanup of transcribed speech.

    Does:
      - Removes filler words (um, uh, like, basically, okay so)
      - Merges sentence fragments
      - Fixes casing after sentence boundaries
      - Smooths double punctuation / whitespace
      - Preserves meaning — NO rewording

    This should feel like a human lightly edited the transcript.
    """
    # Remove common filler words (whole words only)
    filler_pattern = r'\b(?:um+|uh+|erm|hmm+|like,?\s|you know,?\s|I mean,?\s|basically,?\s|okay so,?\s|so basically,?\s|right so,?\s)\b'
    text = re.sub(filler_pattern, '', text, flags=re.IGNORECASE)

    # Clean up whitespace
    text = re.sub(r'\s+', ' ', text).strip()

    # Merge broken fragments: remove periods that come before lowercase
    # "this prompt. here was actually" → "this prompt here was actually"
    text = re.sub(r'\.\s+([a-z])', r' \1', text)

    # Fix double punctuation
    text = re.sub(r'([.!?])\s*\1+', r'\1', text)
    text = re.sub(r'\.\s*,', ',', text)
    text = re.sub(r',\s*\.', '.', text)

    # Remove trailing fragments (very short orphan after last period)
    # "This is a test. the" → "This is a test."
    match = re.match(r'(.+[.!?])\s+(\S{1,4})$', text)
    if match:
        text = match.group(1)

    # Capitalize first character
    if text and text[0].islower():
        text = text[0].upper() + text[1:]

    # Capitalize after sentence-ending punctuation
    text = re.sub(r'([.!?])\s+([a-z])', lambda m: f"{m.group(1)} {m.group(2).upper()}", text)

    # Ensure ending punctuation
    text = text.strip()
    if text and text[-1] not in '.!?':
        text += '.'

    # Final whitespace cleanup
    text = re.sub(r'\s+', ' ', text).strip()

    return text


@Formatter.register("bullet")
def _format_bullet(text):
    """
    Convert text into bullet points.

    Splits on sentence boundaries and conjunctions (and, also, plus, then)
    to create individual action items.
    """
    # Split on sentence boundaries
    parts = re.split(r'(?<=[.!?])\s+', text)

    # Further split on conjunctions for more granular bullets
    expanded = []
    for part in parts:
        # Split on "and", "also", "plus", "then" when they connect clauses
        sub_parts = re.split(r'\s+(?:and\s+(?:also\s+)?|also\s+|plus\s+|then\s+)', part, flags=re.IGNORECASE)
        expanded.extend(sub_parts)

    # Clean and format
    bullets = []
    for item in expanded:
        item = item.strip().strip('.!?,;')
        if not item:
            continue
        # Capitalize first letter
        if item[0].islower():
            item = item[0].upper() + item[1:]
        bullets.append(f"  • {item}")

    if not bullets:
        return f"  • {text}"

    return "\n".join(bullets)


@Formatter.register("dev")
def _format_dev(text):
    """
    Structured dev notes — classifies phrases into Goals, Tasks, and Notes.

    Uses keyword matching to categorize:
      - Goals: "need to", "want to", "goal is", "should", "have to", "gotta"
      - Tasks: "fix", "add", "create", "update", "remove", "build", "implement",
               "refactor", "change", "move", "test", "debug", "deploy", "write"
      - Notes: everything else

    Example:
        Input:  "okay so we need to fix the mic detection and improve buffering"
        Output:
            🎯 Goals:
              • Fix the mic detection
            📋 Tasks:
              • Improve buffering
    """
    timestamp = datetime.now().strftime("%H:%M:%S")

    # Split into individual phrases
    phrases = _split_phrases(text)

    goals = []
    tasks = []
    notes = []

    # Goal indicators — intent/desire patterns
    goal_patterns = [
        r'\b(?:need|needs)\s+to\b',
        r'\b(?:want|wants)\s+to\b',
        r'\bgoal\s+is\b',
        r'\bshould\b',
        r'\bhave\s+to\b',
        r'\bgotta\b',
        r'\blet\'?s\b',
        r'\bwe\s+(?:can|could|might)\b',
    ]

    # Task indicators — action verbs
    task_keywords = [
        'fix', 'add', 'create', 'update', 'remove', 'delete',
        'build', 'implement', 'refactor', 'change', 'move',
        'test', 'debug', 'deploy', 'write', 'setup', 'set up',
        'install', 'configure', 'migrate', 'upgrade', 'optimize',
        'clean', 'rename', 'merge', 'split', 'check', 'review',
        'improve', 'make',
    ]
    task_pattern = r'\b(?:' + '|'.join(task_keywords) + r')\b'

    for phrase in phrases:
        phrase_lower = phrase.lower()
        classified = False

        # Check for goal patterns
        for pattern in goal_patterns:
            if re.search(pattern, phrase_lower):
                # Extract the actionable part after the goal keyword
                cleaned = _extract_action(phrase, pattern)
                goals.append(cleaned)
                classified = True
                break

        if classified:
            continue

        # Check for task patterns (starts with or contains action verb)
        if re.search(task_pattern, phrase_lower):
            tasks.append(_capitalize(phrase))
            classified = True

        if not classified:
            notes.append(_capitalize(phrase))

    # Build output
    lines = [f"[{timestamp}] 💻 Dev Note"]

    if goals:
        lines.append("  🎯 Goals:")
        for g in goals:
            lines.append(f"    • {g}")

    if tasks:
        lines.append("  📋 Tasks:")
        for t in tasks:
            lines.append(f"    • {t}")

    if notes:
        lines.append("  📝 Notes:")
        for n in notes:
            lines.append(f"    • {n}")

    # Fallback: if nothing was categorized, just dump as notes
    if not goals and not tasks and not notes:
        lines.append(f"  📝 Notes:")
        lines.append(f"    • {_capitalize(text)}")

    return "\n".join(lines)


# ==============================================================================
# HELPERS
# ==============================================================================


def _split_phrases(text):
    """
    Split transcription text into individual phrases.

    Handles sentence boundaries and conjunctions like
    "and", "also", "plus" that connect separate ideas.
    """
    # First split on sentence boundaries
    parts = re.split(r'(?<=[.!?])\s+', text)

    # Then split on major conjunctions that connect separate ideas
    expanded = []
    for part in parts:
        sub = re.split(
            r'\s+(?:and\s+(?:then\s+|also\s+)?|also\s+|plus\s+|then\s+)',
            part,
            flags=re.IGNORECASE,
        )
        expanded.extend(sub)

    # Clean up
    result = []
    for item in expanded:
        item = item.strip().strip('.!?,;:')
        # Remove leading filler words
        item = re.sub(r'^(?:okay|ok|so|um|uh|like|well|basically|alright|right)\s+',
                       '', item, flags=re.IGNORECASE).strip()
        if item and len(item) > 1:
            result.append(item)

    return result


def _extract_action(phrase, goal_pattern):
    """
    Extract the actionable part from a goal phrase.

    E.g., "we need to fix the login" → "Fix the login"
    """
    # Try to extract what comes after the goal keyword
    match = re.search(goal_pattern, phrase, re.IGNORECASE)
    if match:
        after = phrase[match.end():].strip()
        if after:
            return _capitalize(after)
    return _capitalize(phrase)


def _capitalize(text):
    """Capitalize first letter, preserve rest."""
    text = text.strip()
    if not text:
        return text
    return text[0].upper() + text[1:]


@Formatter.register("markdown")
def _format_markdown(text):
    """
    Convert transcribed speech into clean Markdown.

    Structure:
      - Splits on sentence boundaries to form paragraphs
      - List-like sentences (starting with action verbs or enumerations) → MD bullets
      - Preserves the speaker's meaning — no rewording

    Useful for pasting into AI prompts, docs, or notes.
    """
    # Remove filler words first
    filler = r'\b(?:um+|uh+|erm|hmm+|like,?\s|you know,?\s|I mean,?\s|basically,?\s|okay so,?\s|right so,?\s)\b'
    text = re.sub(filler, '', text, flags=re.IGNORECASE)
    text = re.sub(r'\s+', ' ', text).strip()

    # Split into sentences
    sentences = re.split(r'(?<=[.!?])\s+', text)

    # Action-verb starters that suggest list items
    list_starters = r'^(?:add|fix|create|update|remove|build|implement|refactor|change|make|set|use|ensure|check|move|rename|test|deploy|write|install|configure)\b'

    paragraphs = []
    list_items = []

    def flush_list():
        if list_items:
            paragraphs.append('\n'.join(f'- {item}' for item in list_items))
            list_items.clear()

    for sent in sentences:
        sent = sent.strip().strip('.!?,;')
        if not sent:
            continue
        # Capitalize
        sent = sent[0].upper() + sent[1:] if sent else sent

        if re.match(list_starters, sent, re.IGNORECASE):
            list_items.append(sent)
        else:
            flush_list()
            paragraphs.append(sent + '.')

    flush_list()

    if not paragraphs:
        return f'{text}.'

    return '\n\n'.join(paragraphs)

