# Snail — Pipeline-Prototyp Plan (v2)

> Ziel: Die vollständige Audio-Pipeline (Mikro → VAD → STT → Übersetzung → TTS → Playback) auf **einem Gerät** mit festen API-Keys bauen und messen, ob P50 < 2s erreichbar ist. Kein Worker, kein Auth, kein zweites Gerät — nur die Kern-Pipeline.

---

## 1. Scope

### Was gebaut wird

Ein **Python-CLI-Tool** (`pipeline.py`), das:

1. Eine WAV-Datei lädt (16 kHz mono) — **Datei-Input only, kein Live-Mikrofon im Prototyp**
2. VAD (Silero) anwendet — Stille wegschneiden
3. Sprachsegmente an STT-API sendet (Groq Whisper oder Deepgram, **Batch-Modus**)
4. Transkript an Übersetzungs-API sendet (DeepL)
5. Übersetzung an TTS-API sendet (Google Cloud TTS oder fish.audio)
6. TTS-Audio dekodiert und über Lautsprecher abspielt
7. Jeden Schritt mit Zeitstempeln misst (inkl. Audio-Enkodierung/Dekodierung)

### Was NICHT gebaut wird

- **Kein AEC (Echo Cancellation)** — separater Prototyp (Schritt 3 aus ARCHITEKTUR.md)
- **Kein Live-Mikrofon** — `record_mic()` wird definiert aber im Prototyp nicht genutzt.
  Grund: Ohne AEC entsteht ein Feedback-Loop (Lautsprecher → Mikrofon), sobald TTS-Playback
  läuft. Der Prototyp arbeitet ausschließlich mit WAV-Datei-Input.
- Kein zweites Gerät, kein WebSocket, kein Relay
- Kein Worker, kein Clerk, keine Auth
- Keine Flutter-App — reines Python für schnelle Iteration
- **Kein Streaming** — alle API-Calls sind Batch (Datei hochladen → Ergebnis abwarten).
  Streaming (Teiltranskripte, chunked TTS) ist der nächste Schritt nach Machbarkeits-Validierung.

### Warum Python

- Schnellste Iteration für API-Tests
- `sounddevice`, `silero-vad`, `requests` — alle ausgereift
- Einfaches Timing mit `time.monotonic()`
- Kann später als Referenz für Flutter-Implementierung dienen

### ⚠️ Caveats (was der Prototyp NICHT misst)

1. **Netzwerk-Hops:** Der Prototyp misst 1 Hop (PC → API). Die echte App hat 2 Hops
   (App → Durable Object → API). Erwarteter Mehr-Aufwand: +20–50 ms. Die gemessene
   Latenz ist eine **untere Grenze**, nicht die echte End-to-End-Latenz.
2. **Mobiles Netzwerk:** Der Prototyp läuft auf PC (WiFi/LAN, ~30 ms RTT). Die echte App
   läuft auf Mobilfunk (4G: 200–400 ms RTT). Mobile Latenz muss separat validiert werden.
3. **AEC-Overhead:** AEC + Noise Suppression kosten ~10 ms on-device. Im Prototyp nicht
   enthalten.
4. **Streaming-Optimierung:** Echte Pipeline nutzt Streaming-Translation + Chunked-TTS
   (parallele Pipeline). Der Prototyp ist seriell (Batch). Die gemessene Latenz ist eine
   **obere Grenze für den Batch-Modus** — Streaming wird niedriger sein.

---

## 2. Architektur

```
┌─────────────────────────────────────────────────────────┐
│                    pipeline.py                          │
│                                                         │
│  Input: WAV-Datei (16kHz mono) — kein Live-Mikro        │
│                                                         │
│  [0] load_audio(path) → numpy array                     │
│  [1] VAD (silero) → speech segments                    │
│  [1b] encode_audio → WAV/Opus bytes (für API-Upload)   │
│  [2] STT (Groq/Deepgram, BATCH) → transcript           │
│  [3] MT (DeepL, BATCH) → translation                   │
│  [4] TTS (Google/fish.audio, BATCH) → MP3/WAV bytes    │
│  [4b] decode_audio → PCM (für Playback)               │
│  [5] play_audio(bytes) → Lautsprecher                  │
│                                                         │
│  Output: JSON mit Timing pro Schritt + Gesamtlatenz     │
│  (inkl. t_encode, t_decode)                             │
└─────────────────────────────────────────────────────────┘
```

### Dateistruktur

