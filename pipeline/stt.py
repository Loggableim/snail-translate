"""STT-API-Clients (Batch-Modus).

Unterstützt:
- Groq Whisper (Free-Tier, Batch)
- Deepgram Nova-2 (Paid-Tier, Batch HTTP POST)
"""

import time
from dataclasses import dataclass

import requests


@dataclass
class STTResult:
    transcript: str
    latency_ms: float
    api: str  # "groq" | "deepgram"


def transcribe_groq(
    audio_path: str, api_key: str, language: str = "de"
) -> STTResult:
    """Groq Whisper API — BATCH-Modus.

    Multipart-Upload der WAV-Datei, wartet auf komplette Transkription.
    ⚠️ KEIN Streaming: Groq liefert das Transkript erst nach kompletter
    Verarbeitung. Latenz hängt von Audiolänge ab (typ. 0.5–3s für 3–15s Audio).
    Rate-Limit: 30 req/min (Free-Tier) — Benchmark muss drosseln.

    Args:
        audio_path: Pfad zur WAV-Datei (16kHz mono).
        api_key: Groq API-Key.
        language: Sprachcode (default: "de").

    Returns:
        STTResult mit Transkript und Latenz.
    """
    url = "https://api.groq.com/openai/v1/audio/transcriptions"
    headers = {"Authorization": f"Bearer {api_key}"}

    t0 = time.monotonic()
    with open(audio_path, "rb") as f:
        files = {"file": f}
        data = {"model": "whisper-large-v3", "language": language}
        resp = requests.post(url, headers=headers, files=files, data=data)
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    transcript = result.get("text", "").strip()

    return STTResult(
        transcript=transcript,
        latency_ms=(t1 - t0) * 1000,
        api="groq",
    )


def transcribe_deepgram(
    audio_path: str, api_key: str, language: str = "de"
) -> STTResult:
    """Deepgram Nova-2 — BATCH-Modus (HTTP POST, nicht WebSocket).

    Sendet WAV als binary body, erhält JSON mit Transkript.
    WebSocket-Streaming ist für später (echtes Streaming-Prototyp).

    Args:
        audio_path: Pfad zur WAV-Datei (16kHz mono).
        api_key: Deepgram API-Key.
        language: Sprachcode (default: "de").

    Returns:
        STTResult mit Transkript und Latenz.
    """
    url = "https://api.deepgram.com/v1/listen"
    params = {
        "model": "nova-2",
        "language": language,
        "smart_format": "true",
    }
    headers = {
        "Authorization": f"Token {api_key}",
        "Content-Type": "audio/wav",
    }

    t0 = time.monotonic()
    with open(audio_path, "rb") as f:
        resp = requests.post(url, headers=headers, params=params, data=f.read())
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    # Deepgram JSON-Struktur: results.channels[0].alternatives[0].transcript
    try:
        transcript = (
            result["results"]["channels"][0]["alternatives"][0]["transcript"]
        ).strip()
    except (KeyError, IndexError):
        transcript = ""

    return STTResult(
        transcript=transcript,
        latency_ms=(t1 - t0) * 1000,
        api="deepgram",
    )


def transcribe_openai(
    audio_path: str, api_key: str, language: str = "de"
) -> STTResult:
    """OpenAI Whisper API — BATCH-Modus.

    Multipart-Upload der WAV-Datei, wartet auf komplette Transkription.
    Nutzt whisper-1 Modell.

    Args:
        audio_path: Pfad zur WAV-Datei (16kHz mono).
        api_key: OpenAI API-Key.
        language: Sprachcode (default: "de").

    Returns:
        STTResult mit Transkript und Latenz.
    """
    url = "https://api.openai.com/v1/audio/transcriptions"
    headers = {"Authorization": f"Bearer {api_key}"}

    t0 = time.monotonic()
    with open(audio_path, "rb") as f:
        files = {"file": f}
        data = {"model": "whisper-1", "language": language}
        resp = requests.post(url, headers=headers, files=files, data=data)
    t1 = time.monotonic()

    resp.raise_for_status()
    result = resp.json()
    transcript = result.get("text", "").strip()

    return STTResult(
        transcript=transcript,
        latency_ms=(t1 - t0) * 1000,
        api="openai",
    )
