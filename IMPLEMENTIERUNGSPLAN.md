# Snail — Implementierungsplan (Zielbild)

> Dieser Plan beschreibt den **kompletten Weg vom aktuellen Stand bis zum
> produktionsreifen MVP**. Er ist das Zielbild — jeder Meilenstein hat klare
> Deliverables, Erfolgskriterien und Go/No-Go-Entscheidungen. Phasen sind
> risikobasiert sortiert: höchstes Risiko zuerst.

---

## Aktueller Stand

| Artefakt | Status |
|----------|--------|
| `ARCHITEKTUR.md` (v2) | ✅ Abgeschlossen — Architektur-Entscheidungen, Pipeline, Modul-Auswahl |
| `API_BENCHMARK_PLAN.md` | ✅ Abgeschlossen — 10 Samples, 7 API-Benchmarks, 6 Pipeline-Benchmarks |
| `PIPELINE_PROTOTYP_PLAN.md` (v2) | ✅ Abgeschlossen — Python-CLI-Prototyp, 6.5–7 Tage |
| `mockup/index.html` | ✅ Abgeschlossen — 8 Screens, Tag/Nacht (Wanderlust/Aurora) |
| API-Keys | ⏳ Ausstehend — Groq, Deepgram, DeepL, Google Cloud TTS, fish.audio |
| Pipeline-Prototyp | ⏳ Ausstehend — Python-CLI, Batch-Pipeline |
| AEC-Prototyp | ⏳ Ausstehend — Echo Cancellation auf Android |
| Backend (Worker + DO) | ⏳ Ausstehend |
| Flutter-App | ⏳ Ausstehend |

---

## Meilensteine

```
M0  Pipeline-Prototyp (Python, Batch, 1 Gerät)
    └─ Validiert: API-Pipeline < 2s machbar?

M1  AEC-Prototyp (Android, 2 Geräte)
    └─ Validiert: Echo Cancellation funktioniert mit BT-Headsets?

M2  Streaming-Pipeline (Python, 1 Gerät)
    └─ Validiert: Streaming-Translation + Chunked-TTS reduziert Latenz?

M3  Backend-Skeleton (Cloudflare Worker + Durable Object)
    └─ Key-Vault, Auth, Quota, WebSocket-Relay, API-Key-Injection

M4  Zwei-Geräte-Prototyp (Python + DO, 2 Geräte)
    └─ Validiert: Audio-Stream über Relay, Pipeline über 2 Geräte

M5  Flutter-App MVP (Android, 2 Geräte, alle Features)
    └─ Login, Session-Join, Live-Übersetzung, Settings, Paywall

M6  Production-Readiness
    └─ iOS, Store-Readiness, Monitoring, DSGVO, Beta-Test
```

---

## M0 — Pipeline-Prototyp (Python, Batch)

**Dauer:** 6.5–7 Tage
**Risiko:** 🔴 Hoch — Machbarkeit der Latenz
**Plan:** `PIPELINE_PROTOTYP_PLAN.md` (v2)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | `pipeline/` | Python-CLI-Tool: WAV → VAD → STT → MT → TTS → Playback |
| 2 | `audio_samples/` | 10 WAV-Dateien (S1–S10, 16kHz mono, TTS-generiert) |
| 3 | `output/` | Benchmark-Ergebnisse (JSON, 130 Runs: 100 Free + 30 Paid) |
| 4 | Auswertung | P50/P95 pro Tier, WER, Bottleneck-Analyse, Go/No-Go |

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| P50 Latenz (Free, WiFi) | < 2s |
| P50 Latenz (Paid, WiFi) | < 2s |
| P95 Latenz (Free, WiFi) | < 4s |
| WER (clean Audio) | < 10% |
| TTS verständlich | Subjektiv OK |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| P50 < 2s, P95 < 4s | ✅ **GO** → M1 (AEC-Prototyp) |
| P50 < 2s, P95 > 4s | ⚠️ Ausreißer analysieren, dann GO/No-Go |
| P50 > 2s, P50 < 3s | ⚠️ Bottleneck identifizieren, Streaming probieren (M2 vor M1) |
| P50 > 3s | ❌ **NO-GO** → API-Stack überdenken, Architektur revidieren |

### Caveats