```
snail/
├── pipeline/
│   ├── pipeline.py          # Haupt-Pipeline
│   ├── vad.py               # Silero VAD Wrapper
│   ├── stt.py               # STT-API-Clients (Groq, Deepgram) — Batch
│   ├── translate.py         # Übersetzungs-API-Client (DeepL)
│   ├── tts.py               # TTS-API-Clients (Google, fish.audio)
│   ├── audio_io.py          # Audio I/O (load, play, encode, decode)
│   ├── benchmark.py         # Benchmark-Runner (misst Latenz, WER)
│   ├── wer.py               # Word Error Rate Berechnung (jiwer)
│   ├── config.py            # API-Keys & Konfiguration (lazy loading)
│   ├── references.json      # Referenz-Transkripte für WER-Messung
│   └── requirements.txt     # Python-Dependencies
├── audio_samples/           # Test-Audio-Dateien (S1–S10)
└── output/                  # Benchmark-Ergebnisse (JSON)
```

---

## 3. Komponenten im Detail

### 3.1 `config.py` — API-Keys & Konfiguration (lazy loading)

```python
import os
from functools import lru_cache

# Pipeline-Konfiguration (statisch)
SOURCE_LANG = "de"
TARGET_LANG = "en"
SAMPLE_RATE = 16000

# API-Keys werden lazy geladen — nur was gebraucht wird
@lru_cache(maxsize=1)
def groq_api_key() -> str:
    key = os.environ.get("SNAIL_GROQ_API_KEY")
    if not key:
        raise RuntimeError("SNAIL_GROQ_API_KEY not set — needed for Free-Tier STT")
    return key

@lru_cache(maxsize=1)
def deepgram_api_key() -> str:
    key = os.environ.get("SNAIL_DEEPGRAM_API_KEY")
    if not key:
        raise RuntimeError("SNAIL_DEEPGRAM_API_KEY not set — needed for Paid-Tier STT")
    return key

@lru_cache(maxsize=1)
def deepl_api_key() -> str:
    key = os.environ.get("SNAIL_DEEPL_API_KEY")
    if not key:
        raise RuntimeError("SNAIL_DEEPL_API_KEY not set — needed for translation")
    return key

@lru_cache(maxsize=1)
def google_credentials_path() -> str:
    path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not path:
        raise RuntimeError(
            "GOOGLE_APPLICATION_CREDENTIALS not set — "
            "needed for Google Cloud TTS. Must point to a Service Account JSON file."
        )
    return path

@lru_cache(maxsize=1)
def fishaudio_api_key() -> str:
    key = os.environ.get("SNAIL_FISHAUDIO_API_KEY")
    if not key:
        raise RuntimeError("SNAIL_FISHAUDIO_API_KEY not set — needed for Paid-Tier TTS")
    return key

def validate_keys_for_tier(tier: str) -> list[str]:
    """Prüft, ob alle für das Tier nötigen Keys vorhanden sind.
    Gibt Liste der fehlenden Keys zurück (leer = alle ok)."""
    missing = []
    if tier == "free":
        for name, getter in [("SNAIL_GROQ_API_KEY", groq_api_key),
                             ("SNAIL_DEEPL_API_KEY", deepl_api_key),
                             ("GOOGLE_APPLICATION_CREDENTIALS", google_credentials_path)]:
            try:
                getter()
            except RuntimeError:
                missing.append(name)
    elif tier == "paid":
        for name, getter in [("SNAIL_DEEPGRAM_API_KEY", deepgram_api_key),
                             ("SNAIL_DEEPL_API_KEY", deepl_api_key),
                             ("SNAIL_FISHAUDIO_API_KEY", fishaudio_api_key)]:
            try:
                getter()
            except RuntimeError:
                missing.append(name)
    return missing
```

> **Änderung v2:** Keys werden lazy geladen (`@lru_cache` + `os.environ.get`).
  Nur die Keys, die für das gewählte Tier nötig sind, werden geprüft.
  Ein fehlender Paid-Tier-Key verhindert nicht den Free-Tier-Benchmark.

### 3.2 `audio_io.py` — Audio I/O

```python
import numpy as np

def load_wav(path: str) -> tuple[np.ndarray, int]:
    """Lädt WAV, gibt (samples, sample_rate) zurück.
    Nutzt soundfile (kein FFmpeg nötig für WAV)."""

def play_audio(pcm: np.ndarray, sample_rate: int = 16000):
    """Spielt PCM numpy array über Lautsprecher ab (sounddevice).
    Kein pyaudio — sounddevice ist zuverlässiger auf Windows."""

def record_mic(duration_sec: float, sample_rate: int = 16000) -> np.ndarray:
    """Nimmt Audio vom Mikrofon auf (sounddevice).
    ⚠️ Im Prototyp NICHT genutzt (kein AEC → Feedback-Loop).
    Definiert für spätere Nutzung mit AEC-Prototyp."""

def encode_wav(audio: np.ndarray, sample_rate: int = 16000) -> bytes:
    """Kodiert numpy array → WAV bytes (für API-Upload).
    soundfile.write zu BytesIO."""

def mp3_to_pcm(mp3_bytes: bytes) -> np.ndarray:
    """Konvertiert MP3-Bytes → PCM numpy array.
    Nutzt soundfile + io.BytesIO (kein FFmpeg nötig).
    Fallback: pydub (braucht FFmpeg)."""

def opus_to_pcm(opus_bytes: bytes) -> np.ndarray:
    """Konvertiert Opus-Bytes → PCM (falls API Opus zurückgibt).
    Nutzt soundfile oder audioread."""
```

