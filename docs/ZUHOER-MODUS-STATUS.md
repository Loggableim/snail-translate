# Zuhör-Modus — Abschlussbericht

Stand: 2026-09-18, Branch `agent/guide-mode`, Basis-Commit `398bb29`.
Auftrag: `docs/ZUHOER-MODUS.md` (Punkte G-01 … G-28).

Dieser Bericht behauptet keinen Abschluss, solange der Gerätetest (G-26) nicht
nachgewiesen ist. Er belegt den implementierten und verifizierten Stand.

## Verifizierte Checks

| Check | Befehl | Ergebnis |
|---|---|---|
| Flutter-Analyse | `flutter analyze` (vendored SDK) | No issues found |
| Flutter-Tests | `flutter test` | **235 grün, 1 skip** (37 neue) |
| Worker-Tests | `cd worker && npx vitest run` | **33/33 grün** (9 neue) |
| DO-Typcheck | `cd durable-object && npx tsc --noEmit` | clean |
| DO-Tests | `cd durable-object && npx vitest run` | **43/43 grün** (19 neue) |
| Protokoll-Drift | `node tools/generate-protocol.mjs` + diff | keine Drift (22 Typen) |
| l10n-Parität | Skript über alle 9 `app_*.arb` | 0 fehlend / 0 überzählig |
| E2E Guide-Flow (lokal) | `python tools/desktop_test/e2e_guide.py http://127.0.0.1:8791` | **11/11 Checks** |
| E2E Guide-Flow (Produktion) | `python tools/desktop_test/e2e_guide.py https://snail-worker.pixstash.workers.dev` | **11/11 Checks** |
| Zwei-Geräte-Lauf | Phone-Guide + Desktop-Listener, lokaler Worker | **Untertitel angekommen** |
| Produktions-Deploy | `wrangler deploy --config wrangler.deploy.toml` | Version `580f8cab` live |

## Punkte-Status

### Phase 1 — Relay & Worker

| Punkt | Status | Evidenz |
|---|---|---|
| G-01 Modus im Relay-Zustand | ✅ | `SessionState.mode`/`listenerLanguages`; `/init`, `/status`; Test „reports mode and listener count" |
| G-02 Listener-Rolle in Auth | ✅ | Drei-Wege-Weiche in `SnailRelay.ts`; `auth.ts` akzeptiert `listener`; Tests: Duo-Room-Ablehnung, Cap 50, Reconnect ersetzt Socket |
| G-03 SocketAttachment + Hibernation | ✅ | `restoreSockets()` rekonstruiert die Map; Test „restores listener sockets from hibernation attachments" |
| G-04 Persistenz und Cleanup | ✅ | `saveState()` schließt `listenerSockets` aus; `cleanup()` schließt alle Listener; Tests |
| G-05 `subtitle`-Nachricht | ✅ | Host-only, Fan-out, History-Eintrag; Tests inkl. Spät-Joiner-Transkript |
| G-06 `listener_joined`/`listener_left` | ✅ | Zähler-Test (1, 2 → left 1) |
| G-07 Guide-Routing | ✅ | chat/edit/delete/voice-Fan-out, Listener→Host, signal/PCM/end/fish_tts abgelehnt, Host-Disconnect → `peer_left`; Tests |
| G-08 Worker: Guide-Raum erstellen | ✅ | `mode` + `listenerLanguages` validiert (1–18, gegen die 18 App-Sprachen); Tests inkl. 400-Fälle |
| G-09 Worker: `/listen` | ✅ | Listener-Token ohne Quota; 404/409-Fälle; JWT-Rolle geprüft |
| G-09b Worker: `GET /api/rooms/:id/status` | ✅ | Öffentlicher Status (mode, sourceLang, listenerLanguages, listenerCount) ohne Auth; nur Routing-Metadaten; Tests inkl. 404 |
| G-10 Worker: `/join` auf Guide-Raum | ✅ | 409 + `code: "guide_room_use_listen"` |
| G-11 DTO + Protokoll-Generator | ✅ | 3 neue Typen + Schemas; Generator läuft; keine Drift |
| G-12 Phase-1-Tests | ✅ | DO 37/37, Worker 31/31, tsc clean |

### Phase 2 — Guide-Screen

| Punkt | Status | Evidenz |
|---|---|---|
| G-13 SessionService + Session-Model | ✅ | `mode`, `listenerLanguages`, `createGuideRoom`, `joinAsListener`; 8 Unit-Tests |
| G-14 Guide-Setup-Ansicht | ✅ | Sprachen-Multi-Select, Provider-Guard (Gemini abgelehnt), Start; 3 Widget-Tests |
| G-15 Guide-Pipeline | ✅ | `GuidePipeline` (eigene Einheit): Fish: `SpeechTurnBuffer` + `FishAudioAsrService` + Halluzinations-Guard; OpenAI: `takeCompletedTurns()`; MT × N parallel via `Future.wait`, Quellsprache übersprungen; **6 Unit-Tests mit Fake-MT** (Parallelität, Guard, Fehlerpfad) |
| G-16 Guide-Lauf-Ansicht | ✅ | QR + Code + Zähler + Quelltext + Fragenliste + Stop; `PopScope`-Teardown |
| G-17 AudioService-Erweiterung | ✅ | `sendSubtitle`, `subtitle`/`listener_joined`/`listener_left`, `listenerCount`; kein P2P/ECDH im Guide-Pfad |
| G-18 Home-Tile + Route | ✅ | Tile „Zuhör-Modus" → `/guide`; Grid auf 9 Tiles umgepackt (2×5, 3×4, 5×2); `home_screen_test` 18/18 |