- Gemessene Latenz = **untere Grenze** (1 Hop, WiFi, keine AEC)
- Echte App: +20–50ms (DO-Relay) + 100–300ms (4G) + 10ms (AEC)
- Batch-Modus — Streaming wird niedrigere Latenz haben

---

## M1 — AEC-Prototyp (Android, 2 Geräte)

**Dauer:** 2–3 Tage
**Risiko:** 🔴 Hoch — Echo/Feedback-Loop kann Produkt unbrauchbar machen
**Abhängigkeit:** M0 (GO)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | AEC-Test-App | Minimale Flutter-App (oder Python-Skript): Mikro → Playback |
| 2 | Test-Protokoll | 5 Szenarien (E1–E5) auf 2 Android-Handys + 2 BT-Headsets |
| 3 | Auswertung | Echo aufgetreten? (ja/nein) pro Szenario, Go/No-Go |

### Test-Szenarien

| ID | Setup | Messung |
|----|-------|---------|
| E1 | AEC off, Lautsprecher | Echo aufgetreten? (Baseline) |
| E2 | AEC on (Android AudioFX), Lautsprecher | Echo aufgetreten? |
| E3 | AEC on (iOS AVAudioSession), Lautsprecher | Echo aufgetreten? |
| E4 | AEC + BT-Headset, Lautsprecher | Echo aufgetreten? |
| E5 | AEC + BT-Headset (beide Geräte) | Feedback-Loop aufgetreten? |

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| E2 (Android AEC, Lautsprecher) | Echo behoben |
| E5 (AEC + BT, beide) | Kein Feedback-Loop |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| E5: kein Feedback-Loop | ✅ **GO** → M2 (Streaming) oder M3 (Backend) |
| E5: Feedback-Loop trotz AEC | ❌ **NO-GO** → Alternativen prüfen: Halb-Duplex-Modus, externes AEC-Modul, andere Headset-Profile |

### Fallback bei No-Go

- **Halb-Duplex:** Playback pausiert Mikrofon (nicht gleichzeitig sprechen) — funktioniert, aber weniger natürlich
- **Externe AEC:** RNNoise + AEC als Software-Pipeline (statt OS-native)
- **Andere Headsets:** LE Audio Headsets mit besserem AEC testen

---

## M2 — Streaming-Pipeline (Python, 1 Gerät)

**Dauer:** 3–4 Tage
**Risiko:** 🟡 Mittel — Latenz-Optimierung
**Abhängigkeit:** M0 (GO)
**Optional:** Nur wenn M0 P50 > 1.5s oder wenn Streaming für < 2s nötig

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | `pipeline/streaming.py` | Streaming-Pipeline: STT-Teiltranskripte → inkrementelle Übersetzung → chunked TTS |
| 2 | Benchmark-Vergleich | Batch vs. Streaming: P50/P95-Delta |
| 3 | Auswertung | Streaming lohnt sich? (Latenz-Reduktion vs. Komplexität) |

### Was geändert wird

| Schritt | Batch (M0) | Streaming (M2) |
|---------|------------|-----------------|
| STT | Groq/Deepgram Batch | Deepgram WebSocket (Teiltranskripte) |
| Übersetzung | DeepL Batch (ganzer Satz) | DeepL Batch (Teiltranskripte, wiederholt) |
| TTS | Google/fish.audio Batch (ganzer Satz) | fish.audio/Deepgram Aura (Satzfragmente) |
| Pipeline | Seriell | Parallell (STT → MT → TTS überlappend) |

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| P50 Streaming < P50 Batch | Ja, um > 300ms |
| P50 Streaming (Free) | < 1.5s |
| P50 Streaming (Paid) | < 1.5s |
| Übersetzungsqualität bei Teiltranskripten | Subjektiv OK (kein Flatter, keine Sprünge) |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| P50 < 1.5s, Qualität OK | ✅ Streaming wird in Flutter-App verwendet |
| P50 < 1.5s, Qualität schlecht | ⚠️ Batch verwenden, Streaming für v2 |
| P50 ≥ 1.5s | ❌ Streaming lohnt nicht, Batch verwenden |

---

## M3 — Backend-Skeleton (Cloudflare Worker + Durable Object)

