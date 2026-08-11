"""Silero VAD — Voice Activity Detection.

Erkennt Sprachsegmente in einem Audio-Signal.
Nutzung: silero-vad (ONNX-basiert, kein torch nötig).
Fallback: webrtcvad (weniger genau, aber keine Model-Datei nötig).

Modell wird einmal geladen und gecached — kein Cold-Start pro Aufruf.
"""

import numpy as np

# Global cache für das Silero-Modell (einmal laden, wiederverwenden)
_silero_model = None


def _get_silero_model():
    """Lädt das Silero VAD Modell einmal und cached es."""
    global _silero_model
    if _silero_model is None:
        from silero_vad import load_silero_vad
        _silero_model = load_silero_vad(onnx=True)
    return _silero_model


def detect_speech(
    audio: np.ndarray, sample_rate: int = 16000
) -> list[tuple[int, int]]:
    """Gibt Liste von (start_sample, end_sample) für Sprachsegmente zurück.

    Args:
        audio: Audio-Samples als numpy array (float64, [-1, 1]).
        sample_rate: Sample-Rate in Hz (default: 16000).

    Returns:
        Liste von (start_sample, end_sample) — Sample-Indizes.
    """
    try:
        return _detect_speech_silero(audio, sample_rate)
    except Exception:
        return _detect_speech_webrtcvad(audio, sample_rate)


def _detect_speech_silero(
    audio: np.ndarray, sample_rate: int = 16000
) -> list[tuple[int, int]]:
    """Silero VAD (ONNX-basiert, Modell gecached)."""
    from silero_vad import get_speech_timestamps

    audio_f32 = audio.astype(np.float32)
    model = _get_silero_model()
    timestamps = get_speech_timestamps(
        audio_f32, model, return_seconds=False, sampling_rate=sample_rate
    )
    return [(ts["start"], ts["end"]) for ts in timestamps]


def _detect_speech_webrtcvad(
    audio: np.ndarray, sample_rate: int = 16000
) -> list[tuple[int, int]]:
    """webrtcvad Fallback (weniger genau, aber stabil)."""
    import webrtcvad

    vad = webrtcvad.Vad(2)

    if sample_rate not in (8000, 16000, 32000, 48000):
        raise ValueError(f"webrtcvad requires 8/16/32/48 kHz, got {sample_rate}")

    audio_i16 = (audio * 32767).astype(np.int16)
    frame_duration_ms = 30
    frame_size = int(sample_rate * frame_duration_ms / 1000)

    segments = []
    in_speech = False
    speech_start = 0

    for i in range(0, len(audio_i16) - frame_size + 1, frame_size):
        frame = audio_i16[i : i + frame_size].tobytes()
        is_speech = vad.is_speech(frame, sample_rate)

        if is_speech and not in_speech:
            speech_start = i
            in_speech = True
        elif not is_speech and in_speech:
            segments.append((speech_start, i))
            in_speech = False

    if in_speech:
        segments.append((speech_start, len(audio_i16)))

    return segments


def remove_silence(
    audio: np.ndarray, segments: list[tuple[int, int]]
) -> np.ndarray:
    """Schneidet Stille weg, gibt nur Sprachsegmente zurück."""
    if not segments:
        return np.array([], dtype=audio.dtype)
    return np.concatenate([audio[start:end] for start, end in segments])