**Dependencies:** `soundfile`, `numpy`, `sounddevice`
**Optional:** `pydub` (nur wenn soundfile MP3 nicht liest — braucht FFmpeg)

> **Änderung v2:** `soundfile` statt `pydub` als primäre Library (kein FFmpeg nötig
  für WAV/FLAC). `sounddevice` statt `pyaudio` (zuverlässiger auf Windows).
  `encode_wav()` als explizite Funktion für API-Upload hinzugefügt.

### 3.3 `vad.py` — Silero VAD

```python
import numpy as np

def detect_speech(audio: np.ndarray, sample_rate: int = 16000) -> list[tuple[int, int]]:
    """Gibt Liste von (start_sample, end_sample) für Sprachsegmente zurück.
    Nutzt silero-vad (ONNX-basiert, kein torch nötig).

    Installation: pip install silero-vad onnxruntime
    (silero-vad Package lädt das ONNX-Modell automatisch von GitHub.)
    Fallback: webrtcvad (weniger genau, aber keine Model-Datei nötig)."""

def remove_silence(audio: np.ndarray, segments) -> np.ndarray:
    """Schneidet Stille weg, gibt nur Sprachsegmente zurück."""
```

**Dependencies:** `silero-vad`, `onnxruntime`
**Fallback:** `webrtcvad` (wenn silero-vad auf Windows problematisch)

> **Änderung v2:** Installationsweg spezifiziert (`pip install silero-vad onnxruntime`).
  Fallback `webrtcvad` explizit dokumentiert.

### 3.4 `stt.py` — STT-API-Clients (Batch, nicht Streaming)

```python
from dataclasses import dataclass

@dataclass
class STTResult:
    transcript: str
    latency_ms: float
    api: str  # "groq" | "deepgram"

def transcribe_groq(audio_path: str, api_key: str, language: str = "de") -> STTResult:
    """Groq Whisper API — BATCH-Modus.
    Multipart-Upload der WAV-Datei, wartet auf komplette Transkription.
    ⚠️ KEIN Streaming: Groq liefert das Transkript erst nach kompletter Verarbeitung.
    Latenz hängt von Audiolänge ab (typ. 0.5–3s für 3–15s Audio).
    Rate-Limit: 30 req/min (Free-Tier) — Benchmark muss drosseln."""

def transcribe_deepgram(audio_path: str, api_key: str, language: str = "de") -> STTResult:
    """Deepgram Nova-2 — BATCH-Modus (HTTP POST, nicht WebSocket).
    Sendet WAV als binary body, erhält JSON mit Transkript.
    WebSocket-Streaming ist für später (echtes Streaming-Prototyp)."""
```

**Dependencies:** `requests`

> **Änderung v2:** Beide APIs als **Batch** dokumentiert (nicht "chunked streaming").
  Groq ist Batch — "chunked upload" bedeutet nur multipart-Upload, nicht
  Teiltranskripte. Deepgram nutzt HTTP POST (nicht WebSocket) im Prototyp.
  Rate-Limit (30 req/min) für Groq dokumentiert.

### 3.5 `translate.py` — Übersetzungs-API-Client

```python
from dataclasses import dataclass

@dataclass
class TranslationResult:
    translated_text: str
    latency_ms: float
    api: str  # "deepl_free" | "deepl_pro"

def translate_deepl(
    text: str, api_key: str, source_lang: str, target_lang: str, pro: bool = False
) -> TranslationResult:
    """DeepL API (Free oder Pro).
    Free: api-free.deepl.com — 500k Zeichen/Monat kostenlos.
    Pro: api.deepl.com — bezahlt.
    Batch-Modus: POST mit Text, wartet auf Übersetzung.
    DeepL Free unterstützt: DE, EN, FR, ES, IT, JA, KO, NL, PL, PT, RU, ZH, BG, CS, DA, ET, FI, EL, HU, LT, LV, RO, SK, SL, SV."""
```

