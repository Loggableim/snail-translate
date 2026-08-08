# Snail — Echtzeit-Konversationsübersetzer

> Zwei Personen mit je einem Headset. Die App erkennt, wer spricht,
> übersetzt das Gespräch live und gibt es dem jeweils anderen in seiner
> Sprache aus. Ideal für Reisen.

## Status

- **Phase:** Konzept / Architektur (kein Code)
- **Plattform:** Flutter (Android jetzt, iOS später)
- **Doku:** [`ARCHITEKTUR.md`](ARCHITEKTUR.md)

## Projektstruktur

```
snail/
├── ARCHITEKTUR.md      # Architektur-Konzept
├── README.md           # Dieses Dokument
├── docs/               # Weitere Doku (API, Setup, Entscheidungen)
│   └── designs/        # UI-Mockups
├── app/                # Flutter-App (wird angelegt, sobald Flutter installiert)
└── backend/            # Cloudflare Worker (Key-Vault + Tier-Gateway)
```

## Nächste Schritte

1. Flutter SDK installieren
2. Cloudflare Worker-Skeleton (Key-Vault, Clerk-Auth, Tier-Quota)
3. Clerk-Integration in der Flutter-App
4. Pipeline-Prototyp (Mikro → VAD → STT → Übersetzung → TTS → Playback)

## Stack-Übersicht

| Baustein | Free Tier | Paid Tier |
|----------|-----------|-----------|
| Frontend | Flutter (Android → iOS) | Flutter (Android → iOS) |
| Backend | Cloudflare Worker (JS/TS) | Cloudflare Worker (JS/TS) |
| Auth | Clerk | Clerk |
| VAD | Silero (lokal) | Silero (lokal) |
| STT | Whisper API | Deepgram (Streaming) |
| Übersetzung | Google Translate | DeepL |
| TTS | Edge-TTS | fish.audio (s2-pro) |
| Transport | WebSocket / WebRTC | WebSocket / WebRTC |
