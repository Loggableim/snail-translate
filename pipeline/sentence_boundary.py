"""Satzgrenzen-Erkennung (Sentence Boundary Detection).

Erkennt Satzgrenzen im Audio anhand von Pausen.
Für Streaming-Pipeline: Audio in Chunks splitten, die einzeln
durch STT→MT→TTS gejagt werden.
"""

import numpy as np


def split_at_pauses(
    audio: np.ndarray,
    sample_rate: int = 16000,
    min_pause_ms: int = 400,
    min_speech_ms: int = 300,
) -> list[np.ndarray]:
    """Teilt Audio an Pausen in Satz-Chunks.

    Algorithmus:
    1. Energie-Schwellwert berechnen (RMS-basiert)
    2. Segmente mit Energie > Schwelle = Sprache
    3. Pausen > min_pause_ms trennen Chunks
    4. Chunks < min_speech_ms verwerfen (kein einzelner Buchstabe)

    Args:
        audio: Audio-Samples (float64, [-1, 1]).
        sample_rate: Sample-Rate in Hz.
        min_pause_ms: Minimale Pause für Satzgrenze (default: 400ms).
        min_speech_ms: Minimale Sprachdauer pro Chunk (default: 300ms).

    Returns:
        Liste von Audio-Chunks (numpy arrays).
    """
    if len(audio) == 0:
        return []

    # RMS-Energie in 20ms-Fenstern
    frame_ms = 20
    frame_samples = int(sample_rate * frame_ms / 1000)
    n_frames = len(audio) // frame_samples

    if n_frames < 2:
        return [audio]

    energy = np.array([
        np.sqrt(np.mean(audio[i * frame_samples:(i + 1) * frame_samples] ** 2))
        for i in range(n_frames)
    ])

    # Dynamischer Schwellwert: 30% der mittleren Energie
    threshold = np.mean(energy) * 0.3

    # Sprache/Schweigen pro Frame
    is_speech = energy > threshold

    # Pausen finden (aufeinanderfolgende Schweigen-Frames)
    min_pause_frames = int(min_pause_ms / frame_ms)
    min_speech_frames = int(min_speech_ms / frame_ms)

    chunks = []
    chunk_start = None

    for i in range(len(is_speech)):
        if is_speech[i] and chunk_start is None:
            chunk_start = i
        elif not is_speech[i] and chunk_start is not None:
            # Prüfe ob Pause lang genug
            pause_len = 1
            while i + pause_len < len(is_speech) and not is_speech[i + pause_len]:
                pause_len += 1

            if pause_len >= min_pause_frames:
                chunk_end = i
                chunk_frames = chunk_end - chunk_start
                if chunk_frames >= min_speech_frames:
                    start_sample = chunk_start * frame_samples
                    end_sample = chunk_end * frame_samples
                    chunks.append(audio[start_sample:end_sample])
                chunk_start = None

    # Letzter Chunk
    if chunk_start is not None:
        chunk_frames = n_frames - chunk_start
        if chunk_frames >= min_speech_frames:
            start_sample = chunk_start * frame_samples
            chunks.append(audio[start_sample:])

    # Fallback: wenn keine Pausen erkannt, ganzes Audio als ein Chunk
    if not chunks:
        chunks = [audio]

    return chunks


def split_at_silence(
    audio: np.ndarray,
    sample_rate: int = 16000,
    max_chunk_ms: int = 5000,
    min_chunk_ms: int = 500,
) -> list[np.ndarray]:
    """Alternative: Teilt Audio in gleichmäßige Chunks an Stille-Grenzen.

    Args:
        audio: Audio-Samples.
        sample_rate: Sample-Rate.
        max_chunk_ms: Maximale Chunk-Länge (default: 5000ms).
        min_chunk_ms: Minimale Chunk-Länge (default: 500ms).

    Returns:
        Liste von Audio-Chunks.
    """
    max_samples = int(sample_rate * max_chunk_ms / 1000)
    min_samples = int(sample_rate * min_chunk_ms / 1000)

    chunks = []
    pos = 0

    while pos < len(audio):
        end = min(pos + max_samples, len(audio))
        chunk = audio[pos:end]

        # Nur behalten wenn lang genug
        if len(chunk) >= min_samples:
            chunks.append(chunk)

        pos = end

    return chunks if chunks else [audio]
