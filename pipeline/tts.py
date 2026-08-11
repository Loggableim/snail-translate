"""TTS-API-Clients (Batch-Modus).

Unterstützt:
- edge-tts (Free-Tier, kostenlos, kein API-Key nötig)
- Google Cloud TTS (optional, Service Account Auth)
- fish.audio (Paid-Tier, s2-pro Modell)
- Deepgram Aura (Alternative, niedrigere Latenz ~150ms)
"""

import subprocess
import sys
import time
from dataclasses import dataclass

import requests


@dataclass
class TTSResult:
    audio_bytes: bytes
    format: str  # "mp3" | "wav" | "opus"
    latency_ms: float
    api: str  # "edge_tts" | "google" | "fishaudio" | "deepgram_aura"


def synthesize_google(text: str, language: str = "en") -> TTSResult:
    """Google Cloud TTS — Standardstimmen.

    ⚠️ Auth via Service Account JSON, NICHT API-Key.
    Setzt GOOGLE_APPLICATION_CREDENTIALS Umgebungsvariable auf Pfad zur
    JSON-Datei. Nutzt google-cloud-texttospeech Library.

    Args:
        text: Zu synthetisierender Text.
        language: Sprachcode (default: "en").

    Returns:
        TTSResult mit MP3-Audio-Bytes und Latenz.
    """
    from google.cloud import texttospeech

    client = texttospeech.TextToSpeechClient()

    synthesis_input = texttospeech.SynthesisInput(text=text)
    voice = texttospeech.VoiceSelectionParams(
        language_code=language,
        name=f"{language}-Standard-A",  # Standardstimme
    )
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
    )

    t0 = time.monotonic()
    response = client.synthesize_speech(
        input=synthesis_input, voice=voice, audio_config=audio_config
    )
    t1 = time.monotonic()

    return TTSResult(
        audio_bytes=response.audio_content,
        format="mp3",
        latency_ms=(t1 - t0) * 1000,
        api="google",
    )


def synthesize_edge_tts(text: str, language: str = "en") -> TTSResult:
    """edge-tts — Kostenlos, kein API-Key nötig.

    Nutzt Microsoft Edge TTS via Subprocess.
    edge-tts muss installiert sein: pip install edge-tts

    Args:
        text: Zu synthetisierender Text.
        language: Sprachcode (default: "en").

    Returns:
        TTSResult mit MP3-Audio-Bytes und Latenz.
    """
    voice = "de-DE-KatjaNeural" if language == "de" else "en-US-JennyNeural"

    t0 = time.monotonic()
    result = subprocess.run(
        [
            sys.executable, "-m", "edge_tts",
            "--voice", voice,
            "--text", text,
            "--write-media", "-",
        ],
        capture_output=True,
        timeout=30,
    )
    t1 = time.monotonic()

    if result.returncode != 0:
        raise RuntimeError(f"edge-tts failed: {result.stderr.decode()}")

    return TTSResult(
        audio_bytes=result.stdout,
        format="mp3",
        latency_ms=(t1 - t0) * 1000,
        api="edge_tts",
    )


def synthesize_fishaudio(
    text: str,
    api_key: str,
) -> TTSResult:
    """fish.audio TTS — Batch-Modus.

    Args:
        text: Zu synthetisierender Text.
        api_key: fish.audio API-Key.

    Returns:
        TTSResult mit MP3-Audio-Bytes und Latenz.
    """
    url = "https://api.fish.audio/v1/tts"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "text": text,
        "format": "mp3",
    }

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, json=payload)
    t1 = time.monotonic()

    resp.raise_for_status()

    return TTSResult(
        audio_bytes=resp.content,
        format="mp3",
        latency_ms=(t1 - t0) * 1000,
        api="fishaudio",
    )


def synthesize_fishaudio_stream(
    text: str,
    api_key: str,
) -> tuple[float, bytes]:
    """fish.audio TTS — HTTP-Streaming-Modus.

    Sendet Text und empfängt Audio-Chunks via HTTP-Chunked-Transfer.
    Gibt (time_to_first_audio_ms, full_audio_bytes) zurück.

    Args:
        text: Zu synthetisierender Text.
        api_key: fish.audio API-Key.

    Returns:
        Tuple aus (TTFA in ms, vollständige Audio-Bytes).
    """
    url = "https://api.fish.audio/v1/tts"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "text": text,
        "format": "mp3",
        "latency": "balanced",
    }

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, json=payload, stream=True)
    resp.raise_for_status()

    chunks = []
    first_chunk_time = None

    for chunk in resp.iter_content(chunk_size=4096):
        if chunk:
            if first_chunk_time is None:
                first_chunk_time = time.monotonic()
            chunks.append(chunk)

    t1 = time.monotonic()
    ttfa = (first_chunk_time - t0) * 1000 if first_chunk_time else (t1 - t0) * 1000

    return ttfa, b"".join(chunks)


def synthesize_deepgram_aura(
    text: str, api_key: str, voice: str = "aura-asteria-en"
) -> TTSResult:
    """Deepgram Aura — Alternative TTS (niedrigere Latenz ~150ms).

    Batch-Modus: HTTP POST, returns MP3 bytes.
    Nur als Fallback/Alternative zu fish.audio.

    Args:
        text: Zu synthetisierender Text.
        api_key: Deepgram API-Key.
        voice: Stimme (default: "aura-asteria-en").

    Returns:
        TTSResult mit MP3-Audio-Bytes und Latenz.
    """
    url = "https://api.deepgram.com/v1/speak"
    headers = {
        "Authorization": f"Token {api_key}",
        "Content-Type": "application/json",
    }
    payload = {"text": text}

    t0 = time.monotonic()
    resp = requests.post(url, headers=headers, json=payload, params={"model": voice})
    t1 = time.monotonic()

    resp.raise_for_status()

    return TTSResult(
        audio_bytes=resp.content,
        format="mp3",
        latency_ms=(t1 - t0) * 1000,
        api="deepgram_aura",
    )
