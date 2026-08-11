# Analyse- & Debug-Prompt: Snail (Code-Stand)

> Kopiere diesen Prompt und gib ihn einem leistungsfähigen Agenten (z.B.
> Claude, GPT-4, DeepSeek) zusammen mit dem Projektverzeichnis `snail/`.
> Der Agent soll den **echten Code** analysieren, die Benchmark-Daten
> interpretieren und konkrete Debug-/Optimierungsmaßnahmen vorschlagen.
> Anders als die alte `docs/analyse-prompt.md` geht es hier nicht um das
> Konzept, sondern um den **implementierten Stand**.

---

## Kontext

**Snail** ist ein Echtzeit-Konversationsübersetzer: Zwei Personen mit je
einem Headset, die App übersetzt das Gespräch live (DE→EN, etc.).
Latenz-Ziel: **P50 < 2s, P95 < 4s** pro Richtung.

### Projektstruktur (relevant)

```
snail/
├── pipeline/                  # Python-Prototyp (lokal, ein Gerät)
│   ├── pipeline.py            # Haupt-Pipeline WAV → VAD → STT → MT → TTS
│   ├── stt.py                 # Groq Whisper / Deepgram (BATCH)
│   ├── translate.py           # Morph / Groq / DeepL
│   ├── tts.py                 # edge-tts / Google / fish.audio / Deepgram Aura
│   ├── vad.py                 # Silero VAD (lokal)
│   ├── relay_client.py        # WebSocket-Client → Durable Object
│   └── config.py              # API-Keys (lazy)
├── durable-object/src/        # Cloudflare Durable Object (Relay)
│   ├── SnailRelay.ts          # WebSocket-Relay, Session-State, Quota
│   └── pipeline.ts            # STT→MT→TTS Proxy im DO
├── worker/src/index.ts        # Cloudflare Worker (Auth, Token, Room)
├── flutter_app/lib/           # Flutter-App
│   └── services/audio_service.dart  # WebSocket + Audio-Streaming
└── output/benchmark_summary.json    # Latenz-/WER-Benchmark (30 Runs)
```

### Benchmark-Ergebnisse (output/benchmark_summary.json, Free-Tier)

| Metrik | Wert |
|--------|------|
| t_total P50 (alle Samples) | **~2086 ms** |
| t_total P95 (alle Samples) | **~3820 ms** |
| t_total mean | ~2325 ms |
| t_stt P50 | ~450–700 ms |
| t_mt P50 | ~350–600 ms |
| t_tts P50 | **~640–2560 ms** (dominiert!) |
| WER mean | ~0.12 (S8: 0.5, S7: 0.29, S4: 0.2, S10: 0.17) |

**Kernbefund:** P50 liegt knapp über dem 2s-Ziel, P95 knapp unter 4s.
Der größte Einzelkostenfaktor ist **TTS** (bis 2.5s bei S3/S6). STT und
MT sind Batch-Aufrufe, kein Streaming.

---

## Aufgabe

Du bist ein erfahrener Echtzeit-Audio-Architekt und Debugger. Analysiere
den **Code** (nicht das Konzept) und beantworte die folgenden Fragen
konkret, mit Datei-/Zeilenreferenzen und priorisierten Empfehlungen.

## Teil A — Analyse (was ist der Ist-Zustand?)

1. **Latenz-Budget vs. Realität:** Vergleiche die Benchmark-Zahlen mit dem
   Ziel (P50<2s, P95<4s). Wo genau wird das Budget gerissen? Welcher
   Pipeline-Schritt ist der Flaschenhals? Ist die Messung selbst korrekt
   (misst sie Batch-Latenz statt Streaming-Latenz)?

2. **Batch vs. Streaming:** Die Architektur sieht Streaming vor (inkrementelle
   STT, Chunked TTS, parallele Pipeline). Der Code ist aber durchgehend
   **Batch** (wartet auf komplette Datei/Text). Quantifiziere, wie viel
   Latenz das kostet und was nötig wäre, um auf Streaming umzustellen.