### Phase 3 — Listener-Screen

| Punkt | Status | Evidenz |
|---|---|---|
| G-19 Listener-Join | ✅ | `snail://guide/<room>`-Schema; 409-Fallback mit sichtbarem Hinweis |
| G-20 Listener-Screen | ✅ | Sprachwahl nur aus `listenerLanguages`, Auto-Scroll-Untertitel, TTS-Toggle, Status, **Frage-Eingabe** (Chat an den Host); 5 Widget-Tests |
| G-21 TTS-Disziplin | ✅ | `TtsQueuePolicy` (eigene Einheit): nur komplette Sätze, Queue-Verwerfung bei Rückstand, Slot-Freigabe bei Engine-Fehler, stiller Fallback ohne Sprachpaket, Stop beim Exit; **7 Unit-Tests mit Fake-TTS** |
| G-22 l10n | ✅ | 29 Keys × 9 Locales, Parität 0/0, `gen-l10n` läuft |
| G-23 flutter_tts-Integration | ✅ | `pubspec.yaml` + `<queries>` für `TTS_SERVICE` im Manifest |

### Phase 4 — Politur & Verifikation

| Punkt | Status | Evidenz |
|---|---|---|
| G-24 Kick | ✅ | `listener_kick` (host-only, guide-only) → `listener_kicked` an das Ziel, Socket geschlossen, Zähler aktualisiert; Tests inkl. Ablehnung durch Listener und unbekannter ID |
| G-25 Transkript-Export | ✅ | Guide kopiert die gesammelten Quellzeilen per Clipboard; Button erscheint erst mit Inhalt |
| G-26 Gerätetest | ✅ **Protokoll-Flow verifiziert** | s. „Gerätetest" |
| G-27 Dokumente | ✅ | `README.md` (Modus-Tabelle, Endpoints, Features) + `zielbild.md` (Punkte 60–65) |
| G-28 Abschlussbericht | ✅ | diese Datei |

## Gerätetest (G-26)

### Guide-Hälfte — auf Hardware (Nothing Phone 3a Pro, Android 16)

- App startet, Home-Dashboard rendert **alle neun Tiles** inklusive „Zuhör-Modus".
- Tap auf das Tile öffnet den Guide-Setup-Screen: Erklärung, alle 18 Sprach-Chips, Start-Button.
- Sprachwahl + Start → **Lauf-Ansicht erscheint**: QR-Code, Raumcode, Zähler, Quelltext-Bereich, Fragenliste, Stop-Button.
- Mikrofon-Capture läuft (`SnailAudio: Standalone capture started; phone=true, aec=true, ns=true`).
- **Kein Crash** über die gesamte Session.

### Protokoll-Flow — end-to-end gegen echte Infrastruktur

`tools/desktop_test/e2e_guide.py` fährt den kompletten Guide-Flow gegen einen
laufenden Worker: Raum anlegen, öffentlicher Status, Gast-Join-Ablehnung,
Guide- und Listener-Auth, Listener-Benachrichtigung, Untertitel-Fan-out,
Publish-Ablehnung für Listener, Transkript für Spät-Joiner.

**Ergebnis: 11/11 Checks — lokal (`wrangler dev`) und gegen Produktion
(`snail-worker.pixstash.workers.dev`).** Damit ist der Zwei-Geräte-Flow auf
Protokollebene vollständig nachgewiesen, inklusive WebSocket-Fan-out über das
echte Relay.

### Zwei-Geräte-Lauf — auf Hardware

Guide auf dem Nothing Phone 3a Pro, Listener als Desktop-Client, beide gegen
einen lokalen Worker (`adb reverse` leitet Phone-localhost auf den PC).

**Ergebnis: der komplette Flow läuft.** Das Phone-Mikrofon nimmt Sprache auf,
Fish ASR transkribiert, die Übersetzung (de→en) wird als `subtitle` über den
Relay gefan-out, und der Listener empfängt sie:

```
src=de -> tgt=en: yeah, yeah, one more thing.
src=de -> tgt=en: why? oh, because that effect is already slow.
src=de -> tgt=en: This is kind of meaningful, and this is why.
```

Der Guide zeigte live „1 Zuhörer verbunden", den Zähler, die Fragenliste und
den „Transkript kopieren"-Button; der Listener-Chip mit „Zuhörer entfernen"
war sichtbar.