**Dependencies:** `requests`

> **Änderung v2:** DeepL Free unterstützte Sprachen dokumentiert (für DE→EN ok).
  Free vs. Pro Endpoint-URL explizit gemacht.

### 3.6 `tts.py` — TTS-API-Clients

```python
from dataclasses import dataclass

@dataclass
class TTSResult:
    audio_bytes: bytes
    format: str  # "mp3" | "wav" | "opus"
    latency_ms: float
    api: str  # "google" | "fishaudio" | "deepgram_aura"

def synthesize_google(text: str, language: str = "en") -> TTSResult:
    """Google Cloud TTS — Standardstimmen.
    ⚠️ Auth via Service Account JSON, NICHT API-Key.
    Setzt GOOGLE_APPLICATION_CREDENTIALS Umgebungsvariable auf Pfad zur JSON-Datei.
    Nutzt google-cloud-texttospeech Library (lädt Credentials automatisch).
    Returns MP3 bytes."""

def synthesize_fishaudio(
    text: str, api_key: str, reference_id: str = "default", model: str = "s2-pro"
) -> TTSResult:
    """fish.audio TTS — s2-pro Modell.
    ⚠️ Batch-Modus: wartet auf kompletten Text, generiert dann MP3.
    KEIN Streaming — Latenz kann 300–500ms betragen.
    Request-Body: reference_id (nicht voice_id), model, text, format=mp3.
    API-Key via Bearer Token im Authorization Header."""

def synthesize_deepgram_aura(text: str, api_key: str, voice: str = "aura-asteria-en") -> TTSResult:
    """Deepgram Aura — Alternative TTS (niedrigere Latenz ~150ms).
    Batch-Modus: HTTP POST, returns MP3 bytes.
    Nur als Fallback/Alternative zu fish.audio."""
```

**Dependencies:** `google-cloud-texttospeech`, `requests`

> **Änderung v2 — kritische Korrekturen:**
> - Google Cloud TTS: Auth via **Service Account JSON**
>   (`GOOGLE_APPLICATION_CREDENTIALS`), nicht API-Key. Signatur geändert.
> - fish.audio: `reference_id` (nicht `voice_id`), `model` als separater Parameter.
> - Deepgram Aura als Alternative hinzugefügt (niedrigere Latenz).
> - Alle als Batch dokumentiert (kein Streaming).

### 3.7 `pipeline.py` — Haupt-Pipeline

```python
from dataclasses import dataclass, asdict
import json, time
from pathlib import Path

@dataclass
class PipelineResult:
    """Ergebnis eines Pipeline-Durchlaufs."""
    input_file: str
    source_lang: str
    target_lang: str
    tier: str  # "free" | "paid"

    # Timing (ms) — alle Schritte inkl. Enkodierung
    t_vad: float
    t_encode: float       # Audio → WAV bytes (für API-Upload)
    t_stt: float          # inkl. Netzwerk (API-Call)
    t_mt: float           # inkl. Netzwerk
    t_tts: float          # inkl. Netzwerk
    t_decode: float       # TTS-Output → PCM (für Playback)
    t_total: float        # Summe aller obigen (ohne load + play)

    # Inhalte
    transcript: str
    translation: str

    # Qualitätsmetriken
    wer: float | None     # Word Error Rate (vs. Referenz), None wenn keine Referenz

    # Metadaten
    stt_api: str
    mt_api: str
    tts_api: str
    timestamp: str

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, ensure_ascii=False)

def run_pipeline(
    audio_path: str,
    tier: str = "free",
    source_lang: str = "de",
    target_lang: str = "en",
    play_output: bool = True,
    reference_transcript: str | None = None,
) -> PipelineResult:
    """
    Führt die vollständige Pipeline aus:
    0. Audio laden
    1. VAD → Sprachsegmente
    1b. Encode → WAV bytes
    2. STT → Transkript (Batch)
    3. MT → Übersetzung (Batch)
    4. TTS → Audio (Batch)
    4b. Decode → PCM
    5. Playback (optional)

    Misst jeden Schritt mit time.monotonic().
    Berechnet WER, falls reference_transcript gegeben.
    """
```

> **Änderung v2:**
> - `t_encode` und `t_decode` als separate Timing-Felder.
> - `wer` als Feld im Result (None wenn keine Referenz).
> - `reference_transcript` als Parameter für WER-Berechnung.
> - `to_json()` für einfache Serialisierung.

### 3.8 `wer.py` — Word Error Rate