**Dauer:** 4–5 Tage
**Risiko:** 🟡 Mittel — Serverless-Architektur, WebSocket-Relay
**Abhängigkeit:** M0 (GO), M1 (GO)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | `worker/` | Cloudflare Worker: Clerk-JWT verifizieren, Quota prüfen, Room-ID erstellen, Session-Token ausgeben |
| 2 | `durable-object/` | Durable Object: WebSocket-Relay, Session-State, API-Key-Injection, Audio-Streaming-Proxy, Quota-Tracking |
| 3 | `wrangler.toml` | Cloudflare-Konfiguration: Worker + DO + KV (Quota) + Secrets (API-Keys) |
| 4 | Test-Suite | Unit-Tests: Auth, Quota, Room-Erstellung, WebSocket-Verbindung, API-Key-Injection |
| 5 | Deployment | Worker + DO deployed auf Cloudflare (staging) |

### Architektur

```
App (A) ──Clerk-JWT──▶ Worker ──Session-Token──▶ App (A)
                        │
                        ├── erstellt Room-ID + DO
                        │
App (A) ──WebSocket──▶ Durable Object ◀──WebSocket── App (B)
                        │
                        ├── verifiziert Session-Token
                        ├── hält WebSocket (beide Geräte)
                        ├── injiziert API-Keys (Worker-Secrets)
                        ├── streamt Audio → STT/MT/TTS APIs
                        ├── trackt Quota (pro User, pro Session)
                        │
                        ▼
                   STT / MT / TTS APIs
```

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| Clerk-JWT verifiziert | ✅ Gültige/ungültige Tokens korrekt erkannt |
| Quota-Check | ✅ Free: 30 min/Monat, Paid: unbegrenzt |
| WebSocket-Verbindung | ✅ 2 Geräte verbunden, stabil für 30 min |
| API-Key-Injection | ✅ App sieht nie API-Keys, APIs erhalten korrekte Keys |
| Audio-Streaming | ✅ Opus-Audio durch DO, < 50ms Overhead |
| Room-ID / QR-Code | ✅ Host erstellt Room, Guest tritt bei |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| Alle Kriterien erfüllt | ✅ **GO** → M4 (Zwei-Geräte-Prototyp) |
| DO-Overhead > 100ms | ⚠️ Architektur überdenken (direkte API-Calls vs. Proxy) |
| WebSocket instabil | ⚠️ TURN-Server / WebRTC als Alternative prüfen |

---

## M4 — Zwei-Geräte-Prototyp (Python + DO, 2 Geräte)

**Dauer:** 3–4 Tage
**Risiko:** 🟡 Mittel — Integration Pipeline + Relay + 2 Geräte
**Abhängigkeit:** M0 (GO), M1 (GO), M3 (GO)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | `pipeline/relay_client.py` | Python-Client: WebSocket zum DO, Audio senden/empfangen |
| 2 | Test-Setup | 2 PCs (oder PC + Handy), je Audio I/O, verbunden über DO |
| 3 | End-to-End-Test | A spricht → B hört Übersetzung (und umgekehrt) |
| 4 | Latenz-Messung | E2E mit DO-Relay (P50/P95), Vergleich mit M0 (ohne Relay) |

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| Bidirektionale Übersetzung | A→B und B→A gleichzeitig |
| Audio-Qualität | Verständlich, keine Dropouts > 1s |
| E2E-Latenz (WiFi, mit DO) | P50 < 2.5s (M0 + 50ms DO-Overhead) |
| Session-Lebenszyklus | Start, 30 min Lauf, Clean Shutdown |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| E2E P50 < 2.5s, Audio OK | ✅ **GO** → M5 (Flutter-App) |
| E2E P50 > 3s | ⚠️ DO-Overhead messen, ggf. direkte API-Calls (Keys an App) |
| Audio-Dropouts | ⚠️ Jitter-Buffer, Opus-Parameter tunen |

---

## M5 — Flutter-App MVP (Android)

**Dauer:** 10–14 Tage
**Risiko:** 🟢 Niedrig — Standard-App-Entwicklung
**Abhängigkeit:** M0–M4 (alle GO)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | `flutter_app/` | Flutter-App (Android), alle 8 Screens aus Mockup |
| 2 | Clerk-Integration | Login, Register, Subscription-Status (Free/Paid) |
| 3 | Audio-Pipeline | Mikro → AEC → VAD → WebSocket → DO → Playback (native Platform Channels für AEC) |
| 4 | Session-Flow | Host: Session starten, QR-Code zeigen. Guest: QR scannen, beitreten |
| 5 | Settings | AEC, Noise Suppression, Sprache, Lautstärke, Tag/Nacht-Modus |
| 6 | Paywall | Free vs. Pro, Clerk-Subscription, Upgrade-Flow |
| 7 | Profil | Statistik, Sessions, Account-Verwaltung |
| 8 | Tag/Nacht-Modus | Wanderlust (Tag) + Aurora (Nacht), Toggle in Status-Bar + Settings |

