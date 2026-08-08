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
├── app/                # Flutter-App (wird angelegt, sobald Flutter installiert)
└── backend/            # Python/FastAPI-Backend (STT/TTS/Übersetzung)
```

## Nächste Schritte

1. Flutter SDK installieren
2. Flutter-Projekt in `app/` anlegen
3. Backend-Skeleton in `backend/` anlegen
4. Pipeline-Prototyp (Mikro → VAD → STT → Übersetzung → TTS → Playback)

## Stack-Übersicht

| Baustein | Lösung |
|----------|--------|
| Frontend | Flutter (Android → iOS) |
| Backend | Python / FastAPI |
| VAD | Silero (lokal) |
| STT + Diarization | Deepgram (Streaming) |
| Übersetzung | DeepL / LLM |
| TTS | fish.audio (s2-pro) |
| Transport | WebSocket / WebRTC |