```python
from jiwer import wer as jiwer_wer

def calculate_wer(reference: str, hypothesis: str) -> float:
    """Berechnet Word Error Rate (0.0 = perfekt, 1.0 = komplett falsch).
    Nutzt jiwer (Levenshtein-basiert auf Wort-Ebene).
    Normalisiert: lowercase, strip, collapse whitespace."""
    return jiwer_wer(reference.strip().lower(), hypothesis.strip().lower())
```

**Dependencies:** `jiwer`

> **Neu in v2:** WER-Berechnung implementiert. `jiwer` ist Standard für STT-Evaluierung.

### 3.9 `references.json` — Referenz-Transkripte

```json
{
  "S1": "Hallo, wie geht es dir?",
  "S2": "Können Sie mir sagen, wo der nächste Bahnhof ist?",
  "S3": "Ich bin vor zwei Tagen in Berlin angekommen und habe mir das Hotel gesucht, aber die Adresse war falsch.",
  "S4": "Einmal Kaffee, bitte. Mit Milch.",
  "S5": "Can you recommend a good restaurant nearby?",
  "S6": "Also wir waren dann im Museum und da gab es diese Ausstellung über moderne Kunst und das war wirklich sehr interessant besonders der Teil mit den Fotografien.",
  "S7": "Ich brauche ein Ticket für den Airport-Shuttle.",
  "S8": "Guten Tag.",
  "S9": "Ich möchte zahlen.",
  "S10": "Danke schön. Wo ist die Toilette?"
}
```

> **Neu in v2:** Referenz-Transkripte für WER-Messung, passend zu Benchmark-Plan §2.3.

### 3.10 `benchmark.py` — Benchmark-Runner

```python
import json, time
from pathlib import Path
from pipeline import run_pipeline, PipelineResult
from config import validate_keys_for_tier

# Groq Free-Tier: 30 req/min → 2s Pause zwischen Calls
GROQ_RATE_LIMIT_DELAY = 2.0  # Sekunden

def run_benchmarks(
    audio_dir: str = "audio_samples/",
    output_dir: str = "output/",
    references_path: str = "pipeline/references.json",
    tiers: list[str] = ["free", "paid"],
    runs_per_sample: int = 10,
    rate_limit_delay: float = GROQ_RATE_LIMIT_DELAY,
) -> list[PipelineResult]:
    """
    Führt Pipeline für alle Audio-Samples (S1–S10) durch,
    pro Tier, mit n Wiederholungen.
    Speichert Ergebnisse als JSON in output/.

    Drosselt Groq-Calls (30 req/min Free-Tier) mit rate_limit_delay.
    """

    # Keys validieren
    for tier in tiers:
        missing = validate_keys_for_tier(tier)
        if missing:
            print(f"⚠️ Tier '{tier}': fehlende Keys: {missing}")
            print(f"   Überspringe Tier '{tier}'")
            tiers = [t for t in tiers if t != tier]

    # Referenz-Transkripte laden
    references = json.loads(Path(references_path).read_text(encoding="utf-8"))

    results = []
    for tier in tiers:
        for sample_file in sorted(Path(audio_dir).glob("S*.wav")):
            sample_id = sample_file.stem  # "S1", "S2", ...
            ref = references.get(sample_id)
            for run in range(runs_per_sample):
                result = run_pipeline(
                    audio_path=str(sample_file),
                    tier=tier,
                    reference_transcript=ref,
                )
                results.append(result)
                # Rate-Limit für Groq (Free-Tier)
                if tier == "free":
                    time.sleep(rate_limit_delay)
                # JSON speichern
                out_path = Path(output_dir) / f"{sample_id}_{tier}_run{run}.json"
                out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(result.to_json(), encoding="utf-8")

    return results

def compute_stats(results: list[PipelineResult]) -> dict:
    """Berechnet P50, P95, Mean, Min, Max pro Sample und Tier.
    Auch pro Schritt (t_vad, t_stt, t_mt, t_tts)."""

def print_summary(stats: dict):
    """Gibt Zusammenfassung als Tabelle aus."""
```

> **Änderung v2:**
> - Rate-Limit-Handling: `time.sleep(2)` zwischen Groq-Calls.
> - `validate_keys_for_tier()` vor Benchmark — fehlende Keys → Tier überspringen.
> - Referenz-Transkripte geladen, WER pro Run berechnet.
> - `runs_per_sample` kann reduziert werden (z.B. 3 für Paid-Tier, um Kosten zu sparen).

---

## 4. Ablauf

### Phase 1: Setup (1.5–2 Tage)

1. Python-Venv erstellen, Dependencies installieren:
   ```bash
   pip install soundfile numpy sounddevice silero-vad onnxruntime
   pip install requests google-cloud-texttospeech jiwer
   ```
