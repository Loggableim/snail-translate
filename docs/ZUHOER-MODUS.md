# Zuhör-Modus (Guide Mode) — Implementierungsauftrag

> Übergib dieses Dokument zusammen mit dem Projektverzeichnis `snail/` an einen
> leistungsfähigen Coding-Agenten. **Voraussetzung:** Der Vorbereitungs-Prompt
> (`docs/ZUHOER-MODUS-VORBEREITUNG.md`) wurde ausgeführt und der Baseline-Bericht
> ist grün.
> Basis: Branch `agent/guide-mode`, Basis-Commit `398bb29`.
> Dieses Dokument ist ein **Arbeitsauftrag**: Der Agent analysiert nicht, er baut.

---

## 1. Rolle und Auftrag

Du implementierst den **Zuhör-Modus** für Snail: **ein Sprecher (Guide), N Zuhörer.**

Der Guide spricht in seiner Sprache. Sein Gerät transkribiert (ASR), übersetzt den
Text in jede angebotene Zuhörer-Sprache (MT) und sendet die Übersetzungen als
`subtitle`-Nachrichten über den Relay an alle Zuhörer. Jeder Zuhörer sieht die
Übersetzung in seiner Sprache als großen Untertitel und kann sie sich optional
lokal vorlesen lassen (flutter_tts). Fragen der Zuhörer laufen über den
vorhandenen Chat-Kanal zum Guide.

Der Auftrag umfasst **28 benannte Punkte** (`G-01` … `G-28`) in vier Phasen.
Er ist **kein Rewrite**: Relay, Worker, ASR-, MT- und Chat-Bausteine existieren;
der Kern der Arbeit ist der Umbau des Relays von strikt 1:1 auf 1:N, ein
Guide-Screen, ein Listener-Screen und die Protokoll-/Test-/l10n-Pflege.

### Ausgangslage, die du kennen musst

- Baseline (nach Vorbereitung): `flutter analyze` clean, `flutter test`
  198 grün / 1 skip, Worker-Vitest 24/24, DO-Vitest 24/24, `tsc --noEmit` clean,
  Protokoll-Drift-Check clean.
- Der Relay ist heute strikt 1:1: `hostSocket`/`guestSocket` als zwei Slots,
  `getPeer()` liefert genau einen Peer. Chat, PCM und Edit/Delete routen über
  `getPeer()`. Für N Zuhörer wird daraus eine Socket-Map mit Fan-out.
- Vorhandene Bausteine, die wiederverwendet werden (nicht neu bauen):
  - **ASR:** `FishAudioAsrService` + `SpeechTurnBuffer` (Muster:
    `_processFishAudio` in `standalone_screen.dart`); OpenAI-Realtime-
    Input-Transcript (`OpenAiRealtimeService.inputTranscript`,
    `takeCompletedTurns()`).
  - **MT:** `TranslationService.translate()` (OpenAI-Chat; Fish → MyMemory-Fallback).
  - **Chat:** `ChatService` + Relay-`chat`-Typ (Fan-out statt 1:1).
  - **QR/Code:** `QrImageView(data: roomId)`; `snail://`-Schema in `join_screen.dart`.
  - **l10n:** 9 ARB-Dateien, `flutter gen-l10n`.
- **Halluzinations-Guard:** `FishAudioAsrService.isImplausibleTranscript` MUSS
  auch im Guide-Pfad vor jeder Übersetzung greifen (Fish ASR erfindet bei
  Echo/Stille ganze Sätze — auf dem Gerät beobachtet).

---

## 2. Zielbild

### Datenfluss (v1)

```
Guide-Gerät
  Mikrofon → SpeechTurnBuffer → ASR (provider-spezifisch)
    → Quelltext (Halluzinations-Guard)
      → MT × N (parallel, Quellsprache übersprungen)
        → subtitle{targetLang: de|en|fr|…} ──┐
                                             │
Relay (Durable Object, mode="guide")         │
  hostSocket ──fan-out──→ listenerSockets (Map userId→ws, Cap 50)
                                             │
Zuhörer-Gerät                                │
  subtitle empfangen → eigene Sprache filtern → Untertitel (groß, Auto-Scroll)
                     → optional: flutter_tts (lokal, offline)
  Frage → chat → nur an den Guide
```

### Abgrenzung der Modi

