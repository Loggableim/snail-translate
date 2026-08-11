"""Streaming-Pipeline: Audio-Chunks → STT → MT → TTS (parallel, streaming).

Im Gegensatz zur Batch-Pipeline (wartet auf komplette STT → dann MT → dann TTS)
arbeitet die Streaming-Pipeline mit Satz-Chunks und fish.audio HTTP-Streaming.

Pipeline:
  1. Audio in Satz-Chunks splitten (Pausen-Heuristik)
  2. Pro Chunk: STT (Groq) → MT (Groq) → TTS (fish.audio streaming)
  3. Time-to-First-Audio (TTFA) messen statt Gesamtlatenz
"""

import json
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import numpy as np

from pipeline.audio_io import load_wav, encode_wav, mp3_to_pcm, play_audio
from pipeline.vad import detect_speech, remove_silence
from pipeline.sentence_boundary import split_at_pauses
from pipeline.stt import transcribe_groq
from pipeline.translate import translate_groq
from pipeline.tts import synthesize_fishaudio_stream, synthesize_edge_tts
from pipeline.wer import calculate_wer
from pipeline.config import (
    SOURCE_LANG, TARGET_LANG, SAMPLE_RATE,
    groq_api_key, fishaudio_api_key,
)


@dataclass
class StreamingResult:
    """Ergebnis eines Streaming-Pipeline-Durchlaufs."""

    input_file: str
    source_lang: str
    target_lang: str

    # Streaming-Metriken
    num_chunks: int
    ttfa_ms: float          # Time-to-First-Audio (erster Chunk)
    total_audio_ms: float    # Gesamtdauer des generierten Audios
    total_pipeline_ms: float  # Gesamtzeit bis letzter Chunk fertig

    # Pro-Chunk-Details
    chunk_timings: list[dict]

    # Qualität
    transcript: str
    translation: str
    wer: float | None

    # Metadaten
    stt_api: str
    mt_api: str
    tts_api: str
    timestamp: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, ensure_ascii=False)