2. API-Keys besorgen:
   - Groq: https://console.groq.com (kostenlos)
   - Deepgram: https://console.deepgram.com (Pay-as-you-go)
   - DeepL Free: https://www.deepl.com/pro-api (500k Zeichen/Monat kostenlos)
   - Google Cloud TTS: https://console.cloud.google.com (Service Account JSON erstellen, 1M Zeichen/Monat kostenlos)
   - fish.audio: https://fish.audio (Pay-as-you-go)
3. Umgebungsvariablen setzen:
   ```bash
   export SNAIL_GROQ_API_KEY="..."
   export SNAIL_DEEPGRAM_API_KEY="..."
   export SNAIL_DEEPL_API_KEY="..."
   export GOOGLE_APPLICATION_CREDENTIALS="/pfad/zu/service-account.json"
   export SNAIL_FISHAUDIO_API_KEY="..."
   ```
4. Audio-Samples S1–S10 erstellen (16 kHz mono WAV):
   - **Empfohlen:** Mit TTS generieren (Google Cloud TTS, deutsche Stimme) — schnell, reproduzierbar
   - **Alternative:** Mit Headset aufnehmen (realistischer, aber 2–4h Aufwand)
   - Format: 16 kHz, mono, 16-bit PCM WAV
   - Inhalte: siehe Benchmark-Plan §2.1 und `references.json`

> **Änderung v2:** Setup-Zeit auf 1.5–2 Tage korrigiert (Audio-Samples + Google
  Service Account + Dependencies). TTS-Generierung für Samples empfohlen.

### Phase 2: Einzelkomponenten (2 Tage)

1. `audio_io.py` — WAV laden, encode/decode, Playback (mit `sounddevice`)
2. `vad.py` — Silero VAD mit Test-Audio validieren
3. `stt.py` — Groq Whisper (Batch) + Deepgram Nova-2 (Batch HTTP POST)
4. `translate.py` — DeepL Free + Pro
5. `tts.py` — Google Cloud TTS (Service Account) + fish.audio (reference_id)
6. `wer.py` — WER-Berechnung mit jiwer testen

Jede Komponente einzeln testen:
```bash
python -m pipeline.audio_io --test
python -m pipeline.vad --input audio_samples/S1.wav
python -m pipeline.stt --api groq --input audio_samples/S1.wav
python -m pipeline.translate --text "Hallo" --source de --target en
python -m pipeline.tts --api google --text "Hello, how are you?"
python -m pipeline.wer --ref "Hallo" --hyp "Hallo"
```

### Phase 3: Pipeline-Integration (1 Tag)

1. `pipeline.py` — Alle Komponenten verketten
2. Manueller Test:
   ```bash
   python pipeline.py --input audio_samples/S1.wav --tier free
   python pipeline.py --input audio_samples/S3.wav --tier paid
   ```
3. Playback testen: Übersetzung hören
4. Timing-Output prüfen: JSON mit `t_vad`, `t_stt`, `t_mt`, `t_tts`, `t_total`

### Phase 4: Benchmark (1.5 Tage)

1. `benchmark.py` — Automatisierte Durchläufe
2. Free-Tier: 10 Samples × 10 Runs = 100 Durchläufe (mit 2s Pause = ~5 min)
3. Paid-Tier: 10 Samples × 3 Runs = 30 Durchläufe (Kosten sparen)
4. Ergebnisse als JSON + Zusammenfassung
5. P50/P95 pro Schritt und pro Tier

> **Änderung v2:** Paid-Tier auf 3 Runs reduziert (Kosten). Benchmark-Zeit auf
  1.5 Tage (Rate-Limit-Drosselung bei Groq).

### Phase 5: Auswertung (0.5 Tage)

1. P50/P95 pro Tier berechnen und ausgeben
2. Bottlenecks identifizieren (welcher Schritt ist am langsamsten?)
3. WER pro Sample auswerten
4. Entscheidung: Pipeline < 2s erreichbar? (ja/nein/mit Einschränkungen)
5. Caveats dokumentieren: gemessene Latenz = untere Grenze (1 Hop, WiFi),
   echte App wird +20–50ms (DO-Relay) + 100–300ms (4G) mehr haben

---

## 5. Erfolgskriterien

| Kriterium | Ziel | Messung |
|-----------|------|---------|
| **P50 Latenz (Free, WiFi)** | < 2s | `benchmark.py` P50 über alle Samples |
| **P50 Latenz (Paid, WiFi)** | < 2s | `benchmark.py` P50 über alle Samples |
| **P95 Latenz (Free, WiFi)** | < 4s | `benchmark.py` P95 |
| **P95 Latenz (Paid, WiFi)** | < 4s | `benchmark.py` P95 |
| **STT-Genauigkeit (WER)** | < 10% (clean Audio) | `wer.py` vs. `references.json` |
| **STT-Genauigkeit (WER, Noise)** | < 20% (S9 mit Hintergrundgeräusch) | `wer.py` |
| **Übersetzung verständlich** | Subjektiv OK | Manuell prüfen |
| **TTS verständlich** | Subjektiv OK | Anhören |

