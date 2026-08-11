"""Haupt-Pipeline: WAV → VAD → STT → MT → TTS → Playback.

Multi-Provider mit automatischem Fallback:
  STT: Deepgram → Groq
  MT:  Morph → Groq
  TTS: fish.audio → edge-tts
"""

import json
import time
from dataclasses import dataclass, asdict
from pathlib import Path

from pipeline.audio_io import load_wav, encode_wav, mp3_to_pcm, play_audio
from pipeline.vad import detect_speech, remove_silence
from pipeline.stt import transcribe_groq, transcribe_deepgram, transcribe_openai
from pipeline.translate import translate_morph, translate_groq
from pipeline.tts import synthesize_fishaudio, synthesize_fishaudio_stream, synthesize_edge_tts, TTSResult
from pipeline.wer import calculate_wer
from pipeline.config import (
    SOURCE_LANG,
    TARGET_LANG,
    SAMPLE_RATE,
    groq_api_key,
    deepgram_api_key,
    openai_api_key,
    morph_api_key,
    fishaudio_api_key,
)


@dataclass
class PipelineResult:
    """Ergebnis eines Pipeline-Durchlaufs."""

    input_file: str
    source_lang: str
    target_lang: str
    tier: str

    # Timing (ms)
    t_vad: float
    t_encode: float
    t_stt: float
    t_mt: float
    t_tts: float
    t_decode: float
    t_total: float

    # Inhalte
    transcript: str
    translation: str

    # Qualität
    wer: float | None

    # Metadaten
    stt_api: str
    mt_api: str
    tts_api: str
    timestamp: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, ensure_ascii=False)


def _empty_result(
    audio_path: str, tier: str, source_lang: str, target_lang: str,
    t_vad: float, reference_transcript: str | None,
) -> PipelineResult:
    return PipelineResult(
        input_file=Path(audio_path).name,
        source_lang=source_lang, target_lang=target_lang, tier=tier,
        t_vad=t_vad, t_encode=0, t_stt=0, t_mt=0, t_tts=0, t_decode=0,
        t_total=t_vad, transcript="", translation="",
        wer=1.0 if reference_transcript else None,
        stt_api="none", mt_api="none", tts_api="none",
        timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    )