| Modus | Sprecher | Empfänger | Übersetzung | Audio |
|---|---|---|---|---|
| Session (duo) | 2 (beide) | 2 | je Gerät, bidirektional | Live-PCM/P2P |
| Schnellübersetzer | 1 Gerät, 2 Mikros | 2 (am Tisch) | lokal | lokal |
| **Zuhör-Modus** | **1 (Guide)** | **N (Cap 50)** | **Guide-Gerät, MT×N** | **Untertitel + lokales TTS** |

---

## 3. Entscheidungen (gesetzt — vom Betreiber vor Übergabe änderbar)

| # | Entscheidung | Begründung |
|---|---|---|
| D1 | Übersetzung auf dem Guide-Gerät: ASR einmal, MT×N | Zuhörer brauchen **keinen** Key; nur Text fließt; skaliert auf 50+ |
| D2 | Alle Sprachen an alle Listener; Filter client-seitig | ~1 KB/Untertitel; Sprachwechsel live ohne Re-Subscribe; Original+Übersetzung parallel möglich |
| D3 | Listener-Cap **50**, kein Free/Paid-Split | kein Billing-Backend; Text-Fan-out ist für einen DO billig |
| D4 | v1-Audio: nur Untertitel + **lokales TTS** (flutter_tts) beim Listener; **kein PCM-Fan-out** | Bandbreite/CPU; latenzärmer; Zuhörer ist reines Display |
| D5 | Modus **fix bei Raum-Erstellung** (`duo`/`guide`); kein Mischen | unterschiedliche Routing-Semantik; Mischen wäre ein dritter Modus |
| D6 | Protokollversion bleibt **1**; neue Nachrichtentypen additiv | alte Clients ignorieren Unbekanntes; kein Bruch |
| D7 | Guide-Modus v1: Untertitel/Chat sind **Relay-Klartext** (keine E2E) | N-Wege-ECDH zu komplex; Inhalt ist öffentliche Rede |
| D8 | Guide-Provider v1: **Fish** (ASR) und **OpenAI** (Realtime-Input-Transkript); Gemini wird mit klarer Meldung abgelehnt | `TranslationService` kann für Gemini nicht übersetzen (`gemini_chat_translation_not_supported`) |
| D9 | Einstieg: neues **Home-Tile „Zuhör-Modus"** + Route `/guide` | Sichtbarkeit; Home-/Grid-Test wird mit angepasst |
| D10 | Arbeit auf Branch **`agent/guide-mode`** | als Einheit reviewbar |

---

## 4. Arbeitsregeln

1. **Toolchain ist portabel und vorgegeben.** Niemals `flutter` direkt aufrufen:
   `.\tools\flutter.ps1 analyze|test|build`. Worker: `cd worker; npx vitest run`.
   Durable Objects: `cd durable-object; npx tsc --noEmit; npx vitest run`.
   Protokoll: `node tools/generate-protocol.mjs` +
   `git diff --exit-code -- shared/dto/v1/generated flutter_app/lib/generated`.
2. **Commits klein und thematisch**, englische Einzeiler mit Scope-Präfix wie im
   Repo üblich (`feat(guide): …`, `fix(relay): …`, `test(relay): …`).
3. **Niemals einen Test abschwächen, um ihn grün zu bekommen.** Schlägt ein
   bestehender Test fehl, zuerst klären, ob er altes Verhalten festschreibt.
4. **Keine Secrets** in Code, Logs, Tests, Commits. `--no-verify` ist verboten.
5. **Nutzersichtbare Texte ausschließlich über ARB** — jeder neue String in
   **allen neun** `app_*.arb`, danach `flutter gen-l10n`. Deutsche Literale im
   Widget-Code sind ein Fehler.
6. **Warum-Kommentare bleiben erhalten** (insbesondere im Relay und im
   Android-Plugin).
7. **Dokumente mitziehen:** `README.md` und `zielbild.md` im selben Commit
   aktualisieren, wenn sich das Verhalten ändert.
8. **Phasenweise abnehmen:** Am Ende jeder Phase müssen alle sechs Checks
   (analyze, flutter test, worker vitest, DO vitest, DO tsc, Protokoll-Drift)
   grün sein, bevor die nächste Phase beginnt.
9. **Bei Unklarheit: dokumentieren, nicht raten.** Naheliegende Variante
   ausarbeiten, als Annahme im Commit kennzeichnen, im Abschlussbericht melden.

