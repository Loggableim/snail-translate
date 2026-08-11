"""API-Keys & Konfiguration (lazy loading).

Keys werden nur geladen, wenn sie gebraucht werden.
Fehlende Keys lösen keinen Fehler aus — Fallback greift automatisch.
"""

import os
from functools import lru_cache

# ── Pipeline-Konfiguration (statisch) ──────────────────────────────────

SOURCE_LANG = "de"
TARGET_LANG = "en"
SAMPLE_RATE = 16000

# ── API-Keys (lazy, alle optional) ─────────────────────────────────────

@lru_cache(maxsize=1)
def groq_api_key() -> str | None:
    return os.environ.get("SNAIL_GROQ_API_KEY") or None

@lru_cache(maxsize=1)
def deepgram_api_key() -> str | None:
    return os.environ.get("SNAIL_DEEPGRAM_API_KEY") or None

@lru_cache(maxsize=1)
def morph_api_key() -> str | None:
    return os.environ.get("SNAIL_MORPH_API_KEY") or None

@lru_cache(maxsize=1)
def fishaudio_api_key() -> str | None:
    return os.environ.get("SNAIL_FISHAUDIO_API_KEY") or None

@lru_cache(maxsize=1)
def openai_api_key() -> str | None:
    return os.environ.get("SNAIL_OPENAI_API_KEY") or None

# Legacy (nicht mehr benötigt, aber behalten für Abwärtskompatibilität)
@lru_cache(maxsize=1)
def deepl_api_key() -> str | None:
    return os.environ.get("SNAIL_DEEPL_API_KEY") or None

@lru_cache(maxsize=1)
def google_credentials_path() -> str | None:
    return os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") or None


# ── Key-Validierung ────────────────────────────────────────────────────

def validate_keys_for_tier(tier: str) -> list[str]:
    """Prüft, welche Keys fehlen. Leer = mindestens ein Key pro Schritt da."""
    missing = []

    # STT: Deepgram oder Groq
    if not deepgram_api_key() and not groq_api_key():
        missing.append("STT (SNAIL_DEEPGRAM_API_KEY oder SNAIL_GROQ_API_KEY)")

    # MT: Morph oder Groq
    if not morph_api_key() and not groq_api_key():
        missing.append("MT (SNAIL_MORPH_API_KEY oder SNAIL_GROQ_API_KEY)")

    # TTS: fish.audio oder edge-tts (edge-tts ist immer da)
    # Kein Check nötig — edge-tts ist Fallback

    return missing