> **⚠️ Wichtig:** Die Latenz-Ziele gelten für **WiFi auf PC**. Die echte App auf
> Mobilfunk wird höhere Latenz haben. Der Prototyp validiert die **Machbarkeit
> der API-Pipeline**, nicht die echte End-to-End-Latenz auf dem Handy.

### Entscheidungsmatrix

| Ergebnis | Aktion |
|----------|--------|
| P50 < 2s, P95 < 4s | ✅ Pipeline funktioniert — weiter mit AEC-Prototyp |
| P50 < 2s, P95 > 4s | ⚠️ Ausreißer untersuchen (Netzwerk? Satzlänge? API-Timeout?) |
| P50 > 2s, P50 < 3s | ⚠️ Bottleneck identifizieren, Streaming-Optimierung probieren |
| P50 > 3s | ❌ API wechseln oder Pipeline grundlegend überdenken |

> **Änderung v2:** Vierte Zeile hinzugefügt (P50 > 3s → grundlegend überdenken).
  WER-Ziel für Noise-Sample (S9) explizit.

---

## 6. Risiken & Fallbacks

| Risiko | Wahrscheinlichkeit | Fallback |
|--------|-------------------|----------|
| **Groq Rate-Limit: 30 req/min (Free)** | Hoch | `time.sleep(2)` zwischen Calls im Benchmark |
| **Groq Whisper zu langsam (Batch)** | Mittel | Deepgram auch für Free-Tier testen (bezahlt, aber schneller) |
| **DeepL Free Rate-Limit (500k Zeichen/Monat)** | Niedrig | Benchmark braucht ~10k Zeichen total — reicht locker |
| **fish.audio Latenz > 500ms** | Mittel | Deepgram Aura als Alternative testen (~150ms) |
| **Silero VAD auf Windows problematisch** | Niedrig | `webrtcvad` als Fallback (weniger genau, aber stabil) |
| **sounddevice auf Windows problematisch** | Niedrig | `pyaudio` als Alternative |
| **Google Service Account Setup fehlerhaft** | Mittel | Dokumentation befolgen, `gcloud auth application-default login` als Alternative |
| **soundfile kann MP3 nicht lesen** | Niedrig | `pydub` + FFmpeg als Fallback |
| **fish.audio: kein Streaming, wartet auf Text** | Hoch (bekannt) | Deepgram Aura testen (niedrigere Latenz, batch) |

> **Änderung v2:** Drei neue Risiken hinzugefügt (Groq Rate-Limit, Google SA Setup,
  fish.audio Streaming). Wahrscheinlichkeiten zugeordnet.

---

## 7. Nächste Schritte nach Pipeline-Prototyp

1. **AEC-Prototyp** (Schritt 3 aus ARCHITEKTUR.md) — Echo Cancellation auf Android testen
2. **Streaming-Pipeline** — Batch → Streaming umstellen (Teiltranskripte, chunked TTS, parallele Pipeline)
3. **Durable Object Prototyp** (Schritt 4) — WebSocket-Relay + API-Key-Injection
4. **Zwei-Geräte-Integration** (Schritt 9) — Pipeline über zwei Geräte

> **Änderung v2:** Streaming-Pipeline als Schritt 2 eingefügt (vor DO-Prototyp).

---

## 8. Benötigte API-Keys & Setup

| API | Umgebungsvariable | Setup | Besorgen unter |
|-----|-------------------|-------|----------------|
| Groq | `SNAIL_GROQ_API_KEY` | API-Key direkt | https://console.groq.com |
| Deepgram | `SNAIL_DEEPGRAM_API_KEY` | API-Key direkt | https://console.deepgram.com |
| DeepL Free | `SNAIL_DEEPL_API_KEY` | DeepL-Auth-Key | https://www.deepl.com/pro-api |
| Google Cloud TTS | `GOOGLE_APPLICATION_CREDENTIALS` | **Service Account JSON-Datei** (Pfad zur Datei) | https://console.cloud.google.com |
| fish.audio | `SNAIL_FISHAUDIO_API_KEY` | API-Key direkt | https://fish.audio |

