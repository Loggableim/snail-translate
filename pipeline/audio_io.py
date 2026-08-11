"""Audio I/O: WAV laden, encode/decode, Playback, Mikrofon-Aufnahme.

Nutzung: soundfile (WAV/FLAC), sounddevice (Playback/Record), numpy.
Kein FFmpeg nötig für WAV.
"""

import io
import numpy as np
import soundfile as sf
import sounddevice as sd


def load_wav(path: str) -> tuple[np.ndarray, int]:
    """Lädt WAV-Datei, gibt (samples, sample_rate) zurück.

    Args:
        path: Pfad zur WAV-Datei.

    Returns:
        Tuple aus (audio_samples als float64 numpy array, sample_rate).
    """
    samples, sr = sf.read(path, dtype="float64")
    # soundfile gibt stereo als (N, 2) zurück → mono konvertieren
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    return samples, sr


def play_audio(pcm: np.ndarray, sample_rate: int = 16000):
    """Spielt PCM numpy array über Lautsprecher ab.

    Args:
        pcm: Audio-Samples als numpy array (float64, [-1, 1]).
        sample_rate: Sample-Rate in Hz (default: 16000).
    """
    sd.play(pcm, samplerate=sample_rate)
    sd.wait()


def record_mic(duration_sec: float, sample_rate: int = 16000) -> np.ndarray:
    """Nimmt Audio vom Mikrofon auf.

    ⚠️ Im Prototyp NICHT genutzt (kein AEC → Feedback-Loop).
    Definiert für spätere Nutzung mit AEC-Prototyp.

    Args:
        duration_sec: Aufnahmedauer in Sekunden.
        sample_rate: Sample-Rate in Hz (default: 16000).

    Returns:
        Audio-Samples als numpy array (float64, [-1, 1]).
    """
    samples = sd.rec(
        int(duration_sec * sample_rate),
        samplerate=sample_rate,
        channels=1,
        dtype="float64",
    )
    sd.wait()
    return samples.flatten()


def encode_wav(audio: np.ndarray, sample_rate: int = 16000) -> bytes:
    """Kodiert numpy array → WAV bytes (für API-Upload).

    Args:
        audio: Audio-Samples als numpy array.
        sample_rate: Sample-Rate in Hz.

    Returns:
        WAV-Datei als bytes.
    """
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format="WAV", subtype="PCM_16")
    buf.seek(0)
    return buf.read()


def mp3_to_pcm(mp3_bytes: bytes) -> np.ndarray:
    """Konvertiert MP3-Bytes → PCM numpy array.

    Nutzt soundfile + io.BytesIO (kein FFmpeg nötig, wenn soundfile
    MP3-Unterstützung hat). Fallback: pydub (braucht FFmpeg).

    Args:
        mp3_bytes: MP3-Datei als bytes.

    Returns:
        PCM-Samples als numpy array (float64, [-1, 1]).
    """
    buf = io.BytesIO(mp3_bytes)
    try:
        samples, _sr = sf.read(buf, dtype="float64")
    except Exception:
        # Fallback: pydub
        try:
            from pydub import AudioSegment
            audio = AudioSegment.from_mp3(io.BytesIO(mp3_bytes))
            samples = np.array(audio.get_array_of_samples(), dtype=np.float64)
            samples /= 32768.0  # int16 → float [-1, 1]
            if audio.channels > 1:
                samples = samples.reshape(-1, audio.channels).mean(axis=1)
        except ImportError:
            raise RuntimeError(
                "Cannot decode MP3: soundfile failed and pydub not installed. "
                "Install pydub + FFmpeg as fallback."
            )
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    return samples


def opus_to_pcm(opus_bytes: bytes) -> np.ndarray:
    """Konvertiert Opus-Bytes → PCM (falls API Opus zurückgibt).

    Args:
        opus_bytes: Opus-codierte Audio-Daten.

    Returns:
        PCM-Samples als numpy array (float64, [-1, 1]).
    """
    buf = io.BytesIO(opus_bytes)
    try:
        samples, _sr = sf.read(buf, dtype="float64")
    except Exception:
        raise RuntimeError(
            "Cannot decode Opus: soundfile does not support Opus. "
            "Install pydub + FFmpeg as fallback."
        )
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    return samples
