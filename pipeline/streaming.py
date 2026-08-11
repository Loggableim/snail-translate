"""Streaming-Pipeline: Satzgrenzen-Heuristik + parallele Chunk-Verarbeitung.

Statt auf komplette STT zu warten, wird das Audio an Pausen > 500ms
in Chunks gesplittet. Jeder Chunk durchläuft STT→MT→TTS parallel
zum nächsten Chunk. fish.audio Streaming-TTS liefert erste Audio-Bytes
nach ~450ms (TTFA).

Batch (M0):  Audio → VAD → STT → MT → TTS  (seriell)
Stream (M2): Audio → VAD → [Chunk1: STT→MT→TTS]
                          [Chunk2: STT→MT→TTS]  (parallel)
                          [Chunk3: STT→MT→TTS]

Erwartete Latenz-Reduktion: 300–500ms (TTS startet früher, MT parallel)
"""

import concurrent.futures
import json
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np

from pipeline.audio_io import load_wav, encode_wav, mp3_to_pcm, play_audio
from pipeline.vad import detect_speech, remove_silence
from pipeline.stt import transcribe_groq
from pipeline.translate import translate_groq
from pipeline.tts import synthesize_fishaudio_stream, synthesize_edge_tts
from pipeline.wer import calculate_wer
from pipeline.config import (
    SOURCE_LANG,
    TARGET_LANG,
    SAMPLE_RATE,
    groq_api_key,
    fishaudio_api_key,
)


# ── Satzgrenzen-Heuristik ─────────────────────────────────────────────

def split_at_pauses(
    audio: np.ndarray,
    sample_rate: int = SAMPLE_RATE,
    min_pause_ms: int = 400,
    min_chunk_ms: int = 500,
    max_chunk_ms: int = 8000,
) -> list[np.ndarray]:
    """Splittet Audio an Pausen (Energie unter Schwellwert für min_pause_ms).

    Args:
        audio: Audio-Samples.
        sample_rate: Sample-Rate.
        min_pause_ms: Minimale Pausendauer für Split (ms).
        min_chunk_ms: Minimale Chunk-Länge (kürzere werden mit Nachbar fusioniert).
        max_chunk_ms: Maximale Chunk-Länge (längere werden erzwungen gesplittet).

    Returns:
        Liste von Audio-Chunks.
    """
    if len(audio) == 0:
        return []

    # Energie berechnen (RMS über 20ms Fenster)
    window_ms = 20
    window_samples = int(sample_rate * window_ms / 1000)
    hop_samples = window_samples // 2

    energy = []
    for i in range(0, len(audio) - window_samples + 1, hop_samples):
        frame = audio[i : i + window_samples]
        rms = np.sqrt(np.mean(frame**2))
        energy.append(rms)

    energy = np.array(energy)

    # Schwellwert: Median-Energie * 0.3 (Pausen = deutlich unter Median)
    threshold = np.median(energy) * 0.3

    # Pausen finden
    min_pause_frames = int(min_pause_ms / (hop_samples / sample_rate * 1000))
    is_silence = energy < threshold

    # Splittpunkte: Übergänge silence→speech
    split_samples = []
    in_silence = True
    silence_start = 0

    for i, silent in enumerate(is_silence):
        sample_pos = i * hop_samples
        if silent and not in_silence:
            silence_start = sample_pos
            in_silence = True
        elif not silent and in_silence:
            pause_duration = sample_pos - silence_start
            if pause_duration >= min_pause_ms * sample_rate / 1000:
                split_samples.append(silence_start + pause_duration // 2)
            in_silence = False

    # Chunks bilden
    if not split_samples:
        return [audio]

    chunks = []
    prev = 0
    for split in split_samples:
        chunk = audio[prev:split]
        if len(chunk) > 0:
            chunks.append(chunk)
        prev = split
    # Letzter Chunk
    if prev < len(audio):
        chunks.append(audio[prev:])

    # Fusioniere zu kurze Chunks
    min_chunk_samples = int(min_chunk_ms * sample_rate / 1000)
    merged = []
    buffer = np.array([], dtype=audio.dtype)

    for chunk in chunks:
        buffer = np.concatenate([buffer, chunk])
        if len(buffer) >= min_chunk_samples:
            merged.append(buffer)
            buffer = np.array([], dtype=audio.dtype)

    if len(buffer) > 0:
        if merged:
            merged[-1] = np.concatenate([merged[-1], buffer])
        else:
            merged.append(buffer)

    # Erzwungener Split für zu lange Chunks
    max_chunk_samples = int(max_chunk_ms * sample_rate / 1000)
    final = []
    for chunk in merged:
        while len(chunk) > max_chunk_samples:
            final.append(chunk[:max_chunk_samples])
            chunk = chunk[max_chunk_samples:]
        if len(chunk) > 0:
            final.append(chunk)

    return final if final else [audio]


# ── Chunk-Pipeline (einzelner Chunk) ──────────────────────────────────

def process_chunk(
    chunk: np.ndarray,
    source_lang: str,
    target_lang: str,
    groq_key: str,
    fish_key: str | None,
    chunk_idx: int,
) -> dict:
    """Verarbeitet einen Audio-Chunk: STT → MT → TTS.

    Returns:
        Dict mit transcript, translation, audio_bytes, timings.
    """
    result = {
        "chunk_idx": chunk_idx,
        "transcript": "",
        "translation": "",
        "audio_bytes": b"",
        "t_stt": 0.0,
        "t_mt": 0.0,
        "t_tts": 0.0,
        "error": None,
    }

    try:
        # Encode
        wav_bytes = encode_wav(chunk, SAMPLE_RATE)

        # STT
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(wav_bytes)
            tmp_path = f.name
        stt_result = transcribe_groq(tmp_path, groq_key, source_lang)
        Path(tmp_path).unlink()
        result["t_stt"] = stt_result.latency_ms
        result["transcript"] = stt_result.transcript

        if not result["transcript"].strip():
            return result

        # MT
        t0 = time.monotonic()
        mt_result = translate_groq(
            result["transcript"], groq_key, source_lang, target_lang
        )
        result["t_mt"] = mt_result.latency_ms
        result["translation"] = mt_result.translated_text

        # TTS
        t0 = time.monotonic()
        if fish_key:
            try:
                ttfa, audio_bytes = synthesize_fishaudio_stream(
                    result["translation"], fish_key
                )
                result["t_tts"] = ttfa
                result["audio_bytes"] = audio_bytes
            except Exception:
                tts_result = synthesize_edge_tts(result["translation"], target_lang)
                result["t_tts"] = tts_result.latency_ms
                result["audio_bytes"] = tts_result.audio_bytes
        else:
            tts_result = synthesize_edge_tts(result["translation"], target_lang)
            result["t_tts"] = tts_result.latency_ms
            result["audio_bytes"] = tts_result.audio_bytes

    except Exception as e:
        result["error"] = str(e)

    return result


# ── Streaming-Pipeline ────────────────────────────────────────────────

@dataclass
class StreamingResult:
    input_file: str
    source_lang: str
    target_lang: str
    num_chunks: int

    # Latenz: Zeit vom Pipeline-Start bis erstes TTS-Audio
    time_to_first_audio_ms: float
    # Latenz: Zeit bis alle Chunks verarbeitet sind
    total_time_ms: float

    # Pro-Chunk-Details
    chunks: list[dict]

    # Vergleichswerte
    batch_p50_ms: float | None

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, ensure_ascii=False)