### Screen-Mapping (Mockup → Flutter)

| Mockup-Screen | Flutter-Widget | API-Anbindung |
|---------------|---------------|---------------|
| Login | `LoginScreen` | Clerk Auth |
| Home | `HomeScreen` | Clerk User + Quota (Worker) |
| QR / Host | `QrHostScreen` | Worker (Room-ID) + QR-Code-Generator |
| Beitreten | `JoinScreen` | QR-Scanner + Worker (Session-Token) |
| Session | `SessionScreen` | WebSocket (DO) + Audio-Pipeline |
| Einstellungen | `SettingsScreen` | Local prefs + Clerk |
| Abo | `PaywallScreen` | Clerk Subscriptions |
| Profil | `ProfileScreen` | Clerk User + Worker (Stats) |

### Audio-Pipeline in Flutter

```
Mikrofon (Platform Channel)
  → AEC (Android AudioFX, Platform Channel)
  → Noise Suppression (RNNoise, Platform Channel oder on-device)
  → VAD (Silero, TensorFlow Lite oder Platform Channel)
  → Opus-Encoder (Platform Channel)
  → WebSocket → Durable Object
  → STT/MT/TTS (im DO)
  → Opus-Audio zurück
  → Opus-Decoder (Platform Channel)
  → Jitter-Buffer
  → Playback (just_audio)
```

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| Login (Clerk) | ✅ Login, Register, Logout funktioniert |
| Session (2 Geräte) | ✅ Host startet, Guest tritt bei, Audio läuft |
| Live-Übersetzung | ✅ A spricht DE → B hört EN (und umgekehrt) |
| E2E-Latenz (4G) | P50 < 3s, P95 < 5s (4G ist langsamer als WiFi) |
| AEC funktioniert | ✅ Kein Feedback-Loop (validiert in M1) |
| Tag/Nacht-Modus | ✅ Toggle funktioniert, beide Themes korrekt |
| Paywall | ✅ Free/Pro erkennbar, Upgrade klappt |
| Stabilität | ✅ 30 min Session ohne Crash |

### Go/No-Go

| Ergebnis | Aktion |
|----------|--------|
| Alle Kriterien erfüllt | ✅ **GO** → M6 (Production-Readiness) |
| 4G-Latenz > 5s | ⚠️ WebRTC statt WebSocket, oder Audio-Codec optimieren |
| AEC auf > 50% der Geräte fehlerhaft | ❌ Halb-Duplex-Modus als Fallback |

---

## M6 — Production-Readiness

**Dauer:** 5–7 Tage
**Risiko:** 🟢 Niedrig — Polish, nicht Machbarkeit
**Abhängigkeit:** M5 (GO)

### Deliverables

| # | Artefakt | Beschreibung |
|---|----------|-------------|
| 1 | iOS-Port | Flutter iOS-Build, AEC via AVAudioSession, Test auf iPhone |
| 2 | Store-Assets | App-Icon, Screenshots, Store-Listing (Play Store + App Store) |
| 3 | Monitoring | Cloudflare Analytics, Error-Tracking (Sentry o.ä.), Latenz-Dashboard |
| 4 | DSGVO | Datenschutzerklärung, Opt-In für Audio-Verarbeitung, DeepL (EU) als primäre MT |
| 5 | Rate-Limiting | Worker: pro User, pro IP, pro Session |
| 6 | Beta-Test | 5–10 Tester, 2 Geräte, Feedback sammeln |
| 7 | CI/CD | GitHub Actions: Flutter-Build, Worker-Deploy, Tests |

### Erfolgskriterien

| Kriterium | Ziel |
|-----------|------|
| iOS funktioniert | ✅ Gleiche Features wie Android, AEC via iOS |
| Store-Readiness | ✅ Play Store + App Store Review bestanden |
| Beta-Tester满意度 | ✅ > 70% "würde ich nutzen" |
| DSGVO | ✅ Datenschutzerklärung, Opt-In, EU-MT |
| Monitoring | ✅ Latenz-P95 < 5s in Produktion |