3. **WER-Probleme:** Warum haben S8 (0.5), S7 (0.29), S4 (0.2) so hohe
   Fehlerraten? Liegt es an STT, an der Audio-Vorverarbeitung (VAD schneidet
   zu aggressiv?), an der Sample-Qualität? Was würdest du testen?

## Teil B — Debug (konkrete Bugs & Inkonsistenzen)

Prüfe den Code auf folgende Verdachtsmomente und bestätige/widerlege sie
mit Code-Referenzen:

1. **DO-Pipeline inkonsistent mit Python-Pipeline:** `durable-object/src/
   pipeline.ts` nutzt DeepL für MT und Google TTS für Free-Tier, während
   `pipeline/translate.py` + `pipeline/tts.py` Morph/Groq und edge-tts
   nutzen. Ist das ein Problem (unterschiedliche Qualität/Kosten pro Tier)?
   Welche Variante ist die "richtige"?

2. **Google TTS-Auth-Bug:** `pipeline.ts` `getApiKeys()` liest
   `env.GOOGLE_APPLICATION_CREDENTIALS` als TTS-API-Key. Google Cloud TTS
   braucht aber einen **Service-Account-JSON-Pfad**, keinen API-Key. Ist
   der Free-Tier-TTS-Pfad im DO damit kaputt? Wie wäre er zu fixen?

3. **Audio-Transport ineffizient:** `SnailRelay.ts` und `relay_client.py`
   und `audio_service.dart` senden Audio als **JSON-`number[]`-Array**
   (Base64/JSON-Overhead, kein echtes Opus-Streaming). Quantifiziere den
   Overhead und schlage einen effizienteren Transport vor (binärer
   WebSocket-Frame, Opus-Codec).

4. **Chunk-Pipeline im DO falsch:** `processAudioPipeline()` verarbeitet
   **jeden 0.5s-Chunk einzeln** als komplette STT→MT→TTS-Kette. Das erzeugt
   pro Chunk einen STT-Aufruf ohne Kontext (bricht Sätze), hohe API-Kosten
   und Latenz. Wie müsste echtes Streaming (Kontext-Puffer, Satzgrenzen)
   aussehen?

5. **Quota-Tracking ist fake:** `SnailRelay.ts` macht `quotaUsed += 0.02`
   ("1 chunk ≈ 20ms"). Das ist willkürlich und nicht an echte Audiodauer
   gekoppelt. Wie sollte Quota korrekt gemessen werden?

6. **Flutter-App unvollständig:** `audio_service.dart` hat kein echtes
   Mikrofon-Streaming, kein AEC, kein on-device VAD, und `_receivedAudio`
   sammelt alles im RAM. Was fehlt für einen funktionierenden End-to-End-
   Pfad auf dem Gerät?

## Teil C — Empfehlungen

1. **Priorisierte Fix-Liste:** Was ist der schnellste Weg, P50 unter 2s zu
   bringen? (TTS ist der größte Hebel — welche Optionen: Deepgram Aura
   Streaming, Chunked TTS, parallele Pipeline, kleinere Chunks?)
2. **Streaming-Roadmap:** Skizziere die minimalen Änderungen, um STT/MT/TTS
   von Batch auf Streaming umzustellen (pro Datei, mit API-Referenzen).
3. **Test-Strategie:** Welche Tests fehlen (Unit, Integration, E2E)?
   Wie würdest du die Latenz-Messung verbessern (echte Streaming-Latenz,
   first-token statt total)?

## Format

- Antworte auf Deutsch.
- Strukturiere nach Teil A / B / C.
- **Belege jede Aussage mit Datei- und Zeilenreferenz** (z.B.
  `pipeline/tts.py:106`).
- Trenne klar: **beobachtete Fakten** vs. **Vermutungen**.
- Gib am Ende eine priorisierte, umsetzbare Empfehlungsliste (Top 5).
- Sei ehrlich: Wenn etwas nicht funktioniert oder ein Designfehler ist, sag es.