**Dabei gefunden und behoben:** Die Capture-Subscription wurde registriert,
bevor `_running` gesetzt war — der Listener verwirft Frames, solange
`_running` false ist, also gingen die ersten Turns verloren. Auf dem Gerät
zeigte sich das als „Warte auf Sprache …", obwohl das Mikrofon nachweislich
lief.

**Offener Qualitätsbefund:** Fish ASR halluziniert bei Hintergrundgeräuschen
in **lateinischer Schrift** — beobachtet wurden tschechische Sätze
(„šápy třeba jsou zemným výrobem", „Víš, jak mám resti kvalních spal") in
einem deutschen Gespräch. Der bestehende `isImplausibleTranscript`-Guard
prüft die Schrift und greift hier **nicht**, weil Tschechisch wie Deutsch
lateinisch ist. Für den Betrieb heißt das: In lauter Umgebung können falsche
Sätze im Transkript landen. Eine Sprach-Erkennung pro Turn (Fish liefert
`language`) oder ein Plausibilitäts-Check gegen die erwartete Sprache wäre
der nächste Schritt.

### Desktop-Hälfte — als Testvehikel

Die Windows-App läuft, enumeriert **13 echte Mikrofone** und startet Capture
ohne Fehler. Sie diente als Ersatz für ein zweites Gerät.

**Nicht durchgeführt:** ein manueller Klick-Durchlauf beider Geräte mit echter
Sprachausgabe (Mikrofon → ASR → MT → Untertitel auf einem zweiten Bildschirm).
Die UI-Interaktion auf Desktop ist über Skripte nur eingeschränkt steuerbar
(Fokus-Verhalten von Flutter-Windows-Fenstern), daher wurde der Flow auf
Protokollebene verifiziert statt per Klick.

## Nicht verifiziert

- **Kein Live-Provider-Test für OpenAI/Gemini.** Der Fish-Pfad lief auf
  Hardware (s. „Zwei-Geräte-Lauf"); die OpenAI- und Gemini-Pfade der
  Guide-Pipeline wurden nur gegen Fakes getestet.
- **ASR-Halluzination in lateinischer Schrift.** Beim Zwei-Geräte-Lauf
  erkannte Fish ASR tschechische Sätze aus Hintergrundgeräuschen in einem
  deutschen Gespräch; der Schrift-basierte Guard greift dort nicht. Details
  im Abschnitt „Zwei-Geräte-Lauf".
- **Kein Lasttest mit vielen Zuhörern.** Alle Läufe nutzten einen oder zwei
  Listener; das Verhalten bei 50 (Cap) ist nicht geprüft.

## Betriebsrisiken

1. **MyMemory-Tageslimit.** Der Fish-MT-Pfad fällt auf MyMemory zurück
   (Free-Tier). Für längere Guide-Sessions ist OpenAI-Chat-MT die belastbare
   Wahl; bei vielen Zuhörer-Sprachen multipliziert sich die MT-Last pro Satz.
2. **Kein E2E im Guide-Modus (D7).** Untertitel und Chat sind Relay-Klartext.
   Das ist für öffentliche Rede vertretbar, aber nicht für Vertrauliches.
3. **TTS-Qualität.** `flutter_tts` nutzt die System-Engine: Stimme und
   Verfügbarkeit hängen vom Gerät ab; fehlende Sprachpakete degradieren still
   auf Untertitel.

## Arbeitsbaum

- Branch `agent/guide-mode` von `agent/snail-architecture` (`398bb29`).
- Vorbestehende Fremd-Änderungen wurden separat committet:
  `680acd6` (Fish-TTS-Hibernation-Restore), `e3b4cd5` (Session-Fremdsprachen-Guard).
- Der Alt-Test-Fix aus dem Vorbereitungs-Prompt: `50f9ed8`.
- Untracked geblieben: `.tmp-*`-Debug-Artefakte, `docs/HAERTUNGS-MASTERPROMPT.md`,
  `docs/ZUHOER-MODUS*.md`, `docs/guide-mode.md`.

## Nebenfund

Die neuen Widget-Tests deckten **zwei vorbestehende Dispose-Bugs** auf:

1. `OpenAiRealtimeService.disconnect()` rief `notifyListeners()` nach
   `dispose()` auf („used after being disposed"). Behoben mit dem
   `_disposed`-Guard, den `GeminiLiveService` bereits hatte.
2. `AudioService` hatte **gar kein** `dispose()`-Override und `disconnect()`
   notifizierte bedingungslos — ein Screen, der beim Teardown trennt, warf
   „A AudioService was used after being disposed". Guard + Override ergänzt.

Zusätzlich: Der Kick-Handler riss den Widget-Tree **innerhalb** des
Socket-Dispatch ab und löste „setState() called when widget tree was locked"
aus; der Callback wird jetzt per `scheduleMicrotask` verzögert und der Hinweis
nach dem Teardown gezeigt.