> **Änderung v2 — kritisch:** Google Cloud TTS braucht **Service Account JSON**
> (Pfad in `GOOGLE_APPLICATION_CREDENTIALS`), nicht einen einfachen API-Key.
> Setup: Google Cloud Console → IAM → Service Accounts → Create → JSON Key herunterladen.

---

## 9. Zeitplan

| Phase | Dauer | Ergebnis |
|-------|-------|----------|
| Setup | 1.5–2 Tage | Keys, Dependencies, Samples (TTS-generiert) |
| Einzelkomponenten | 2 Tage | Jede API einzeln aufrufbar + WER |
| Integration | 1 Tag | `pipeline.py` funktioniert |
| Benchmark | 1.5 Tage | 130 Durchläufe (100 Free + 30 Paid), JSON-Ergebnisse |
| Auswertung | 0.5 Tage | Entscheidung: Pipeline machbar? |
| **Gesamt** | **6.5–7 Tage** | Pipeline-Prototyp abgeschlossen |

> **Änderung v2:** Zeitplan realistischer (6.5–7 statt 5.5 Tage).
  Paid-Tier Runs reduziert (3 statt 10 → 30 statt 100 Calls → Kosten sparen).

---

## 10. Dependencies (`requirements.txt`)

```
# Audio I/O
soundfile>=0.12
numpy>=1.24
sounddevice>=0.4

# VAD
silero-vad>=0.1
onnxruntime>=1.16

# API Clients
requests>=2.31
google-cloud-texttospeech>=2.14

# Quality Metrics
jiwer>=3.0

# Optional Fallbacks
# pydub>=0.25        # nur wenn soundfile MP3 nicht liest (braucht FFmpeg)
# webrtcvad>=2.0     # Fallback für Silero VAD
# pyaudio>=0.2      # Fallback für sounddevice
```

> **Neu in v2:** Komplette `requirements.txt` mit Versionen und Optional-Dependencies.

---

## 11. Änderungsprotokoll (v1 → v2)

| # | Änderung | Begründung |
|---|----------|-----------|
| 1 | Google Cloud TTS: API-Key → Service Account JSON | Google Cloud TTS authentifiziert via OAuth2 Service Account, nicht API-Key |
| 2 | Groq Whisper: "chunked streaming" → "Batch" | Groq ist Batch (multipart upload, wartet auf komplettes Transkript) |
| 3 | Deepgram: WebSocket → HTTP POST (Batch) im Prototyp | Batch ist einfacher, WebSocket für später |
| 4 | `config.py`: eager → lazy loading (`@lru_cache`) | Nur benötigte Keys pro Tier laden, fehlende Keys verhindern nicht anderen Tier |
| 5 | Netzwerk-Caveats hinzugefügt (§1) | Prototyp misst 1 Hop (WiFi), echte App hat 2 Hops (4G) |
| 6 | `t_encode`/`t_decode` als Timing-Felder | Audio-Konvertierung kostet Zeit, muss gemessen werden |
| 7 | `wer.py` + `references.json` hinzugefügt | WER-Erfolgskriterium war definiert aber nicht implementiert |
| 8 | Rate-Limit-Handling im Benchmark (`time.sleep(2)`) | Groq Free: 30 req/min, sonst 429 Errors |
| 9 | Audio-Samples: TTS-Generierung empfohlen | Schneller als aufnehmen, reproduzierbar |
| 10 | `soundfile` statt `pydub` (kein FFmpeg nötig) | Weniger Setup-Aufwand auf Windows |
| 11 | `sounddevice` statt `pyaudio` | Zuverlässiger auf Windows |
| 12 | fish.audio: `voice_id` → `reference_id` | API nutzt `reference_id`, nicht `voice_id` |
| 13 | Deepgram Aura als TTS-Alternative | Niedrigere Latenz (~150ms) als fish.audio (~300–500ms) |
| 14 | Zeitplan: 5.5 → 6.5–7 Tage | Setup und Benchmark brauchen länger (Rate-Limit, SA-Setup) |
| 15 | Paid-Tier Runs: 10 → 3 | Kosten sparen (Deepgram + fish.audio sind bezahlt) |
| 16 | `record_mic()` als definiert aber ungenutzt markiert | Ohne AEC → Feedback-Loop, nur Datei-Input im Prototyp |
| 17 | Streaming-Pipeline als Schritt 2 nach Prototyp | Batch validiert Machbarkeit, Streaming optimiert Latenz |
| 18 | `requirements.txt` mit Versionen | Reproduzierbares Setup |
| 19 | Entscheidungsmatrix: P50 > 3s → "grundlegend überdenken" | Klare Grenze für No-Go |
| 20 | DeepL Free unterstützte Sprachen dokumentiert | Vermeidet Überraschungen bei exotischen Sprachpaaren |