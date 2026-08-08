# Snail — Echtzeit-Konversationsübersetzer („Babelfisch fürs Reisen")

> Zwei Personen mit je einem Headset. Die App erkennt, wer spricht,
> übersetzt das Gespräch live und gibt es dem jeweils anderen in seiner
> Sprache aus. Ideal für Reisen.

---

## 1. Zielbild & Nutzungsszenario

- **Zwei Nutzer** (A und B), jeder mit eigenem Headset (Mikro + Kopfhörer).
- A spricht Deutsch, B spricht Englisch (beliebige Sprachpaare).
- A spricht → B hört die Übersetzung auf Englisch (und umgekehrt).
- Die App erkennt automatisch, **wer gerade spricht** (Diarization), damit
  die Übersetzung dem richtigen Gegenüber zugespielt wird.
- Latenz-Ziel: **< 2 Sekunden** pro Richtung (komfortabel für Reisegespräche).

---

## 2. Kern-Pipeline (eine Richtung)

Jede Sprechrichtung durchläuft dieselbe Kette:

```
Mikrofon (A)
   │  Audio-Stream (16 kHz, mono)
   ▼
[1] VAD — Voice Activity Detection
   │  erkennt Sprachsegmente, schneidet Stille weg
   ▼
[2] STT — Speech-to-Text (Streaming)
   │  liefert laufende Teiltranskripte
   ▼
[3] Diarization — Speaker-Erkennung
   │  „das ist A" / „das ist B" (Voice-Fingerprint)
   ▼
[4] Übersetzung (LLM / MT-Engine)
   │  übersetzt ins Zielsprachen-Paar
   ▼
[5] TTS — Text-to-Speech
   │  erzeugt Sprachausgabe in Zielsprache
   ▼
[6] Playback
   │  Ausgabe auf dem Headset des Gegenübers
   ▼
Kopfhörer (B)
```

**Gegenrichtung** läuft parallel und unabhängig (A↔B gleichzeitig möglich).

---

## 3. Zwei Architektur-Varianten

### Variante A — Zwei Geräte (empfohlen)
Jeder Nutzer hat sein eigenes Smartphone/Tablet + Headset. Die Geräte
verbinden sich über einen zentralen Server (oder P2P).

```
[Gerät A] ──Audio──▶ [Server: STT→Übersetzung→TTS] ──Audio──▶ [Gerät B]
[Gerät B] ──Audio──▶ [Server: STT→Übersetzung→TTS] ──Audio──▶ [Gerät A]
```

- **Vorteile:** natürliche Nutzung (jeder hat sein eigenes Gerät), keine
  Audio-Übersprechung, skalierbar.
- **Nachteile:** braucht Netzwerkverbindung, Server-Latenz.

### Variante B — Ein Gerät, zwei Headsets
Ein Tablet/Laptop, an dem beide Headsets hängen. Verarbeitung komplett lokal.

- **Vorteile:** kein Server nötig, offline-fähig, geringste Latenz.
- **Nachteile:** unhandlich (ein Gerät teilen), Audio-Routing komplexer
  (zwei Mikros gleichzeitig, getrennte Ausgänge).

> **Empfehlung:** Variante A als Ziel, aber die Pipeline so bauen, dass sie
> auch lokal (Variante B) laufen kann — gleiche Kernmodule, nur anderer
> Transport.

---

## 3b. Technische Entscheidung: Bluetooth-Limit → Zwei Geräte

**Entscheidung (2026-08):** Snail nutzt **Variante A (zwei Geräte)**. Ein
einzelnes Handy kann **nicht** zwei volle Bluetooth-Headsets gleichzeitig
bedienen — das ist der entscheidende technische Grund.

### Bluetooth-Profile & Limits

| Profil | Funktion | Limit |
|--------|----------|-------|
| **A2DP** | Audio-Ausgabe (Musik/Sprache) | Nur **1** Stereo-Sink gleichzeitig |
| **HFP** | Headset-Profil (Mikro + Audio) | Nur **1** Verbindung gleichzeitig ⚠️ |

**Konsequenz:** Ein Handy kann nur **ein** Headset mit aktivem Mikrofon
bedienen. Das zweite Headset könnte höchstens als reiner Audio-Ausgang
(A2DP) laufen, aber **nicht sprechen** — es fehlt der zweite HFP-Kanal.

### Warum "1 Handy + 2 Headsets" nicht funktioniert

| Ansatz | Machbar? | Problem |
|--------|----------|---------|
| 1 Handy + 2 Headsets (je Mikro+Audio) | ❌ | Nur 1 HFP-Verbindung gleichzeitig |
| 1 Handy + 2 Headsets (nur Audio-Ausgabe) | ⚠️ | Kein Mikro für den zweiten — kann nicht sprechen |
| **2 Handys, je 1 Headset** | ✅ | Jedes Handy hat sein eigenes HFP |

### Workarounds (nicht empfohlen)

- **USB-Headset + Bluetooth-Headset:** USB umgeht das HFP-Limit, aber
  unhandlich und nicht mobil-tauglich.