def run_streaming_pipeline(
    audio_path: str,
    source_lang: str = SOURCE_LANG,
    target_lang: str = TARGET_LANG,
    play_output: bool = False,
    reference_transcript: str | None = None,
    max_workers: int = 3,
) -> StreamingResult:
    """Führt die Streaming-Pipeline aus.

    1. Audio laden + VAD
    2. An Pausen in Chunks splitten
    3. Chunks parallel verarbeiten (STT→MT→TTS)
    4. Erste TTS-Audio-Bytes messen (TTFA)

    Args:
        audio_path: Pfad zur WAV-Datei.
        source_lang: Quellsprache.
        target_lang: Zielsprache.
        play_output: True um Audio abzuspielen.
        reference_transcript: Für WER (nicht genutzt in Streaming).
        max_workers: Max parallele Chunks.

    Returns:
        StreamingResult mit Latenz-Metriken.
    """
    groq_key = groq_api_key()
    fish_key = fishaudio_api_key()

    if not groq_key:
        raise RuntimeError("SNAIL_GROQ_API_KEY required for streaming pipeline")

    # 0. Audio laden
    audio, sr = load_wav(audio_path)
    if sr != SAMPLE_RATE:
        raise ValueError(f"Expected {SAMPLE_RATE} Hz, got {sr}")

    # 1. VAD
    segments = detect_speech(audio, sr)
    speech = remove_silence(audio, segments)

    if len(speech) == 0:
        return StreamingResult(
            input_file=Path(audio_path).name,
            source_lang=source_lang,
            target_lang=target_lang,
            num_chunks=0,
            time_to_first_audio_ms=0,
            total_time_ms=0,
            chunks=[],
            batch_p50_ms=None,
        )

    # 2. An Pausen splitten
    chunks = split_at_pauses(speech, sr)

    pipeline_start = time.monotonic()
    first_audio_time = None

    # 3. Chunks parallel verarbeiten
    chunk_results = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {}
        for i, chunk in enumerate(chunks):
            future = executor.submit(
                process_chunk,
                chunk, source_lang, target_lang, groq_key, fish_key, i,
            )
            futures[future] = i

        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            chunk_results.append(result)

            # Track first audio
            if result["audio_bytes"] and first_audio_time is None:
                first_audio_time = time.monotonic()

    # Sortiere nach chunk_idx
    chunk_results.sort(key=lambda r: r["chunk_idx"])

    total_time = (time.monotonic() - pipeline_start) * 1000
    ttfa = (first_audio_time - pipeline_start) * 1000 if first_audio_time else total_time

    # 4. Playback (optional)
    if play_output:
        all_audio = b"".join(
            r["audio_bytes"] for r in chunk_results if r["audio_bytes"]
        )
        if all_audio:
            pcm = mp3_to_pcm(all_audio)
            play_audio(pcm, SAMPLE_RATE)

    return StreamingResult(
        input_file=Path(audio_path).name,
        source_lang=source_lang,
        target_lang=target_lang,
        num_chunks=len(chunks),
        time_to_first_audio_ms=ttfa,
        total_time_ms=total_time,
        chunks=chunk_results,
        batch_p50_ms=None,
    )


# ── CLI ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Snail Streaming Pipeline")
    parser.add_argument("--input", required=True, help="WAV-Datei")
    parser.add_argument("--source", default=SOURCE_LANG)
    parser.add_argument("--target", default=TARGET_LANG)
    parser.add_argument("--play", action="store_true")
    parser.add_argument("--workers", type=int, default=3)

    args = parser.parse_args()
    result = run_streaming_pipeline(
        audio_path=args.input,
        source_lang=args.source,
        target_lang=args.target,
        play_output=args.play,
        max_workers=args.workers,
    )
    print(result.to_json())
