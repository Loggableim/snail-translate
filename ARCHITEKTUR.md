# Snail — Echtzeit-Konversationsübersetzer („Babelfisch fürs Reisen")

> Zwei Personen mit je einem Headset. Die App erkennt, wer spricht,
> übersetzt das Gespräch live und gibt es dem jeweils anderen in seiner
> Sprache aus. Ideal für Reisen.

---

## 1. Zielbild & Nutzungsszenario

- **Zwei Nutzer** (A und B), jeder mit eigenem Handy + Headset (Mikro + Kopfhörer).
- A spricht Deutsch, B spricht Englisch (beliebige Sprachpaare).
- A spricht → B hört die Übersetzung auf Englisch (und umgekehrt).
- Da jedes Gerät sein eigenes Mikro hat, ist **immer klar, wer spricht**
  (keine Diarization nötig).
- Latenz-Ziel: **< 2 Sekunden** pro Richtung (komfortabel für Reisegespräche).

---

## 2. Kern-Pipeline (eine Richtung)

Jede Sprechrichtung durchläuft dieselbe Kette. Da jedes Gerät sein eigenes
Mikro hat, ist die Sprecher-Zuordnung implizit gegeben — **keine
Diarization nötig.**

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
[3] Übersetzung (LLM / MT-Engine)
   │  übersetzt ins Zielsprachen-Paar
   ▼
[4] TTS — Text-to-Speech
   │  erzeugt Sprachausgabe in Zielsprache
   ▼
[5] Playback
   │  Ausgabe auf dem Headset des Gegenübers
   ▼
Kopfhörer (B)
```

**Gegenrichtung** läuft parallel und unabhängig (A↔B gleichzeitig möglich).

---

## 3. Architektur-Entscheidungen

### 3a. Zwei Geräte (Bluetooth-Limit)

**Entscheidung (2026-08):** Snail nutzt **zwei Geräte** (jeder sein eigenes
Handy + Headset). Ein einzelnes Handy kann **nicht** zwei volle Bluetooth-
Headsets gleichzeitig bedienen.

| Profil | Funktion | Limit |
|--------|----------|-------|
| **A2DP** | Audio-Ausgabe (Musik/Sprache) | Nur **1** Stereo-Sink gleichzeitig |
| **HFP** | Headset-Profil (Mikro + Audio) | Nur **1** Verbindung gleichzeitig ⚠️ |

**Konsequenz:** Ein Handy kann nur **ein** Headset mit aktivem Mikrofon
bedienen. Das zweite Headset könnte höchstens als reiner Audio-Ausgang
(A2DP) laufen, aber **nicht sprechen** — es fehlt der zweite HFP-Kanal.

| Ansatz | Machbar? | Problem |
|--------|----------|---------|
| 1 Handy + 2 Headsets (je Mikro+Audio) | ❌ | Nur 1 HFP-Verbindung gleichzeitig |
| 1 Handy + 2 Headsets (nur Audio-Ausgabe) | ⚠️ | Kein Mikro für den zweiten |
| **2 Handys, je 1 Headset** | ✅ | Jedes Handy hat sein eigenes HFP |

> **Historisch:** Eine "Ein-Gerät, zwei-Headsets"-Variante wurde erwogen,
> aber durch das Bluetooth-Limit verworfen. Workarounds (USB+Bluetooth,
> LE Audio/Auracast) sind nicht mobil-tauglich.

### 3b. Cloudflare Worker + Clerk (kommerziell)

**Entscheidung (2026-08):** Snail nutzt ein **serverless Backend auf
Cloudflare Workers** als Key-Vault und Tier-Gateway, mit **Clerk** für
Auth & Subscriptions. Die API-Keys liegen als Worker-Secrets in der
Cloudflare-Umgebung — **nie auf dem Gerät.**

#### Warum dieser Ansatz

| Anforderung | Lösung |
|-------------|--------|
| Keys sicher | Worker-Secrets in Cloudflare, nie in der App |
| Kein Server-Betrieb | Cloudflare Workers (serverless, Pay-per-Use) |
| Free/Paid-Tiers | Worker prüft Quota pro User, wählt API |
| Auth + Subscriptions | **Clerk** (verwaltet User, Sessions, Abos) |
| Skalierung | Cloudflare skaliert automatisch |

#### Architektur

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Cloudflare Worker (Edge)                     │
│  • Keys als Worker-Secrets (Deepgram, DeepL, fish.audio, Google)   │
│  • Clerk-Auth verifizieren                                          │
│  • Tier-Quota prüfen                                                │
│  • Gibt kurzlebige Session-Tokens aus                               │
└──────┬──────────────────────────────────────────────────────┬──────┘
       │  Clerk-JWT (Auth)                                    │  Clerk-JWT (Auth)
       │  Session-Token (API-Zugriff)                         │  Session-Token (API-Zugriff)
       ▼                                                     ▼
┌─────────────┐   Audio direkt an APIs   ┌─────────────┐
│  App (A)    │ ───────────────────────▶ │  App (B)    │
│  Flutter    │   Deepgram / DeepL /     │  Flutter    │
│             │   fish.audio / Google    │             │
│             │                          │             │
│  Mikro+Head │ ◀─── WebSocket ────────▶ │  Mikro+Head │
└─────────────┘   Audio-Stream zwischen  └─────────────┘
                  den Geräten
```