def run_pipeline(
    audio_path: str,
    tier: str = "free",
    source_lang: str = SOURCE_LANG,
    target_lang: str = TARGET_LANG,
    play_output: bool = False,
    reference_transcript: str | None = None,
) -> PipelineResult:
    """Führt die vollständige Pipeline mit Multi-Provider-Fallback aus."""

    # ── 0. Audio laden ──────────────────────────────────────────────
    audio, sr = load_wav(audio_path)
    if sr != SAMPLE_RATE:
        raise ValueError(f"Expected {SAMPLE_RATE} Hz, got {sr}")

    # ── 1. VAD ──────────────────────────────────────────────────────
    t0 = time.monotonic()
    segments = detect_speech(audio, sr)
    speech_audio = remove_silence(audio, segments)
    t1 = time.monotonic()
    t_vad = (t1 - t0) * 1000

    if len(speech_audio) == 0:
        return _empty_result(audio_path, tier, source_lang, target_lang, t_vad, reference_transcript)

    # ── 1b. Encode ─────────────────────────────────────────────────
    t0 = time.monotonic()
    wav_bytes = encode_wav(speech_audio, sr)
    t1 = time.monotonic()
    t_encode = (t1 - t0) * 1000

    tmp_wav = Path(audio_path).with_suffix(".tmp.wav")
    tmp_wav.write_bytes(wav_bytes)

    try:
        # ── 2. STT: Groq → Deepgram → OpenAI Fallback ────────────────
        gq_key = groq_api_key()
        dg_key = deepgram_api_key()
        oa_key = openai_api_key()

        stt_error = None
        if gq_key:
            try:
                stt_result = transcribe_groq(str(tmp_wav), gq_key, source_lang)
            except Exception as e:
                stt_error = e
                if dg_key:
                    try:
                        stt_result = transcribe_deepgram(str(tmp_wav), dg_key, source_lang)
                    except Exception as e2:
                        stt_error = e2
                        if oa_key:
                            stt_result = transcribe_openai(str(tmp_wav), oa_key, source_lang)
                        else:
                            raise RuntimeError(f"All STT providers failed. Last error: {stt_error}")
                elif oa_key:
                    try:
                        stt_result = transcribe_openai(str(tmp_wav), oa_key, source_lang)
                    except Exception as e2:
                        raise RuntimeError(f"All STT providers failed. Last error: {e2}")
                else:
                    raise RuntimeError(f"STT failed and no fallback available. Error: {stt_error}")
        elif dg_key:
            try:
                stt_result = transcribe_deepgram(str(tmp_wav), dg_key, source_lang)
            except Exception as e:
                if oa_key:
                    stt_result = transcribe_openai(str(tmp_wav), oa_key, source_lang)
                else:
                    raise RuntimeError(f"STT failed and no fallback available. Error: {e}")
        elif oa_key:
            stt_result = transcribe_openai(str(tmp_wav), oa_key, source_lang)
        else:
            raise RuntimeError("No STT provider available (set SNAIL_GROQ_API_KEY, SNAIL_DEEPGRAM_API_KEY, or SNAIL_OPENAI_API_KEY)")

        transcript = stt_result.transcript

        # ── 3. MT: Groq → Morph Fallback ───────────────────────────
        t0 = time.monotonic()

        if gq_key:
            try:
                mt_result = translate_groq(transcript, gq_key, source_lang, target_lang)
            except Exception:
                mp_key = morph_api_key()
                if mp_key:
                    mt_result = translate_morph(transcript, mp_key, source_lang, target_lang)
                else:
                    raise
        else:
            mp_key = morph_api_key()
            if mp_key:
                mt_result = translate_morph(transcript, mp_key, source_lang, target_lang)
            else:
                raise RuntimeError("No MT provider available (set SNAIL_GROQ_API_KEY or SNAIL_MORPH_API_KEY)")

        t1 = time.monotonic()
        t_mt = (t1 - t0) * 1000
        translation = mt_result.translated_text

        # ── 4. TTS: fish.audio Streaming → edge-tts Fallback ────────
        t0 = time.monotonic()
        fish_key = fishaudio_api_key()
        if fish_key:
            try:
                ttfa, audio_bytes = synthesize_fishaudio_stream(translation, fish_key)
                tts_result = TTSResult(
                    audio_bytes=audio_bytes,
                    format="mp3",
                    latency_ms=ttfa,
                    api="fishaudio_stream",
                )
            except Exception:
                tts_result = synthesize_edge_tts(translation, target_lang)
        else:
            tts_result = synthesize_edge_tts(translation, target_lang)
        t1 = time.monotonic()
        t_tts = tts_result.latency_ms  # Time-to-first-audio

        # ── 4b. Decode ─────────────────────────────────────────────
        t0 = time.monotonic()
        pcm = mp3_to_pcm(tts_result.audio_bytes)
        t1 = time.monotonic()
        t_decode = (t1 - t0) * 1000

        # ── 5. Playback (optional) ──────────────────────────────────
        if play_output:
            play_audio(pcm, SAMPLE_RATE)

        # ── WER ────────────────────────────────────────────────────
        wer = None
        if reference_transcript:
            wer = calculate_wer(reference_transcript, transcript)

        t_total = t_vad + t_encode + stt_result.latency_ms + t_mt + t_tts + t_decode

        return PipelineResult(
            input_file=Path(audio_path).name,
            source_lang=source_lang, target_lang=target_lang, tier=tier,
            t_vad=t_vad, t_encode=t_encode,
            t_stt=stt_result.latency_ms, t_mt=t_mt, t_tts=t_tts, t_decode=t_decode,
            t_total=t_total, transcript=transcript, translation=translation,
            wer=wer,
            stt_api=stt_result.api, mt_api=mt_result.api, tts_api=tts_result.api,
            timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        )

    finally:
        if tmp_wav.exists():
            tmp_wav.unlink()


# ── CLI ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Snail Pipeline")
    parser.add_argument("--input", required=True, help="WAV-Datei (16kHz mono)")
    parser.add_argument("--tier", choices=["free", "paid"], default="free")
    parser.add_argument("--source", default=SOURCE_LANG)
    parser.add_argument("--target", default=TARGET_LANG)
    parser.add_argument("--play", action="store_true")
    parser.add_argument("--ref", default=None, help="Referenz-Transkript für WER")

    args = parser.parse_args()
    result = run_pipeline(
        audio_path=args.input, tier=args.tier,
        source_lang=args.source, target_lang=args.target,
        play_output=args.play, reference_transcript=args.ref,
    )
    print(result.to_json())