---

## Gesamt-Zeitplan

| Meilenstein | Dauer | Kumuliert | Risiko |
|-------------|-------|-----------|--------|
| M0 Pipeline-Prototyp | 7 Tage | 7 Tage | 🔴 Hoch |
| M1 AEC-Prototyp | 3 Tage | 10 Tage | 🔴 Hoch |
| M2 Streaming-Pipeline | 4 Tage | 14 Tage | 🟡 Mittel (optional) |
| M3 Backend-Skeleton | 5 Tage | 19 Tage | 🟡 Mittel |
| M4 Zwei-Geräte-Prototyp | 4 Tage | 23 Tage | 🟡 Mittel |
| M5 Flutter-App MVP | 14 Tage | 37 Tage | 🟢 Niedrig |
| M6 Production-Readiness | 7 Tage | 44 Tage | 🟢 Niedrig |

**Gesamt: ~44 Tage (6–9 Wochen)** — M2 optional, ohne M2: ~40 Tage

### Kritischer Pfad

```
M0 (Pipeline) → M1 (AEC) → M3 (Backend) → M4 (2 Geräte) → M5 (Flutter) → M6 (Prod)
                    ↓
               M2 (Streaming) — optional, parallel zu M3
```

**M0 und M1 sind die kritischen Meilensteine.** Wenn diese GO geben, ist der Rest
Ingenieursarbeit. Wenn M0 oder M1 NO-GO geben, muss die Architektur überdacht werden.

---

## Risiko-Heatmap

| Risiko | Meilenstein | Wahrscheinlichkeit | Impact | Mitigation |
|--------|-------------|-------------------|--------|------------|
| API-Pipeline > 2s | M0 | Mittel | 🔴 Hoch | M2 (Streaming), API-Wechsel |
| AEC funktioniert nicht | M1 | Mittel | 🔴 Hoch | Halb-Duplex, externes AEC |
| DO-Overhead zu hoch | M3 | Niedrig | 🟡 Mittel | Direkte API-Calls (Keys an App) |
| 4G-Latenz > 5s | M5 | Mittel | 🟡 Mittel | WebRTC, Codec-Tuning |
| fish.audio instabil | M0/M5 | Niedrig | 🟡 Mittel | Deepgram Aura als Alternative |
| Groq Rate-Limit | M0 | Hoch | 🟢 Niedrig | Drosselung, Deepgram als Fallback |
| Flutter Audio-Latenz | M5 | Niedrig | 🟡 Mittel | Platform Channels, nativer Audio-Pfad |

---

## Entscheidungs-Log

| Datum | Meilenstein | Entscheidung | Begründung |
|-------|-------------|-------------|------------|
| | M0 | (ausstehend) | |
| | M1 | (ausstehend) | |
| | M2 | (ausstehend) | |
| | M3 | (ausstehend) | |
| | M4 | (ausstehend) | |
| | M5 | (ausstehend) | |
| | M6 | (ausstehend) | |

> Wird nach jedem Meilenstein ausgefüllt: GO/NO-GO + Begründung + ggf. Plan-Anpassung.

---

## Datei-Übersicht

| Datei | Status | Zweck |
|-------|--------|-------|
| `ARCHITEKTUR.md` | ✅ v2 | Architektur-Entscheidungen, Pipeline, Modul-Auswahl |
| `API_BENCHMARK_PLAN.md` | ✅ | API-Benchmark-Plan (10 Samples, 7+6+4+5 Szenarien) |
| `PIPELINE_PROTOTYP_PLAN.md` | ✅ v2 | Python-Prototyp-Plan (Batch, 6.5–7 Tage) |
| `IMPLEMENTIERUNGSPLAN.md` | ✅ v1 | Dieser Plan — Zielbild, Meilensteine, Go/No-Go |
| `mockup/index.html` | ✅ | 8 Screens, Tag/Nacht (Wanderlust/Aurora) |
| `pipeline/` | ⏳ M0 | Python-CLI-Prototyp |
| `worker/` | ⏳ M3 | Cloudflare Worker |
| `durable-object/` | ⏳ M3 | Durable Object (Relay) |
| `flutter_app/` | ⏳ M5 | Flutter-App (Android) |