**Der Worker ist ein reines Key-Vault + Tier-Gateway.** Er gibt
kurzlebige Session-Tokens aus, mit denen die App die APIs **direkt**
aufruft. Der Worker streamt **kein** Audio — das wäre mit Worker-Limits
nicht machbar.

#### Rollen der Komponenten

- **Clerk:** User-Auth (Login/Register), Session-Management, Subscription-
  Status (Free/Paid). Die App bekommt von Clerk ein **JWT-Token**.
- **Cloudflare Worker:** Verifiziert das Clerk-Token, prüft die Tier-Quota,
  hält die API-Keys (Worker-Secrets) und gibt **kurzlebige Session-Tokens**
  aus, mit denen die App die APIs direkt aufruft.
- **App:** Nutzt das Clerk-JWT für Auth und das Session-Token für API-Calls.
  Sieht **nie** einen API-Key.

#### Session-Join-Flow

1. **Host (A) startet Session** → Worker erzeugt eine **Room-ID** (z.B.
   `snail-4821`) und ein Session-Token.
2. **Host zeigt QR-Code** mit der Room-ID (oder teilt den Code manuell).
3. **Guest (B) scannt QR-Code** → sendet Room-ID + Clerk-JWT an den Worker.
4. **Worker prüft Auth + Quota** → gibt Session-Token an B zurück.
5. **Beide Geräte verbinden sich** über WebSocket (direkt oder über ein
   Relay) und streamen Audio.

#### Free- vs. Paid-Tier (API-Auswahl pro Tier)

| | **Free Tier** | **Paid Tier** |
|---|---|---|
| **Quota** | X Minuten/Monat (z.B. 30) | Unbegrenzt |
| **Sprachen** | Wenige (DE/EN) | Alle |
| **STT** | Whisper API (günstig) | Deepgram (beste Qualität) |
| **Übersetzung** | Google Translate (kostenlos) | DeepL (beste Qualität) |
| **TTS** | Edge-TTS (kostenlos) | fish.audio (Premium) |

> Der Worker wählt **pro Tier unterschiedliche APIs**. Free-Nutzer
> bekommen die kostenlosen/günstigen Bausteine, Paid-Nutzer die Premium-
> Bausteine. So bleibt das Free-Tier ein bewusster Verlustbringer zum
> Anlocken, ohne die API-Kosten zu sprengen.

#### Sicherheit gegen Key-Extraktion

1. **Keys nur als Worker-Secrets** — nie im App-Code oder Client.
2. **App nutzt nur Clerk-JWT + Session-Token** — keine API-Keys im Client.
3. **Session-Tokens sind kurzlebig** (z.B. 1 Stunde) und an die Session
   gebunden.
4. **Rate-Limiting pro User** im Worker (verhindert Missbrauch).
5. **Quota-Check** vor jeder Token-Ausgabe.

---

## 4. Modul-Auswahl (pro Tier)

| Baustein | Free Tier | Paid Tier |
|----------|-----------|-----------|
| **VAD** | Silero VAD (lokal, ~50ms) | Silero VAD (lokal, ~50ms) |
| **STT** | Whisper API | Deepgram (Streaming) |
| **Übersetzung** | Google Translate | DeepL |
| **TTS** | Edge-TTS | fish.audio (s2-pro) |

> **VAD** läuft immer lokal (Silero) — kein API-Call nötig, geringste
> Latenz. **fish.audio** ist die bevorzugte Paid-TTS (günstiger als
> ElevenLabs, natürliche Stimmen). API-Details: `reference_id` (nicht
> `voice_id`) im Request-Body, Modell `s2-pro`, Format MP3, API-Key via
> `FISHAUDIO_API_KEY`.

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
> Gespräch natürlich an. Die App ruft die APIs **direkt** auf (kein
> Worker-Hop für Audio), daher bleibt das Budget realistisch.