---

## 5. Ausdrückliche Nicht-Ziele

- **Kein PCM-/Audio-Fan-out** an Zuhörer (v1; Text + lokales TTS reichen).
- **Keine N-Sprecher** (Meeting-Modus) — der Guide-Modus ist einseitig.
- **Kein Server-MT** (der Worker übersetzt nicht; bleibt Guide-Gerät).
- **Keine Web-Zuhörer-UI** (Browser-Listener) — Tokens/Protokoll so bauen, dass
  eine Web-Seite später ein weiterer Listener-Client sein kann, aber nicht bauen.
- **Keine E2E-Verschlüsselung** für Guide-Untertitel/Chat (D7).
- **Kein Gemini-Guide** (D8).
- **Kein Modus-Mischen** (D5).
- **Kein Billing/Tier-Split** für Listener (D3).

---

## 6. Fundstellen (Stand `398bb29`)

| Bereich | Datei | Symbol |
|---|---|---|
| Relay-Zustand | `durable-object/src/SnailRelay.ts` | `interface SessionState` (~Z. 21) |
| Relay-Auth | " | `case "auth"` (~Z. 359); Rollen-Slots (~Z. 396–414) |
| Relay-Routing | " | `getPeer()` (~Z. 745); `broadcast()` (~Z. 781) |
| Relay-Chat | " | `case "chat"` (~Z. 459); `edit`/`delete` (~Z. 605/637) |
| Relay-Persistenz | " | `saveState()` (~Z. 799); `restoreSockets()` (~Z. 786); `cleanup()` (~Z. 851) |
| Relay-Konstanten | " | `MAX_*` (~Z. 99–105) |
| Token-Rolle | `durable-object/src/auth.ts` | `SessionTokenPayload` (~Z. 9); `validateSessionTokenForRoom` (~Z. 19) |
| Worker-Räume | `worker/src/index.ts` | `handleCreateRoom` (~Z. 320); `handleJoinRoom` (~Z. 386); Routen (~Z. 630) |
| DTO | `shared/dto/v1/messages.json` | `MessageType`-Enum |
| Protokoll-Gen | `tools/generate-protocol.mjs` | — |
| App-Session | `flutter_app/lib/models/session.dart`; `services/session_service.dart` | `class Session`; `createRoom` (~Z. 226), `joinRoom` (~Z. 277) |
| App-Relay | `flutter_app/lib/services/audio_service.dart` | `_onMessage` (~Z. 170–260) |
| App-Chat | `flutter_app/lib/services/chat_service.dart` | `sendChat` (~Z. 294) |
| Standalone-Pipeline | `flutter_app/lib/screens/standalone_screen.dart` | `_processFishAudio` (~Z. 510) |
| Turn-Buffer | `flutter_app/lib/services/speech_turn_buffer.dart` | `add`/`isTurnComplete`/`takeTurn` |
| ASR | `flutter_app/lib/services/fish_audio_asr_service.dart` | `transcribe`; `isImplausibleTranscript` |
| OpenAI | `flutter_app/lib/services/openai_realtime_service.dart` | `inputTranscript`; `takeCompletedTurns` |
| MT | `flutter_app/lib/services/translation_service.dart` | `translate` |
| Join | `flutter_app/lib/screens/join_screen.dart` | `_onDetect` (~Z. 59); `_roomIdFromQr` (~Z. 87) |
| Home/Routen | `flutter_app/lib/screens/home_screen.dart`; `lib/main.dart` | `_Dashboard` (~Z. 294); `routes` (~Z. 135) |
| Tests | `durable-object/src/relay.test.ts`; `worker/src/index.test.ts`; `flutter_app/test/home_screen_test.dart` | — |

---

## 7. Phase 1 — Relay & Worker: Multi-Listener-Infrastruktur

Ohne App testbar. **Phasen-Abnahme:** alle neuen Vitest-Fälle grün, `tsc` clean,
Protokoll-Drift-Check clean.

### G-01 — Modus im Relay-Zustand

- **Ziel:** `SessionState` bekommt `mode: "duo" | "guide"` (Default `"duo"`) und
  `listenerLanguages: string[]`. `/init` akzeptiert `mode` und
  `listenerLanguages`; `/status` liefert `mode` und `listenerCount`.
