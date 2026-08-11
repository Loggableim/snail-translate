# Snail — API-Benchmark-Plan

> Ziel: Validieren, ob die gewählten APIs das Latenz-Budget von P50 < 2s,
> P95 < 4s (End-to-End, eine Richtung) einhalten können. Jede API wird
> einzeln und in der kombinierten Pipeline gemessen — unter WiFi und 4G.

---

## 1. Zu testende APIs

### 1.1 STT (Speech-to-Text)

| API | Tier | Modus | Endpoint | Auth |
|-----|------|-------|----------|------|
| **Groq Whisper** | Free | Streaming (chunked) | `https://api.groq.com/openai/v1/audio/transcriptions` | Bearer Token |
| **Deepgram Nova-2** | Paid | Streaming (WebSocket) | `wss://api.deepgram.com/v1/listen` | Basic Auth (API-Key:pass) |

### 1.2 Übersetzung (MT)

| API | Tier | Modus | Endpoint | Auth |
|-----|------|-------|----------|------|
| **DeepL Free** | Free | Batch (POST) | `https://api-free.deepl.com/v2/translate` | DeepL-Auth-Key |
| **DeepL Pro** | Paid | Batch (POST) | `https://api.deepl.com/v2/translate` | DeepL-Auth-Key |

> DeepL hat keine offizielle Streaming-API. Die „Streaming"-Übersetzung
> erfolgt durch wiederholte Batch-Calls mit inkrementellen Teiltranskripten.
> Das muss im Benchmark abgebildet werden: Mehrere kurze Calls vs. ein
> langer Call.

### 1.3 TTS (Text-to-Speech)

| API | Tier | Modus | Endpoint | Auth |
|-----|------|-------|----------|------|
| **Google Cloud TTS** | Free | Batch (POST) | `https://texttospeech.googleapis.com/v1/text:synthesize` | API-Key |
| **fish.audio** | Paid | Batch (POST) | `https://api.fish.audio/v1/tts` | Bearer Token |
| **Deepgram Aura** | Paid (alt.) | Batch (POST) | `https://api.deepgram.com/v1/speak` | Basic Auth |

> Deepgram Aura wird als Alternative zu fish.audio getestet, da sie
> niedrigere Latenz verspricht (~150ms vs. ~300–500ms).

### 1.4 Durable Object (Relay-Overhead)

| Komponente | Messung |
|-----------|---------|
| WebSocket-Verbindungsaufbau | Time-to-Connect |
| Audio-Roundtrip (App → DO → App) | Latenz-Overhead |
| API-Key-Injection + API-Weiterleitung | Zusätzliche Latenz vs. Direkt-Call |

---

## 2. Audio-Samples

### 2.1 Sample-Set

Alle Samples sind **16 kHz, mono, 16-bit PCM** (Snail-Format). Codiert als
WAV (für API-Kompatibilität) und Opus (für Transport).