- **LE Audio / Auracast:** Neuer Standard, aber noch kaum verbreitet und
  nicht für 2 volle Mikro-Kanäle gedacht.

### Fazit

Für das Reise-Szenario ist **zwei Geräte** die einzig saubere Lösung. Das
ist zugleich die natürlichere Nutzung (jeder hat sein eigenes Handy) und
bestätigt die Architektur-Variante A als Ziel.

---

## 4. Modul-Auswahl (Optionen je Baustein)

| Baustein | Lokal (offline) | Cloud (beste Qualität) |
|----------|-----------------|------------------------|
| **VAD** | Silero VAD (leicht, ~50ms) | — (immer lokal sinnvoll) |
| **STT** | Whisper (small/base) | Whisper API, Deepgram, Google STT |
| **Diarization** | Pyannote / Speaker-Embeddings | AssemblyAI, Deepgram |
| **Übersetzung** | Argos Translate, NLLB | DeepSeek/LLM, DeepL, Google Translate |
| **TTS** | Piper, Coqui | **fish.audio** (s2-pro), Edge-TTS, Google TTS |

**Pragmatischer Start (Cloud):** Silero VAD + Whisper API + DeepL/LLM +
**fish.audio** (s2-pro). Schnell, gut, minimaler Aufwand.

> **fish.audio** ist die bevorzugte TTS-Lösung (günstiger als ElevenLabs,
> natürliche Stimmen). API-Details: `reference_id` (nicht `voice_id`) im
> Request-Body, Modell `s2-pro`, Format MP3, API-Key via ENV-Variable
> `FISHAUDIO_API_KEY`.

**Später (offline):** Whisper lokal + NLLB + Piper → komplett offline-fähig.

---

## 5. Latenz-Budget (Ziel < 2s)

| Schritt | Budget |
|---------|--------|
| VAD | ~50 ms |
| STT (Streaming, Teiltranskript) | ~300–500 ms |
| Übersetzung | ~200–500 ms |
| TTS | ~200–400 ms |
| Netzwerk | ~50–100 ms |
| **Summe** | **~1–2 s** ✅ |

> Streaming-STT ist der Schlüssel: Man wartet nicht auf das Ende des
> Satzes, sondern übersetzt laufende Teiltranskripte. So fühlt sich das
> Gespräch natürlich an.

---

## 6. Technologie-Stack (Vorschlag)

- **Frontend (Mobile):** **Flutter** (empfohlen) — eine Codebasis für
  **Android (jetzt)** und **iOS (später)**. Alternativ React Native.
  Flutter hat starke Audio-Streaming-Bibliotheken und eine einheitliche
  UI. → **Cross-Platform ist die Grundsatzentscheidung.**
- **Backend/Orchestrierung:** Python (FastAPI) — beste STT/TTS-Ökosysteme.
- **Echtzeit-Transport:** WebSocket (Audio-Streams + Steuerung).
- **Audio-Streaming:** WebRTC für niedrige Latenz, alternativ WebSocket mit
  Opus-codierten Chunks.

### Flutter vs. React Native (Kurzvergleich)

| Kriterium | Flutter | React Native |
|-----------|---------|--------------|
| Audio-Streaming | Sehr gut (record/just_audio) | Gut (react-native-audio) |
| Performance | Nativ (kompiliert) | JS-Bridge (leicht langsamer) |
| UI-Konsistenz | Pixel-identisch auf beiden OS | Native Komponenten |
| iOS-Setup | Einfach | Xcode/CocoaPods nötig |
| Empfehlung | ✅ **Start hier** | Solide Alternative |

> **Warum Flutter:** Für eine latenzkritische Audio-App ist die native
> Performance und die ausgereifte Audio-Pipeline ein klarer Vorteil. Du
> baust einmal und deployst auf Android + iOS ohne doppelte Arbeit.

---

## 7. Offene Fragen / Entscheidungen

1. **Zwei Geräte oder ein Gerät?** → bestimmt Transport & Serverbedarf.
2. **Online oder offline-fähig?** → bestimmt Modul-Wahl (Cloud vs. lokal).
3. **Welche Sprachen zuerst?** → Deutsch/Englisch als Start sinnvoll.
4. **Server nötig?** → ja bei Variante A (zentral), nein bei B (lokal).
5. **Konversationsmodus:** Soll die App auch „Dolmetscher-Modus" können
   (eine Person spricht, Übersetzung wird laut für alle wiedergegeben)?

---

## 8. Nächste Schritte (wenn wir bauen)

1. **Prototyp der Pipeline** (lokal, ein Gerät): Mikro → VAD → STT →
   Übersetzung → TTS → Lautsprecher. Damit die Kette funktioniert.
2. **Diarization ergänzen** → wer spricht.
3. **Transport wählen** (WebSocket/WebRTC) → zwei Geräte verbinden.
4. **UI** → Sprachwahl, Verbindungsstatus, Live-Transkript-Anzeige.
