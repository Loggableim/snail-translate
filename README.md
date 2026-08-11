# Snail — Echtzeit-Konversationsübersetzer

Zwei Personen, zwei Headsets, eine Sprache. Snail übersetzt Live-Gespräche in Echtzeit.

## Verbindliches Zielbild

Snail ist eine BYOK-App auf Session-Ebene: Wer eine Session eröffnet, wählt
Ollama, OpenAI oder Gemini Live und übernimmt die Providerkosten. Der eingeladene Nutzer
braucht keinen eigenen Key. Hat der Gast einen eigenen Live-Key, übersetzt er
seine Richtung lokal parallel; ohne eigenen Key übernimmt die Gegenstelle den
Fallback. Flutter übernimmt
Mikrofon, AEC, Noise Suppression, Playback und die Providerwahl des Owners.
Der Worker übernimmt Geräteberechtigungen, Room, Quota, Conversation-State und
stellt kurzlebige OpenAI-Realtime-Secrets aus, ohne lokale BYOK-Keys zu sehen.

### App teilen

Über **App direkt teilen** bietet das bereits laufende Host-Gerät seine
signierte Android-APK selbst über einen kurzlebigen QR-/Share-Link an. Im
gleichen WLAN ist der Transfer direkt; außerhalb vermittelt Cloudflare nur
einen temporären verschlüsselten Tunnel und speichert die APK nicht. Nach der
Installation folgen Kontakt-QR und die verschlüsselte P2P-Verbindung; der
Share-Link enthält nie API-Keys oder eine Session-Berechtigung.

Der primäre Live-Audio-Pfad ist `gpt-realtime-translate` über die dedizierte
Realtime-Translation-Session. Die App streamt 24-kHz-PCM16, spielt Audio-Deltas
sofort über eine begrenzte Jitter-Queue ab und verarbeitet Quell- sowie
Zielsprach-Transcript-Deltas. VAD, Barge-in, Reconnect, Queue-Backpressure und
Turn-Latenzen sind Bestandteil des Zielbilds; es gibt keine starre globale
500-ms-Sperre.

Die alte Python-Pipeline in `pipeline/` ist nur Benchmark- und
Entwicklungsreferenz; sie ist kein Produkt-Fallback.

## Implementierungsstatus

| Bereich | Status |
|---|---|
| Flutter-Android-Runtime, AEC/NS und Playback | implementiert und auf Android gestartet |
| OpenAI Realtime Translation | Streaming-Kern implementiert; Transcript/VAD/Resilienz werden zum Zielbild ausgebaut |
| Gemini Live Translation | implementiert als lokaler BYOK-Audioanbieter |
| Session-BYOK-Fallback | implementiert: Gast-Key parallel, sonst Owner-Key lokal |
| WebRTC-Audio/DataChannel mit Relay-Fallback | implementiert |
| QR-Identität, Kontakte und gezielte Einladungen | implementiert |
| Verschlüsselte Conversation-Historie und Offline-Outbox | implementiert |
| Telegram-Sticker | Bot-API-Import öffentlicher Packs; vollständiges MTProto offen |
| Provider-Live-E2E-/Latenzbenchmark | offen, benötigt reale Provider-Konfiguration |

Snail unterstützt im Zielbild einen Messenger-Modus. Die Nutzer
werden über User-ID und Conversation- bzw. Room-ID verbunden und können sich
auch über getrennte Netzwerke oder an unterschiedlichen Orten austauschen.
Online-Nachrichten werden bevorzugt direkt per WebRTC zugestellt; bei
blockiertem NAT greift TURN. Offline-Nachrichten und Zustellstatus werden
verschlüsselt persistent gespeichert. Live-Übersetzung öffnet bei
Bedarf zusätzlich einen temporären Realtime-Room.

Für Live-Audio nutzt die Flutter-App nach dem SDP/ICE-Handschlag einen
WebRTC-DataChannel für fertige Übersetzungs-Chunks. Während der Verbindung
und bei fehlgeschlagenem ICE bleibt der verschlüsselte Relay-Pfad als
Fallback aktiv.

