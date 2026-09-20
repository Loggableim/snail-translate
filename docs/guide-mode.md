# Guide‑Mode (Zuhör‑Modus)

## Ziel
Der Guide‑Mode ermöglicht **1 Sprecher → N Zuhörer**. Der Sprecher übersetzt seine Sprache in mehrere Zielsprachen und die Zuhörer sehen die Untertitel (und optional TTS). Der Modus ist komplett **client‑seitig** ohne Server‑Kosten für die Zuhörer.

## Architektur‑Übersicht

```
Guide‑Handy (ASR → MT×N → Relay → Fan‑out)
   |
   | 1:1 WebSocket (hostSocket)
   V
Relay‑DO (SnailRelay)
   |
   | fan‑out 1:n WebSocket (listenerSockets)
   V
Zuhörer‑Handy / Web‑Client (Untertitel + optional TTS)
```

### 1. Relay‑DO
* **SessionState** erweitert um:
  * `mode: "guide" | "duo"`
  * `listenerSockets: Map<string, WebSocket>` – Schlüssel: `listenerId`
  * `maxListeners: number` – Cap (default 50)
* Auth‑Rolle `listener` (Token‑Payload: `{sub, room, role: "listener", tier}`)
* `chat`‑Case: Host → fan‑out an alle Listener, Listener → nur an Host
* Neuer `subtitle`‑Case: Host → fan‑out an alle Listener, History‑Persistenz (für spätere Joins)
* `getPeer()` bleibt host/guest, neue `getListener()` liefert Map‑Eintrag
* `restoreSockets()` rekonstruiert `listenerSockets` aus `SocketAttachment` (Cap‑Check)
* `cleanup()` schließt alle Listener‑Sockets, löscht `listenerSockets`

### 2. Worker
* `POST /api/rooms` → `mode` optional (default `duo`), `listenerLanguages[]`
* `POST /api/rooms/:id/listen` → Listener‑Token erzeugen, keine Quota‑Check
* `GET /api/rooms/:id/status` → `mode`, `listenerCount`

### 3. Guide‑App
* `SessionService.createGuideRoom(languages)` → ruft Worker auf, bekommt `roomId`, `relayUrl`, `sessionToken`
* `audio_service.dart` → neue Methode `joinAsGuide(Session)`
  * startet ASR → `SpeechTurnBuffer`
  * bei `turnComplete` → `translate( text, sourceLang, targetLangs )`
  * `subtitle`‑Message an Relay
  * `chat`‑Message für Fragen
* UI: `GuideScreen` – QR‑Code, Listener‑Zähler, Untertitel‑Liste, Fragen‑Button

### 4. Listener‑App
* `SessionService.joinAsListener(roomId)` → ruft Worker auf, bekommt `relayUrl`, `sessionToken`
* `audio_service.dart` → neue Methode `joinAsListener(Session)`
  * setzt `onSubtitle`‑Callback: zeigt Untertitel in der gewählten Sprache
  * optional `flutter_tts` für TTS (Toggle)
  * UI: `ListenerScreen` – Untertitel‑View, TTS‑Toggle, Frage‑Button

## Datenformate

> **Hinweis:** Dieses Dokument war der erste Entwurf. Die maßgebliche
> Spezifikation ist `docs/ZUHOER-MODUS.md`; das umgesetzte Verhalten ist in
> `docs/ZUHOER-MODUS-STATUS.md` belegt. Das Subtitle-Format unten wurde
> entsprechend korrigiert.

* **Subtitle‑Message** — eine Nachricht **pro Zielsprache** (nicht eine
  Nachricht mit allen Übersetzungen). Der Relay fächert jede einzeln an alle
  Listener auf; jeder Listener filtert lokal nach `targetLang`. Das hält den
  Sprachwechsel zur Laufzeit ohne Re-Subscribe möglich und erlaubt es einem
  Listener, Original und Übersetzung parallel zu sehen.
  ```ts
  type SubtitleMessage = {
    type: "subtitle";
    messageId: string;
    text: string;          // translated text for targetLang
    sourceLang: string;    // e.g. "de"
    targetLang: string;    // e.g. "en"
    senderId?: string;
    timestamp: number;
  };
  ```
  Text ist auf 2000 Zeichen begrenzt. Nur der Host darf senden; ein Listener
  erhält `error "Only the host can send subtitles"`. Jede Subtitle landet
  zusätzlich in `chatHistory`, damit Spät-Joiner das Transkript über
  `chat_history` erhalten.
* **Chat‑Message** bleibt unverändert, aber `role` = `listener` → nur an Host.

## Cap‑Check & Sicherheit
* Listener‑Tokens werden **nicht** mit User‑Auth verknüpft – sie sind temporär (max 30 min). `SNAIL_RELAY` prüft `maxListeners` und lehnt neue Listener ab, wenn die Cap erreicht ist.
* Alle Listener‑Sockets werden in `listenerSockets` gespeichert, damit `cleanup()` sie sauber schließen kann.
* `SessionService` prüft, dass der Guide die `mode`-Eigenschaft des Sessions korrekt hat.

## Tests
* **Unit** (vitest):
  * `SnailRelay` – `subtitle`‑fan‑out, Cap‑Check, `getListener()`
  * `Worker` – `POST /api/rooms` mit `mode=guide`, `listen`‑Endpoint
* **Integration** (Flutter test):
  * Guide‑Screen → Untertitel‑Streaming
  * Listener‑Screen → Untertitel‑Anzeige + TTS‑Toggle

## Nächste Schritte

Alle Schritte sind erledigt — der Modus ist implementiert, getestet und
deployt:

1. ~~Design‑Doc fertigstellen~~ → dieses Dokument, plus die maßgebliche
   Spezifikation `docs/ZUHOER-MODUS.md`.
2. ~~Relay‑DO~~ → `mode`, `listenerSockets`, Listener-Rolle, `subtitle`-Fan-out,
   Hibernation-Restore, Cleanup.
3. ~~Worker~~ → `mode=guide` bei der Raum-Erstellung, `POST /api/rooms/:id/listen`,
   `GET /api/rooms/:id/status`, Guide-Room-Guard auf `/join`.
4. ~~Flutter‑App~~ → `GuideScreen`, `ListenerScreen`, Home-Tile, QR-Routing,
   Desktop-Support.
5. ~~Tests~~ → 43 DO-Tests, 33 Worker-Tests, 235 Flutter-Tests, 11/11
   E2E-Checks lokal und in Produktion, Zwei-Geräte-Lauf auf Hardware.

Details und die verbleibenden offenen Punkte: `docs/ZUHOER-MODUS-STATUS.md`.

## Hinweise
* Der Guide‑Mode ist **nicht** ein Sub‑Modus von `duo`. Es ist ein eigener Modus, weil die Logik (1 → N) nicht mit 1 ↔ 1‑Übersetzung zusammenpasst.
* Für die erste Version bleibt der Guide‑Mode **free** – keine Quota‑Kosten. Listener brauchen keinen Key.
* TTS‑Fallback: Falls `flutter_tts` nicht verfügbar ist, wird nur der Untertitel angezeigt.

---

**Autor:** `logga` – 2026‑09‑18

**Status:** Umgesetzt. Maßgebliche Spezifikation: `docs/ZUHOER-MODUS.md`.
Umsetzungsnachweis: `docs/ZUHOER-MODUS-STATUS.md`.