| ID | Sprache | Länge | Inhalt | Zweck |
|----|---------|-------|--------|-------|
| **S1** | DE | 3s | „Hallo, wie geht es dir?" (kurz, einfach) | Best-Case-Latenz |
| **S2** | DE | 8s | „Können Sie mir sagen, wo der nächste Bahnhof ist?" (mittel, Reise) | Realistischer Satz |
| **S3** | DE | 15s | „Ich bin vor zwei Tagen in Berlin angekommen und habe mir das Hotel gesucht, aber die Adresse war falsch." (lang, komplex) | Worst-Case (lange Sätze) |
| **S4** | DE | 5s | „Einmal Kaffee, bitte. Mit Milch." (kurz, Alltag) | Häufiger Use Case |
| **S5** | EN | 6s | „Can you recommend a good restaurant nearby?" (EN→DE) | Gegenrichtung |
| **S6** | DE | 20s | Durchgehender Satz ohne klare Satzgrenzen („Also wir waren dann im Museum und da gab es diese Ausstellung über moderne Kunst und das war wirklich sehr interessant besonders der Teil mit den Fotografien...") | Streaming-STT-Test (Satzgrenzen-Erkennung) |
| **S7** | DE | 10s | Reise-Wortschatz mit englischen Lehnwörtern („Ich brauche ein Ticket für den Airport-Shuttle.") | Code-Switching |
| **S8** | DE | 4s | Stille (2s) + „Guten Tag." (2s) | VAD-Test (Stille-Erkennung) |
| **S9** | DE | 7s | Restaurant-Geräusche (Hintergrund) + „Ich möchte zahlen." | Noise Suppression + STT-Qualität |
| **S10** | DE | 12s | Zwei kurze Sätze mit Pause („Danke schön. [2s Pause] Wo ist die Toilette?") | VAD + Satzgrenzen |

### 2.2 Sample-Generierung

- **S1–S8:** Aufgenommen mit Headset (Bluetooth, 16kHz mono) — realistische
  Audio-Qualität, wie Snail sie sehen wird.
- **S9:** Aufgenommen in echtem Restaurant (oder Restaurant-Geräusch-Sample
  gemischt mit klarer Stimme).
- **S10:** Aufgenommen mit echter Pause.
- **Format:** WAV (16kHz, mono, 16-bit) als Master. Für STT-APIs als WAV
  oder μ-law. Für Transport als Opus.

### 2.3 Text-Referenzen (für STT-Genauigkeit)

| ID | Referenz-Transkript | Referenz-Übersetzung (EN) |
|----|---------------------|---------------------------|
| S1 | „Hallo, wie geht es dir?" | „Hello, how are you?" |
| S2 | „Können Sie mir sagen, wo der nächste Bahnhof ist?" | „Can you tell me where the nearest train station is?" |
| S3 | „Ich bin vor zwei Tagen in Berlin angekommen und habe mir das Hotel gesucht, aber die Adresse war falsch." | „I arrived in Berlin two days ago and looked for the hotel, but the address was wrong." |
| S4 | „Einmal Kaffee, bitte. Mit Milch." | „One coffee, please. With milk." |
| S5 | „Can you recommend a good restaurant nearby?" | „Können Sie ein gutes Restaurant in der Nähe empfehlen?" |
| S6 | (siehe oben) | (fließende Übersetzung) |
| S7 | „Ich brauche ein Ticket für den Airport-Shuttle." | „I need a ticket for the airport shuttle." |
| S8 | (Stille, dann) „Guten Tag." | „Good day." |
| S9 | „Ich möchte zahlen." | „I would like to pay." |
| S10 | „Danke schön. Wo ist die Toilette?" | „Thank you. Where is the toilet?" |

---

## 3. Metriken

### 3.1 Primäre Metriken (Latenz)

| Metrik | Definition | Ziel |
|--------|-----------|------|
| **T_STT_first** | Zeit von Audio-Senden bis erstes Teiltranskript | < 500ms (P50) |
| **T_STT_final** | Zeit von Audio-Senden bis finales Transkript | < 1500ms (P50) |
| **T_MT** | Zeit von Text-Senden bis übersetzter Text | < 500ms (P50) |
| **T_TTS** | Zeit von Text-Senden bis erstes Audio-Byte | < 500ms (P50) |
| **T_E2E** | Zeit von Mikrofon-Aufnahme bis Playback-Beginn | < 2000ms (P50), < 4000ms (P95) |
| **T_DO_overhead** | Zusätzliche Latenz durch Durable Object (vs. Direkt-Call) | < 50ms (P50) |

### 3.2 Sekundäre Metriken (Qualität)

| Metrik | Definition | Ziel |
|--------|-----------|------|
| **WER** (Word Error Rate) | STT-Genauigkeit vs. Referenz-Transkript | < 10% (klare Stimme), < 20% (mit Hintergrundgeräusch) |
| **BLEU** (Übersetzung) | Übersetzungsqualität vs. Referenz | Informell (subjektiv + Referenz-Vergleich) |
| **MOS** (TTS-Qualität) | Mean Opinion Score (subjektiv, 1–5) | > 3.5 (verständlich + natürlich) |
| **Audio-Qualität** | TTS-Output verständlich? (ja/nein) | 100% verständlich |

### 3.3 Kontext-Metriken

| Metrik | Definition |
|--------|-----------|
| **Netzwerk** | WiFi (50ms RTT) vs. 4G (200ms RTT) vs. 3G (400ms RTT) |
| **Satzlänge** | Kurz (3–5s) vs. Mittel (8–10s) vs. Lang (15–20s) |
| **Hintergrundgeräusch** | Clean vs. Restaurant (S9) |
| **Wiederholungen** | 10 Runs pro Sample (für P50/P95) |

---

## 4. Benchmark-Szenarien

### 4.1 Einzel-API-Benchmarks (isoliert)

Jede API wird einzeln gemessen — ohne Pipeline, ohne DO, direkt von einem
Test-Client (Python-Skript oder Dart-CLI).

| Szenario | API | Samples | Netzwerk | Runs |
|----------|-----|---------|----------|------|
| **B1: Groq Whisper** | Groq STT | S1–S10 | WiFi + 4G | 10/Sample |
| **B2: Deepgram Nova-2** | Deepgram STT | S1–S10 | WiFi + 4G | 10/Sample |
| **B3: DeepL Free** | DeepL MT | T1–T10 (Texte) | WiFi + 4G | 10/Text |
| **B4: DeepL Pro** | DeepL MT | T1–T10 | WiFi + 4G | 10/Text |
| **B5: Google Cloud TTS** | Google TTS | T1–T10 | WiFi + 4G | 10/Text |
| **B6: fish.audio** | fish.audio TTS | T1–T10 | WiFi + 4G | 10/Text |
| **B7: Deepgram Aura** | Deepgram TTS | T1–T10 | WiFi + 4G | 10/Text |

**Text-Samples für MT/TTS (T1–T10):** Die übersetzten Referenz-Texte aus
§2.3 (z.B. T1 = „Hello, how are you?" für TTS, T1 = „Hallo, wie geht es
dir?" für MT).

### 4.2 Pipeline-Benchmark (kombiniert, ein Gerät)

Die vollständige Pipeline (STT → MT → TTS) auf einem Gerät, ohne DO, mit
festen API-Keys. Misst T_E2E (Mikrofon → Playback).

| Szenario | Pipeline (Tier) | Samples | Netzwerk | Runs |
|----------|----------------|---------|----------|------|
| **P1: Free-Pipeline** | Groq → DeepL Free → Google TTS | S1–S10 | WiFi | 10/Sample |
| **P2: Free-Pipeline** | Groq → DeepL Free → Google TTS | S1–S10 | 4G | 10/Sample |
| **P3: Paid-Pipeline** | Deepgram → DeepL Pro → fish.audio | S1–S10 | WiFi | 10/Sample |
| **P4: Paid-Pipeline** | Deepgram → DeepL Pro → fish.audio | S1–S10 | 4G | 10/Sample |
| **P5: Paid-Alternative** | Deepgram → DeepL Pro → Deepgram Aura | S1–S10 | WiFi | 10/Sample |
| **P6: Paid-Alternative** | Deepgram → DeepL Pro → Deepgram Aura | S1–S10 | 4G | 10/Sample |

### 4.3 Durable Object Benchmark (Relay-Overhead)

| Szenario | Messung | Methode |
|----------|----------|---------|
| **D1: WebSocket-Connect** | Time-to-Connect (App → DO) | 10 Verbindungen, WiFi + 4G |
| **D2: Audio-Roundtrip** | App → DO → App (Opus-Chunk, 100ms) | 100 Chunks, WiFi + 4G |
| **D3: API-Proxy-Overhead** | STT-Call direkt vs. STT-Call durch DO | 10 Calls, WiFi |
| **D4: Full-Pipeline durch DO** | STT → MT → TTS, alles durch DO | S1, S3, S6, 10 Runs, WiFi |

### 4.4 AEC-Test (Echo-Vermeidung)

| Szenario | Setup | Messung |
|----------|-------|---------|
| **E1: AEC off** | Gerät A spricht, Gerät B spielt TTS laut, A's Mikro nimmt B's TTS auf | STT von A erkennt Echo? (ja/nein) |
| **E2: AEC on (Android)** | Gleiche Setup, Android AudioFX AEC aktiv | STT von A erkennt Echo? (ja/nein) |
| **E3: AEC on (iOS)** | Gleiche Setup, AVAudioSession echoCancelation | STT von A erkennt Echo? (ja/nein) |
| **E4: AEC + BT-Headset** | A mit BT-Headset, B's TTS auf Lautsprecher | STT von A erkennt Echo? (ja/nein) |
| **E5: AEC + BT-Headset (beide)** | A und B mit BT-Headsets, AEC auf beiden Geräten | Feedback-Loop aufgetreten? (ja/nein) |

> AEC-Tests sind **nicht** Latenz-Messungen, sondern Funktions-Tests
> (Echo aufgetreten: ja/nein). Sie sind aber kritisch für die Machbarkeit.

---

## 5. Test-Infrastruktur

### 5.1 Test-Client

Ein **Python-Skript** (oder Dart-CLI) für isolierte API-Benchmarks (B1–B7).
Kein Flutter nötig — nur API-Calls + Zeitmessung.

```python
# Skizze: benchmark_stt.py
import time, requests, json

def benchmark_groq(audio_path, api_key):
    url = "https://api.groq.com/openai/v1/audio/transcriptions"
    headers = {"Authorization": f"Bearer {api_key}"}
    with open(audio_path, "rb") as f:
        files = {"file": f}
        data = {"model": "whisper-large-v3", "language": "de"}
        t0 = time.monotonic()
        resp = requests.post(url, headers=headers, files=files, data=data)
        t1 = time.monotonic()
    return {"latency_ms": (t1 - t0) * 1000, "text": resp.json().get("text", "")}
```

### 5.2 Pipeline-Prototyp

Ein **Dart-CLI** (oder einfache Flutter-App) für Pipeline-Benchmarks (P1–P6).
Liest Audio-Datei → VAD → STT → MT → TTS → schreibt Audio-Datei. Misst
T_E2E und alle Zwischen-Schritte.

### 5.3 Durable Object

Ein minimales **Cloudflare Worker + DO** für D1–D4. WebSocket-Relay +
API-Key-Injection + Audio-Weiterleitung.

### 5.4 Netzwerk-Simulation

- **WiFi:** Lokales Netzwerk (echtes WiFi, nicht Simulator).
- **4G:** Handy-Hotspot (echtes 4G) oder Network Link Conditioner (iOS) /
  emulator -netspeed 4G (Android).
- **3G:** Optional, nur für Worst-Case-Tests.

### 5.5 Hardware

| Gerät | Rolle |
|-------|-------|
| **Android-Handy (A)** | Host, BT-Headset, Mikrofon |
| **Android-Handy (B)** | Guest, BT-Headset, Playback |
| **BT-Headset (A)** | z.B. Sony WH-1000XM5 oder günstiges Headset |
| **BT-Headset (B)** | Gleiches oder anderes Modell |
| **Test-PC** | Python-Benchmark-Client, WiFi/4G |

---

## 6. Auswertung

### 6.1 Output-Format

Pro Benchmark-Run wird ein JSON-Eintrag erzeugt:

```json
{
  "scenario": "B1",
  "api": "groq_whisper",
  "sample": "S1",
  "network": "wifi",
  "run": 1,
  "latency_ms": 342,
  "wer": 0.0,
  "transcript": "Hallo, wie geht es dir?",
  "timestamp": "2026-08-08T03:15:00Z"
}
```

### 6.2 Aggregation

Pro Szenario (z.B. B1, S1, WiFi, 10 Runs):

| Statistik | Wert |
|-----------|------|
| P50 | Median der Latenz |
| P95 | 95. Perzentil |
| Mean | Durchschnitt |
| Min / Max | Bereich |
| WER (STT) | Durchschnittliche Word Error Rate |
| Fehler | Anzahl fehlgeschlagener Calls |

### 6.3 Entscheidungs-Matrix

Nach allen Benchmarks wird eine Matrix erstellt:

| Pipeline (Tier) | P50 (WiFi) | P95 (WiFi) | P50 (4G) | P95 (4G) | WER | TTS-MOS | Empfehlung |
|----------------|------------|------------|----------|----------|-----|---------|------------|
| Free (Groq+DeepL Free+Google) | ? | ? | ? | ? | ? | ? | ? |
| Paid (Deepgram+DeepL Pro+fish) | ? | ? | ? | ? | ? | ? | ? |
| Paid-Alt (Deepgram+DeepL Pro+Aura) | ? | ? | ? | ? | ? | ? | ? |

**Entscheidungsregeln:**
- Wenn P50 < 2s und P95 < 4s: ✅ API-Kombination ist geeignet.
- Wenn P50 < 2s aber P95 > 4s: ⚠️ Bedingt geeignet — untersuche P95-Ausreißer.
- Wenn P50 > 2s: ❌ API-Kombination ist nicht geeignet — Alternative suchen.

### 6.4 AEC-Entscheidung

| Szenario | Echo aufgetreten? | Entscheidung |
|----------|-------------------|--------------|
| E1 (AEC off) | Ja (erwartet) | — |
| E2 (AEC on, Android) | ? | Wenn ja: AEC unzureichend → Alternative (Halb-Duplex oder externes AEC-Modul) |
| E3 (AEC on, iOS) | ? | Wenn nein: ✅ iOS AEC funktioniert |
| E4 (AEC + BT, Lautsprecher) | ? | Worst-Case — wenn ja, nur Headset-Modus unterstützen |
| E5 (AEC + BT, beide) | ? | Kritischster Test — wenn ja, Produkt unbrauchbar |

---

## 7. Durchführungs-Plan

| Phase | Szenarien | Dauer | Voraussetzung |
|-------|----------|-------|---------------|
| **1: Einzel-API** | B1–B7 | 2–3 Tage | API-Keys besorgen, Audio-Samples erstellen |
| **2: Pipeline** | P1–P6 | 2–3 Tage | Phase 1 abgeschlossen, Pipeline-Prototyp |
| **3: Durable Object** | D1–D4 | 2–3 Tage | DO-Prototyp, Cloudflare-Konto |
| **4: AEC** | E1–E5 | 1–2 Tage | 2 Android-Handys, 2 BT-Headsets |
| **5: Auswertung** | Matrix, Entscheidungen | 1 Tag | Alle Phasen abgeschlossen |

**Gesamtdauer: 8–12 Tage** (kann parallelisiert werden: Phase 1 + 4
gleichzeitig, Phase 2 nach Phase 1, Phase 3 parallel zu Phase 2).

---

## 8. API-Keys (benötigt)

| API | Tier | Kosten | Link |
|-----|------|--------|------|
| **Groq** | Free | Kostenlos (Rate-Limit) | https://console.groq.com |
| **Deepgram** | Paid | Pay-as-you-go | https://console.deepgram.com |
| **DeepL Free** | Free | 500k Zeichen/Monat | https://www.deepl.com/pro-api |
| **DeepL Pro** | Paid | Ab €5.49/Monat | https://www.deepl.com/pro |
| **Google Cloud TTS** | Paid | $4/Mio Zeichen | https://cloud.google.com/text-to-speech |
| **fish.audio** | Paid | Pay-as-you-go | https://fish.audio |
| **Cloudflare** | Paid | Workers Paid ($5/Monat) | https://dash.cloudflare.com |

> **Hinweis:** Google Cloud TTS hat ein kostenloses Kontingent (1 Mio Zeichen/Monat
> für Standardstimmen), reicht für Benchmark-Zwecke.

---

## 9. Risiko-Flags (vor Benchmark zu prüfen)

| Risiko | Check | Wenn Problem |
|--------|-------|-------------|
| **Groq Rate-Limit** | 30 req/min (Free) | Benchmark ggf. drosseln |
| **Deepgram WebSocket** | Streaming-Modus verfügbar? | Wenn nicht: Batch-Modus testen + Latenz messen |
| **fish.audio Latenz** | Kein Streaming-TTS | Batch-Latenz messen, ggf. Deepgram Aura als Fallback |
| **DeepL Free Rate-Limit** | 500k Zeichen/Monat | Reicht für Benchmark (ca. 10k Zeichen total) |
| **Cloudflare DO** | Durable Objects verfügbar? | Workers Paid Plan nötig ($5/Monat) |
| **Android AEC** | AudioFX AEC pro Gerät unterschiedlich | Auf 2–3 Geräten testen (Pixel, Samsung, Xiaomi) |