Jeder Nutzer erhält automatisch einen individuellen QR-Code als öffentliche
User-ID. Der Username kann jederzeit geändert werden; der QR-Link ändert sich
dabei, die lokale Geräteidentität und bestehende Conversations bleiben
erhalten. Nach dem Scan versucht Snail bevorzugt eine direkte, verschlüsselte
P2P-Verbindung per WebRTC. Der Worker dient nur als Rendezvous-/Signalling-
Dienst; TURN ist der Fallback bei blockiertem NAT.

Die Kontakte-Seite zeigt auch den eigenen QR-Code. Die Geräteidentität basiert
auf einem Keystore-geschützten App-Schlüssel, nicht auf der IMEI: Das ist auf
aktuellen Android-Versionen verlässlich nutzbar und vermeidet eine unnötig
personenbezogene Hardwarekennung. Der Übersetzungsverlauf speichert nur
abgeschlossene Turns lokal und wird mit Neustart-, Duplikat-, Lösch- und
Abbruch-Smoke-Tests abgesichert.

Im Messenger können öffentliche Telegram-Stickerpacks über einen
`t.me/addstickers/...`-Link importiert werden. Dafür wird lokal ein Telegram-
Bot-Token benötigt; der Token wird nicht in Chatnachrichten oder im Relay
übertragen. Statische WebP-Sticker werden als lokale Daten übertragen,
animierte/video Sticker behalten ihre Telegram-Metadaten.

## Architektur

```
Mikrofon → AEC/NS → Audio-Queue → OpenAI Realtime Translation → Audio-Queue → Playback
    │                         │             │
    └── Flutter + Geräte-ID ──┴── WebRTC/P2P oder Relay ────┘
                                  │
                         Worker: QR, Quota,
                         kurzlebiges Secret
```

## Tech-Stack

| Schicht | Technologie |
|---------|------------|
| App | Flutter 3.29+ (Dart) |
| Gateway | Cloudflare Worker (TypeScript) |
| Relay | Cloudflare Durable Object |
| Storage | Cloudflare KV |
| STT | Groq Whisper (531ms P50) → Deepgram → OpenAI |
| MT | Groq gpt-oss-20b (430ms P50) |
| TTS | fish.audio (450ms TTFA) → edge-tts |

## Pipeline-Performance

| Metrik | Wert |
|--------|------|
| P50 Gesamt | **1.422ms** |
| P95 Gesamt | **1.845ms** |
| Ziel | <2s P50, <4s P95 |
| Status | 🟢 GO |

## Setup (Entwicklung)

### Voraussetzungen
- Flutter SDK 3.29+
- Android SDK 34 + NDK 26.3
- JDK 21
- Cloudflare Wrangler CLI

### Flutter-App bauen
```bash
cd flutter_app
flutter pub get
flutter build apk --release
```

### Backend deployen
```bash
wrangler deploy
```

## API-Referenz

| Endpoint | Methode | Beschreibung |
|----------|---------|-------------|
| `/api/health` | GET | Health-Check |
| `/api/rooms` | POST | Raum erstellen (Host) |
| `/api/rooms/:id/join` | POST | Raum beitreten (Guest) |
| `/ws?room=<id>` | WS | WebSocket-Relay |

## Historischer Provider-Benchmark

Die folgende alte Tabelle beschreibt nur frühere Benchmark-Läufe. Sie ist
nicht der BYOK-Produktpfad.

| Schritt | Primär | Fallback 1 | Fallback 2 |
|---------|--------|-----------|-----------|
| STT | Groq Whisper (531ms) | Deepgram Nova-2 | OpenAI Whisper (1250ms) |
| MT | Groq gpt-oss-20b (430ms) | — | — |
| TTS | fish.audio (450ms) | edge-tts | — |

## Features

- [x] Echtzeit-Audio-Übersetzung (STT → MT → TTS)
- [x] Acoustic Echo Cancellation (Android AudioFX)
- [x] Multi-Provider-Fallback (Groq → Deepgram → OpenAI)
- [x] QR-Code Session-Sharing
- [x] Transkript-History
- [x] Strukturiertes Error-Logging
- [x] Graceful WebSocket-Reconnect
- [x] API-Key-Management (Show/Hide)
- [x] Automatische Spracherkennung (First-Run)
- [x] Dark/Light Theme

## Lizenz

MIT