def run_streaming_pipeline(
    audio_path: str,
    source_lang: str = SOURCE_LANG,
    target_lang: str = TARGET_LANG,
    play_output: bool = False,
    reference_transcript: str | None = None,
) -> StreamingResult:
    """Führt die Streaming-Pipeline aus.

    Args:
        audio_path: Pfad zur WAV-Datei.
        source_lang: Quellsprache.
        target_lang: Zielsprache.
        play_output: True um Audio abzuspielen.
        reference_transcript: Referenz für WER.

    Returns:
        StreamingResult mit TTFA und Chunk-Timings.
    """
    gq_key = groq_api_key()
    if not gq_key:
        raise RuntimeError("SNAIL_GROQ_API_KEY required for streaming pipeline")

    fish_key = fishaudio_api_key()

    # ── 0. Audio laden + VAD ────────────────────────────────────────
    audio, sr = load_wav(audio_path)
    if sr != SAMPLE_RATE:
        raise ValueError(f"Expected {SAMPLE_RATE} Hz, got {sr}")

    segments = detect_speech(audio, sr)
    speech_audio = remove_silence(audio, segments)

    if len(speech_audio) == 0:
        return StreamingResult(
            input_file=Path(audio_path).name,
            source_lang=source_lang, target_lang=target_lang,
            num_chunks=0, ttfa_ms=0, total_audio_ms=0, total_pipeline_ms=0,
            chunk_timings=[], transcript="", translation="",
            wer=1.0 if reference_transcript else None,
            stt_api="none", mt_api="none", tts_api="none",
            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        )

    # ── 1. In Satz-Chunks splitten ──────────────────────────────────
    chunks = split_at_pauses(speech_audio, sr, min_pause_ms=400, min_speech_ms=300)
    print(f"  📦 {len(chunks)} Satz-Chunks aus {len(speech_audio)/sr:.1f}s Audio")

    # ── 2. Pro Chunk: STT → MT → TTS (streaming) ────────────────────
    pipeline_start = time.monotonic()
    first_audio_time = None
    all_transcripts = []
    all_translations = []
    all_audio = []
    chunk_timings = []

    for i, chunk in enumerate(chunks):
        chunk_start = time.monotonic()

        # 2a. Encode
        wav_bytes = encode_wav(chunk, sr)
        tmp_wav = Path(audio_path).with_suffix(f".chunk{i}.wav")
        tmp_wav.write_bytes(wav_bytes)

        try:
            # 2b. STT
            stt_t0 = time.monotonic()
            stt_result = transcribe_groq(str(tmp_wav), gq_key, source_lang)
            stt_t1 = time.monotonic()
            transcript = stt_result.transcript
            all_transcripts.append(transcript)

            # 2c. MT
            mt_t0 = time.monotonic()
            mt_result = translate_groq(transcript, gq_key, source_lang, target_lang)
            mt_t1 = time.monotonic()
            translation = mt_result.translated_text
            all_translations.append(translation)

            # 2d. TTS (streaming)
            tts_t0 = time.monotonic()
            if fish_key:
                try:
                    ttfa, audio_bytes = synthesize_fishaudio_stream(translation, fish_key)
                    tts_api = "fishaudio_stream"
                except Exception:
                    tts_result = synthesize_edge_tts(translation, target_lang)
                    ttfa = tts_result.latency_ms
                    audio_bytes = tts_result.audio_bytes
                    tts_api = "edge_tts"
            else:
                tts_result = synthesize_edge_tts(translation, target_lang)
                ttfa = tts_result.latency_ms
                audio_bytes = tts_result.audio_bytes
                tts_api = "edge_tts"

            tts_t1 = time.monotonic()

            if first_audio_time is None:
                first_audio_time = tts_t0 + (ttfa / 1000)

            all_audio.append(audio_bytes)

            chunk_end = time.monotonic()
            chunk_timings.append({
                "chunk": i,
                "duration_ms": len(chunk) / sr * 1000,
                "transcript": transcript,
                "translation": translation,
                "t_stt_ms": (stt_t1 - stt_t0) * 1000,
                "t_mt_ms": (mt_t1 - mt_t0) * 1000,
                "t_tts_ms": (tts_t1 - tts_t0) * 1000,
                "ttfa_ms": ttfa,
                "t_total_ms": (chunk_end - chunk_start) * 1000,
            })

        finally:
            if tmp_wav.exists():
                tmp_wav.unlink()

    pipeline_end = time.monotonic()

    # ── 3. Metriken ──────────────────────────────────────────────────
    ttfa = (first_audio_time - pipeline_start) * 1000 if first_audio_time else 0
    total_pipeline_ms = (pipeline_end - pipeline_start) * 1000

    full_transcript = " ".join(all_transcripts)
    full_translation = " ".join(all_translations)

    # WER
    wer = None
    if reference_transcript:
        wer = calculate_wer(reference_transcript, full_transcript)

    # ── 4. Playback (optional) ───────────────────────────────────────
    if play_output and all_audio:
        all_pcm = []
        for ab in all_audio:
            try:
                all_pcm.append(mp3_to_pcm(ab))
            except Exception:
                pass
        if all_pcm:
            combined = np.concatenate(all_pcm)
            play_audio(combined, SAMPLE_RATE)

    return StreamingResult(
        input_file=Path(audio_path).name,
        source_lang=source_lang, target_lang=target_lang,
        num_chunks=len(chunks),
        ttfa_ms=ttfa,
        total_audio_ms=sum(len(ab) for ab in all_audio) / 1000,  # rough
        total_pipeline_ms=total_pipeline_ms,
        chunk_timings=chunk_timings,
        transcript=full_transcript,
        translation=full_translation,
        wer=wer,
        stt_api="groq", mt_api="groq", tts_api=tts_api if all_audio else "none",
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    )


# ── CLI ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Snail Streaming Pipeline")
    parser.add_argument("--input", required=True, help="WAV-Datei")
    parser.add_argument("--source", default=SOURCE_LANG)
    parser.add_argument("--target", default=TARGET_LANG)
    parser.add_argument("--play", action="store_true")
    parser.add_argument("--ref", default=None)

    args = parser.parse_args()
    result = run_streaming_pipeline(
        audio_path=args.input,
        source_lang=args.source, target_lang=args.target,
        play_output=args.play, reference_transcript=args.ref,
    )
    print(result.to_json())
