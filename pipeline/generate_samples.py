"""Audio-Sample-Generator: Erzeugt S1–S10 WAV-Dateien (16kHz mono).

Generierungs-Strategien (in Reihenfolge):
1. Google Cloud TTS (wenn GOOGLE_APPLICATION_CREDENTIALS gesetzt)
2. edge-tts (kostenlos, kein API-Key nötig) — via Subprocess
3. Fallback: Stille + Sinuston (für Struktur-Tests ohne API)

Output: audio_samples/S1.wav ... S10.wav
"""

import io
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

# ── Sample-Definitionen (aus API_BENCHMARK_PLAN.md §2.1) ──────────────

SAMPLES = {
    "S1": {"text": "Hallo, wie geht es dir?", "lang": "de", "desc": "kurz, einfach"},
    "S2": {
        "text": "Können Sie mir sagen, wo der nächste Bahnhof ist?",
        "lang": "de",
        "desc": "mittel, Reise",
    },
    "S3": {
        "text": "Ich bin vor zwei Tagen in Berlin angekommen und habe mir das Hotel gesucht, aber die Adresse war falsch.",
        "lang": "de",
        "desc": "lang, komplex",
    },
    "S4": {
        "text": "Einmal Kaffee, bitte. Mit Milch.",
        "lang": "de",
        "desc": "kurz, Alltag",
    },
    "S5": {
        "text": "Can you recommend a good restaurant nearby?",
        "lang": "en",
        "desc": "EN→DE Gegenrichtung",
    },
    "S6": {
        "text": "Also wir waren dann im Museum und da gab es diese Ausstellung über moderne Kunst und das war wirklich sehr interessant besonders der Teil mit den Fotografien.",
        "lang": "de",
        "desc": "lang, ohne Satzgrenzen",
    },
    "S7": {
        "text": "Ich brauche ein Ticket für den Airport-Shuttle.",
        "lang": "de",
        "desc": "Code-Switching",
    },
    "S8": {
        "text": "Guten Tag.",
        "lang": "de",
        "desc": "kurz, VAD-Test",
    },
    "S9": {
        "text": "Ich möchte zahlen.",
        "lang": "de",
        "desc": "Noise-Test",
    },
    "S10": {
        "text": "Danke schön. Wo ist die Toilette?",
        "lang": "de",
        "desc": "zwei Sätze mit Pause",
    },
}

SAMPLE_RATE = 16000
OUTPUT_DIR = Path("audio_samples")


def generate_google_tts(text: str, language: str) -> bytes:
    """Generiert Audio via Google Cloud TTS, gibt MP3-Bytes zurück."""
    from google.cloud import texttospeech

    client = texttospeech.TextToSpeechClient()
    synthesis_input = texttospeech.SynthesisInput(text=text)

    # Deutsche/englische Standardstimme
    voice_name = f"{language}-Standard-A"
    voice = texttospeech.VoiceSelectionParams(
        language_code=language,
        name=voice_name,
    )
    audio_config = texttospeech.AudioConfig(
        audio_encoding=texttospeech.AudioEncoding.MP3,
    )

    response = client.synthesize_speech(
        input=synthesis_input, voice=voice, audio_config=audio_config
    )
    return response.audio_content


def generate_edge_tts(text: str, language: str) -> bytes:
    """Generiert Audio via edge-tts (kostenlos), gibt MP3-Bytes zurück.

    edge-tts muss installiert sein: pip install edge-tts
    """
    voice = "de-DE-KatjaNeural" if language == "de" else "en-US-JennyNeural"

    # edge-tts als Subprocess (gibt MP3 auf stdout)
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "edge_tts",
            "--voice", voice,
            "--text", text,
            "--write-media", "-",  # stdout
        ],
        capture_output=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise RuntimeError(f"edge-tts failed: {result.stderr.decode()}")

    return result.stdout


def mp3_to_wav_bytes(mp3_bytes: bytes, target_sr: int = SAMPLE_RATE) -> bytes:
    """Konvertiert MP3-Bytes → WAV-Bytes (16kHz mono)."""
    buf = io.BytesIO(mp3_bytes)
    samples, sr = sf.read(buf, dtype="float64")

    # Mono
    if samples.ndim > 1:
        samples = samples.mean(axis=1)

    # Resample falls nötig
    if sr != target_sr:
        import math
        ratio = target_sr / sr
        new_len = int(len(samples) * ratio)
        samples = np.interp(
            np.linspace(0, len(samples) - 1, new_len),
            np.arange(len(samples)),
            samples,
        )

    # WAV schreiben
    out_buf = io.BytesIO()
    sf.write(out_buf, samples, target_sr, format="WAV", subtype="PCM_16")
    out_buf.seek(0)
    return out_buf.read()


def generate_fallback_wav(text: str, language: str) -> bytes:
    """Fallback: Generiert Sinuston + Stille (für Struktur-Tests)."""
    duration = max(2.0, len(text) * 0.08)  # ~80ms pro Zeichen
    t = np.linspace(0, duration, int(SAMPLE_RATE * duration), endpoint=False)

    # Einfacher Sinuston (440 Hz) mit Fade-in/out
    freq = 440 if language == "de" else 523  # C5 für EN
    audio = np.sin(2 * np.pi * freq * t) * 0.3

    # Fade-in/out (50ms)
    fade_len = int(0.05 * SAMPLE_RATE)
    if fade_len > 0 and len(audio) > 2 * fade_len:
        audio[:fade_len] *= np.linspace(0, 1, fade_len)
        audio[-fade_len:] *= np.linspace(1, 0, fade_len)

    out_buf = io.BytesIO()
    sf.write(out_buf, audio, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    out_buf.seek(0)
    return out_buf.read()


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # TTS-Strategie wählen
    tts_fn = None
    tts_name = None

    # 1. Google Cloud TTS
    try:
        from google.cloud import texttospeech  # noqa: F401
        import os
        if os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            tts_fn = generate_google_tts
            tts_name = "Google Cloud TTS"
    except ImportError:
        pass

    # 2. edge-tts
    if tts_fn is None:
        try:
            result = subprocess.run(
                [sys.executable, "-m", "edge_tts", "--help"],
                capture_output=True,
                timeout=5,
            )
            if result.returncode == 0:
                tts_fn = generate_edge_tts
                tts_name = "edge-tts (kostenlos)"
        except Exception:
            pass

    # 3. Fallback
    if tts_fn is None:
        tts_fn = generate_fallback_wav
        tts_name = "Fallback (Sinuston)"

    print(f"🎤 TTS-Generator: {tts_name}")
    print(f"📁 Output: {OUTPUT_DIR.absolute()}")
    print()

    for sample_id, info in SAMPLES.items():
        out_file = OUTPUT_DIR / f"{sample_id}.wav"
        print(f"  {sample_id}: {info['desc']} ({info['lang']}) ...", end=" ")

        try:
            mp3_bytes = tts_fn(info["text"], info["lang"])
            wav_bytes = mp3_to_wav_bytes(mp3_bytes)
            out_file.write_bytes(wav_bytes)

            # Metadaten ausgeben
            buf = io.BytesIO(wav_bytes)
            samples, sr = sf.read(buf)
            duration = len(samples) / sr
            print(f"✅ {duration:.1f}s")
        except Exception as e:
            print(f"❌ Fehler: {e}")

        time.sleep(0.5)  # Rate-Limit für TTS-APIs

    print(f"\n✅ Fertig: {len(list(OUTPUT_DIR.glob('S*.wav')))} Dateien in {OUTPUT_DIR.absolute()}")


if __name__ == "__main__":
    main()