- **Fundstelle:** `SnailRelay.ts` — `SessionState` (~Z. 21), `/init` (~Z. 233),
  `/status` (~Z. 270).
- **Abnahme:** Test: `/init` mit `mode:"guide"` → `/status` zeigt `mode` +
  `listenerCount: 0`; ohne `mode` → `"duo"`.

### G-02 — Listener-Rolle in Auth

- **Ziel:** `auth.ts`: `SessionTokenPayload.role` → `"host" | "guest" | "listener"`;
  `validateSessionTokenForRoom` akzeptiert `listener`. Relay-Auth wird
  **Drei-Wege-Weiche**: host → `hostSocket`, guest → `guestSocket`,
  listener → `listenerSockets`-Map. Listener nur auf `mode === "guide"`
  (sonst `auth_error "Not a listening room"`); Gast-Token auf Guide-Raum →
  `auth_error` (Defense in Depth). Cap `MAX_LISTENERS = 50`; gleicher `userId`
  **ersetzt** den alten Socket (close 4002 „Replaced by new connection").
- **Fundstelle:** `auth.ts` (~Z. 9–28); `SnailRelay.ts` Auth-Case (~Z. 396–414);
  Konstanten (~Z. 99–105).
- **Achtung:** Der aktuelle `else`-Zweig weist jede Nicht-Host-Rolle dem
  Guest-Slot zu — ohne Drei-Wege-Weiche landet ein Listener-Token im Gast-Slot.
- **Abnahme:** Tests: Listener auf Duo-Raum → `auth_error`; 51. Listener →
  `auth_error`; Reconnect mit gleichem `userId` ersetzt den Socket; Cap zählt
  korrekt.

### G-03 — SocketAttachment + Hibernation-Restore

- **Ziel:** `SocketAttachment.peerRole` → `"host" | "guest" | "listener" | null`;
  `restoreSockets()` rekonstruiert `listenerSockets` aus `getWebSockets()`
  (Map `userId` → ws), sonst ist der Fan-out nach Hibernation tot.
- **Fundstelle:** `SnailRelay.ts` — `SocketAttachment` (~Z. 91–95),
  `restoreSockets()` (~Z. 786).
- **Achtung:** Der Test-Harness (`relay.test.ts`, `state()`) mockt
  `getWebSockets` nicht — Mock erweitern.
- **Abnahme:** Test: Socket mit Listener-Attachment → nach Restore im Fan-out.

### G-04 — Persistenz und Cleanup

- **Ziel:** `saveState()` schließt `listenerSockets` aus dem Persist-Objekt aus
  (Live-WebSocket-Objekte sind nicht serialisierbar); `cleanup()` schließt alle
  Listener-Sockets (4000 „Session ended").
- **Fundstelle:** `saveState()` (~Z. 799), `cleanup()` (~Z. 851).
- **Abnahme:** Test: Cleanup mit 2 Listenern → beide Sockets geschlossen,
  Storage geleert; `saveState` persistiert keine Socket-Objekte.

### G-05 — `subtitle`-Nachricht

- **Ziel:** Neuer Typ `subtitle` mit `{ messageId, text, sourceLang, targetLang,
  timestamp, senderId? }` (Text max. 2000 Zeichen). Host → Fan-out an alle
  Listener **und** Eintrag in `chatHistory` (Spät-Joiner erhalten so das
  Transkript über `chat_history`). Listener → `error "Only the host can send
  subtitles"`.
- **Fundstelle:** `ClientMessage`/`ServerMessage` (~Z. 43–72); `chat`-Case als
  Muster (~Z. 459–495).
- **Abnahme:** Test: Host-Subtitle → alle Listener + History-Eintrag;
  Listener-Subtitle → `error`.

### G-06 — `listener_joined` / `listener_left`

- **Ziel:** Bei Listener-Auth: `listener_joined` an den Host (mit `listenerId`,
  `count`); Listener erhält `auth_ok` + `chat_history` (wie Gast). Bei
  Disconnect: `listener_left` an den Host (`count`).
- **Abnahme:** Tests für Join/Leave-Zähler.

### G-07 — Guide-Routing

- **Ziel:** Im Guide-Modus:
  - `chat`/`edit`/`delete` vom **Host** → Fan-out an alle Listener; vom
    **Listener** → nur an den Host.
  - `end` nur Host (Listener → `error`).
  - `signal` von Listenern → `error` (kein P2P im Guide-Modus).
  - Binäre PCM-Frames im Guide-Modus → `error` (v1, D4).
  - `fish_tts_*` von Listenern → `error`.
  - Host-Disconnect → `peer_left` (`peerId "host"`) an alle Listener
    (Reconnect-Fenster; Inaktivitäts-Alarm räumt auf).
- **Abnahme:** Tests für jedes Routing.

### G-08 — Worker: Guide-Raum erstellen

- **Ziel:** `POST /api/rooms` akzeptiert `mode: "guide"` + `listenerLanguages:
  string[]` (validiert gegen die Sprachliste, 1–18 Einträge); `/init` an das DO
  enthält `mode` + `listenerLanguages`; Response enthält `mode`.
- **Fundstelle:** `worker/src/index.ts` — `handleCreateRoom` (~Z. 320–384).
- **Abnahme:** `index.test.ts`: Create mit `mode` → DO-Init-Request enthält
  `mode`; ungültige Sprache → 400.

### G-09 — Worker: `POST /api/rooms/:id/listen`

- **Ziel:** Listener-Token minten. Auth wie `/join`; Raum muss existieren (404)
  und Guide-Raum sein (409 „Not a listening room"); **Quota-Check übersprungen**
  (Zuhörer verbrauchen nichts); Rate-Limit wie `join`; Token-Rolle `"listener"`.
  Response: `roomId`, `sessionToken`, `relayUrl`, `sourceLang` (Guide-Sprache),
  `listenerLanguages`, `tier`.
- **Abnahme:** Tests: 404, 409, 200 mit `listener`-JWT-Rolle; kein Quota-Verbrauch.

### G-10 — Worker: `/join` auf Guide-Raum ablehnen

- **Ziel:** `/join` auf einem Guide-Raum → 409 mit
  `{ error, code: "guide_room_use_listen" }` (die App fällt darauf in den
  Listener-Flow, s. G-19).
- **Abnahme:** Test.

### G-11 — DTO + Protokoll-Generator

- **Ziel:** `shared/dto/v1/messages.json`: `MessageType` um `subtitle`,
  `listener_joined`, `listener_left` erweitern + Schemas;
  `node tools/generate-protocol.mjs` ausführen; CI-Drift-Check grün.
- **Abnahme:** Generator läuft; `git diff --exit-code -- shared/dto/v1/generated
  flutter_app/lib/generated` leer.

### G-12 — Phase-1-Tests

- **Ziel:** `relay.test.ts` + `index.test.ts` um die Fälle aus G-01…G-10
  erweitern; alle Suiten grün.
- **Abnahme:** `npx vitest run` in `worker/` und `durable-object/` grün;
  `tsc --noEmit` clean.

---

## 8. Phase 2 — Guide-Screen (Sprecher)

**Phasen-Abnahme:** alle sechs Checks grün; Widget-/Unit-Tests für die neuen
Screens.

### G-13 — SessionService + Session-Model

- **Ziel:** `Session` bekommt `mode` (`"duo" | "guide"`), Rolle kann `"listener"`
  sein; `SessionService.createGuideRoom({required List<String> listenerLanguages})`
  → `POST /api/rooms` mit `mode`; `SessionService.joinAsListener(String roomId)`
  → `POST /api/rooms/:id/listen`.
- **Abnahme:** Unit-Tests (Mock-HTTP) für beide Methoden; `Session.fromJson`
  parst `mode`.

### G-14 — Guide-Setup-Ansicht

- **Ziel:** `screens/guide_screen.dart` — Setup: Sprachen-Multi-Select (aus
  `models/translation_languages.dart`, mind. 1 Zielsprache), Provider-Anzeige +
  Key-Check (Fish/OpenAI ok; **Gemini → klare Meldung „Im Zuhör-Modus nicht
  verfügbar"**, D8), Start-Button. Route `/guide` in `main.dart` + Home-Tile
  (G-18).
- **Abnahme:** Widget-Test: Setup rendert, Gemini-Warnung erscheint, Start
  navigiert in die Lauf-Ansicht.

### G-15 — Guide-Pipeline

- **Ziel:** Mic-Capture (SnailAudio, Muster `standalone_screen.dart`) →
  provider-spezifische ASR:
  - **Fish:** `FishAudioAsrService` + `SpeechTurnBuffer` (Muster
    `_processFishAudio`, 250-ms-Timer, `_fishBusy`-Guard).
  - **OpenAI:** `OpenAiRealtimeService` — `inputTranscript` +
    `takeCompletedTurns()` (Output-Transcript/-Audio wird ignoriert).
  Halluzinations-Guard (`isImplausibleTranscript`) vor jeder Übersetzung.
  Danach **MT × N parallel** (`Future.wait`, `TranslationService.translate`),
  Sprachen == Quellsprache überspringen. Ergebnis → `sendSubtitle` (G-17).
- **Abnahme:** Unit-Test der Pipeline-Logik mit Fake-ASR/MT: Turn → N Subtitles,
  Quellsprache übersprungen, Guard verwirft unplausible Transkripte.

### G-16 — Guide-Lauf-Ansicht

- **Ziel:** QR (`QrImageView(data: roomId)`) + Code, Listener-Zähler, Live-
  Quelltext, Fragen-Liste (eingehende Listener-Chats aus `ChatService`),
  Stop-Button mit vollständigem Teardown + `PopScope` (Muster
  `session_screen.dart` — System-Back muss denselben Teardown auslösen).
- **Abnahme:** Widget-Test: Zähler aktualisiert sich, Stop räumt auf.

### G-17 — AudioService-Erweiterung

- **Ziel:** `sendSubtitle(...)`; `_onMessage`: `subtitle`-Empfang (Callback),
  `listener_joined`/`listener_left` → Zähler; im Guide-Modus **kein P2P-Start**
  und **kein ECDH** (`_configureConversationCrypto` nur bei duo, D7).
- **Abnahme:** Unit-Tests für Empfang/Zähler.

### G-18 — Home-Tile + Route

- **Ziel:** Home-Tile „Zuhör-Modus" (z. B. `Icons.campaign_rounded`), Route
  `/guide` in `main.dart`. **Pitfall:** Jede neue `pushNamed`-Zielroute MUSS in
  `main.dart` existieren, sonst Navigator-Crash.
- **Achtung:** `home_screen_test.dart` prüft, dass alle Tiles ohne Scrollen
  passen (9. Tile kann den No-Scroll-Test brechen). Grid-Metriken prüfen; falls
  nötig Kachelhöhe anpassen und den Test mit Begründung aktualisieren.
- **Abnahme:** `home_screen_test` grün; Tap auf das Tile → `/guide`.

---

## 9. Phase 3 — Listener-Screen (Zuhörer)

**Phasen-Abnahme:** alle sechs Checks grün; l10n-Parität; Widget-Tests.

### G-19 — Listener-Join

- **Ziel:** `join_screen.dart`: QR-Schema `snail://guide/<roomId>` → direkt in
  den Listener-Flow. Manueller Code auf einem Guide-Raum → `/join`-409-Code
  `guide_room_use_listen` → automatisch `joinAsListener` + **sichtbarer Hinweis**
  („Dies ist eine Zuhör-Session — du hörst jetzt zu"), keine stille Magie.
- **Abnahme:** Widget-Test: QR-Routing, Fallback bei 409.

### G-20 — Listener-Screen

- **Ziel:** `screens/listener_screen.dart` — Sprachwahl (nur Sprachen aus
  `listenerLanguages` des Raums, Default Gerätesprache), Untertitel-Liste (groß,
  Auto-Scroll via `ScrollController` + `jumpTo(maxScrollExtent)` im
  Post-Frame-Callback — Muster Chat-Auto-Scroll-Fix), TTS-Toggle,
  Frage-Button (Chat an den Host), Verbindungsstatus, „Guide spricht: X".
- **Abnahme:** Widget-Test: Untertitel erscheinen, Auto-Scroll folgt,
  Sprachwechsel filtert.

### G-21 — TTS-Disziplin (flutter_tts)

- **Ziel:** Nur **komplette Sätze** sprechen; Queue **verwerfen**, wenn Rückstand
  > N Sätze (kein 20-s-Nachlaufen); fehlendes Sprachpaket → **stiller Fallback**
  auf nur-Untertitel (kein Fehlerdialog); TTS stoppt beim Screen-Exit.
- **Abnahme:** Unit-Test der Queue-Logik mit Fake-TTS.

### G-22 — l10n

- **Ziel:** Alle neuen Strings in **allen neun** `app_*.arb` + `flutter gen-l10n`;
  keine deutschen Literale im Widget-Code; `localization_guard_test.dart` ggf.
  um die neuen Dateien erweitern.
- **Abnahme:** `gen-l10n` läuft; ARB-Paritätsskript grün.

### G-23 — flutter_tts-Integration

- **Ziel:** `pubspec.yaml` + `flutter pub get`; **AndroidManifest:** `<queries>`
  für `android.intent.action.TTS_SERVICE` (Android 11+ Paket-Sichtbarkeit —
  ohne diesen Eintrag findet die App keine TTS-Engine).
- **Abnahme:** Build läuft; Gerätetest in Phase 4.

---

## 10. Phase 4 — Politur & Verifikation

### G-24 — Kick (optional)

- **Ziel:** Host entfernt einen Listener: neuer Typ `listener_kick`
  (Host → Relay → Socket des Listeners schließen + `listener_left` an Host).
- **Abnahme:** Test.

### G-25 — Transkript-Export (optional)

- **Ziel:** Untertitel-Historie als Text teilen (Share-Intent).
- **Abnahme:** Widget-Test.

### G-26 — Gerätetest

- **Ziel:** Guide auf dem Nothing Phone 3a Pro (`A059P`, adb-Workflow s.
  Projekt-Doku) + Listener auf zweitem Gerät **oder Emulator** (Listener ist
  reines Display — Emulator reicht). Checkliste: Join per QR, Untertitel < 2 s,
  Sprachwechsel live, TTS an/aus, Frage → Guide, Host-Stop → Listener-UI,
  Reconnect des Listeners.
- **Abnahme:** Ausgefüllte Checkliste im Abschlussbericht; Logcat ohne Crashes.

### G-27 — Dokumente

- **Ziel:** `README.md` + `zielbild.md` im selben Commit wie das Feature
  aktualisieren (Modus-Tabelle, Status).
- **Abnahme:** Diff enthält beide Dateien.

### G-28 — Abschlussbericht

- **Ziel:** Bericht im Format von `docs/HAERTUNGS-STATUS.md`: Tabelle
  Befehl → Ergebnis, Liste der G-Punkte mit Status, offene Punkte, explizite
  „nicht verifiziert"-Zeile.
- **Abnahme:** Bericht liegt als `docs/ZUHOER-MODUS-STATUS.md` vor.

---

## 11. Bekannte Fallen (aus der Code-Analyse)

1. **Route vergessen** → Navigator-Crash (jede neue `pushNamed`-Zielroute in
   `main.dart` eintragen).
2. **`saveState()` + Live-Objekte:** `listenerSockets` MUSS aus dem
   Persist-Objekt ausgeschlossen werden, sonst Serialisierungsfehler.
3. **Hibernation:** `restoreSockets()` ohne Listener-Rekonstruktion = toter
   Fan-out nach jeder Hibernation.
4. **Auth-`else`-Zweig:** fängt Nicht-Host-Rollen in den Guest-Slot (s. G-02).
5. **`validateSessionTokenForRoom`** lehnt heute jede Rolle außer host/guest ab —
   Listener-Token würden mit „Invalid token role" scheitern.
6. **Protokoll-Drift:** Neue Typen MÜSSEN in `shared/dto/v1/messages.json` +
   Generator, sonst bricht CI.
7. **ARB ×9:** Jeder String in allen neun Dateien, dann `gen-l10n` — eine
   fehlende Locale bricht die Generierung.
8. **flutter_tts auf Android 11+:** `<queries>`-Eintrag für TTS_SERVICE nötig.
9. **Home-Grid-Test:** 9. Tile kann den No-Scroll-Test brechen (s. G-18).
10. **Kein ECDH im Guide-Modus:** `peer_joined` mit Agreement-Key gibt es nur im
    Duo-Modus; Guide-Chat bleibt Klartext (D7) — nicht versehentlich
    `_configureConversationCrypto` aufrufen.
11. **MyMemory-Tageslimit:** Fish-MT fällt auf MyMemory zurück (Free-Tier-Limit);
    für längere Sessions ist OpenAI-Chat-MT die belastbare Wahl. Im
    Abschlussbericht als Betriebsrisiko nennen.
12. **`_fishBusy`-Guard:** Die Guide-Pipeline darf pro Turn nur einmal
    transkribieren/übersetzen (Muster aus `standalone_screen.dart` übernehmen).