---

## 6. Technologie-Stack

- **Frontend (Mobile):** **Flutter** — eine Codebasis für **Android
  (jetzt)** und **iOS (später)**. Flutter hat starke Audio-Streaming-
  Bibliotheken und native Performance. → **Cross-Platform ist die
  Grundsatzentscheidung.**
- **Backend (serverless):** **Cloudflare Worker** (JavaScript/TypeScript) —
  Key-Vault, Tier-Gateway, Clerk-Auth-Verifikation, Session-Token-Ausgabe.
  Kein Server-Betrieb, Pay-per-Use.
- **Auth & Subscriptions:** **Clerk** — User-Management, Login/Register,
  Subscription-Status (Free/Paid).
- **Echtzeit-Transport:** WebSocket (Audio-Streams + Steuerung) zwischen
  den beiden Geräten.
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

## 7. Offene Fragen

1. **Session-Join:** QR-Code mit Room-ID oder manueller Code? Beides?
2. **WebRTC vs. WebSocket:** Welcher Transport für die Audio-Streams
   zwischen den Geräten? WebRTC hat niedrigere Latenz, aber komplexeres
   NAT-Traversal.
3. **Relay-Server für WebRTC:** Braucht es einen TURN-Server, wenn beide
   Geräte hinter NAT sind? Oder reicht ein Cloudflare-Relay?
4. **Welche Sprachen zuerst?** → Deutsch/Englisch als Start sinnvoll.
5. **Dolmetscher-Modus:** Soll die App auch einen Modus haben, bei dem
   eine Person spricht und die Übersetzung laut für alle wiedergegeben
   wird (statt über Headset)?

---

## 8. Nächste Schritte

1. **Cloudflare Worker-Skeleton** — Key-Vault, Clerk-Auth-Verifikation,
   Session-Token-Ausgabe, Tier-Quota-Logik.
2. **Clerk-Integration** — User-Auth in der Flutter-App, Subscription-
   Status abfragen.
3. **Tier-Logik** — Worker wählt APIs pro Tier, gibt entsprechende
   Session-Tokens aus.
4. **API-Orchestrierung** — App ruft STT/Übersetzung/TTS-APIs direkt mit
   Session-Token auf.
5. **Session-Join-Flow** — Room-ID, QR-Code, WebSocket-Verbindung zwischen
   den Geräten.
6. **Pipeline-Prototyp** — Mikro → VAD → STT → Übersetzung → TTS →
   Playback (zuerst lokal auf einem Gerät, dann über zwei Geräte).

---

## Anhang A: Alternativ-Ansatz — Cloudflare Quick-Tunnel (persönliches Tool)

> Dieser Ansatz wurde für ein **persönliches Tool ohne Monetarisierung**
> dokumentiert. Für ein kommerzielles Produkt mit Free/Paid-Tiers ist er
> **nicht geeignet** (API-Keys liegen auf dem Host-Handy → unsicher).

### Konzept

Der erste Nutzer (Host) startet die Session, erzeugt einen **Cloudflare
Quick-Tunnel** (`trycloudflare.com`) und zeigt die Tunnel-URL als QR-Code.
Der zweite Nutzer (Guest) scannt den QR-Code und verbindet sich direkt
durch den Tunnel. **Kein zentraler Server nötig.**

```
[Gerät A - Host]  startet zuerst
   │  1. startet lokale Pipeline (STT→Übersetzung→TTS)
   │  2. cloudflared tunnel --url localhost:PORT
   │     → erzeugt https://xyz.trycloudflare.com (frische, zufällige URL)
   │  3. QR-Code zeigt auf https://xyz.trycloudflare.com/join?session=...
   │
[Gerät B - Guest] scannt QR-Code
   │  verbindet sich durch den Tunnel → Session läuft
```

### Einschränkungen

- **Pipeline-Last liegt auf dem Host-Handy** (STT/TTS/Übersetzung) → CPU &
  Batterie.
- **API-Keys liegen auf dem Host-Handy** → unsicher, keine Tiers möglich.
- **Quick-Tunnel-URLs sind ephemer** — verschwinden, wenn `cloudflared`
  endet.
- `cloudflared` muss für Android kompiliert und in die App eingebettet
  werden.
