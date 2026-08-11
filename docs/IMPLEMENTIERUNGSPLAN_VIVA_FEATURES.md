# Snail — Implementierungsplan: Viva-Translate-Features

> **Ziel:** Produktreife Test-App mit Audio-Pipeline, Multi-Provider-Fallback, Error-Handling und Entwickler-Dokumentation.
> **Ausführender Agent:** Lies diesen Plan vollständig, dann arbeite ihn Schritt für Schritt ab. Prüfe nach jedem Schritt das Ergebnis, bevor du fortfährst.

---

## Zielbild

Eine Flutter-Test-App (Android), die ohne externen Login sofort nutzbar ist:

1. **Audio-Capture** mit clientseitigem PCM-Resampling (16kHz → 8kHz) und S16LE-Konvertierung via `AudioWorkletProcessor`-Äquivalent (Flutter Platform Channel)
2. **Multi-Provider-STT-Fallback:** Groq Whisper → Deepgram Nova-2 → OpenAI Whisper (automatisch, mit Latenz-Logging)
3. **API-Key-Management:** Keine produktiven Keys im Quelltext. Entwicklung nutzt Build-Time-Variablen; produktiv kommen Clerk-Auth, kurzlebige Realtime-Secrets und lokale BYOK-Konfiguration zum Einsatz.
4. **First-Run-Defaults:** Gerätesprache via `Locale.getDefault()` erkennen, als Quellsprache setzen
5. **Strukturiertes Error-Logging:** Jeder Fehler mit Timestamp, Provider, Kontext → lokal gespeichert + in UI einsehbar
6. **Graceful Retry:** WebSocket-Reconnect mit exponentiellem Backoff (1s, 2s, 4s, 8s, max 30s)
7. **Transkript-History:** Alle Transkripte + Übersetzungen pro Session speichern, in History-Screen anzeigen
8. **Entwickler-README:** Setup, Architektur, API-Referenz

---

## Build-Time- und Secure-Storage-Konfiguration

```dart
// In services/api_keys.dart
const GROQ_API_KEY = "<set via secret store or environment>";
const FISHAUDIO_API_KEY = "<set via secret store or environment>";
const DEEPGRAM_API_KEY = "<set via secret store or environment>";
const OPENAI_API_KEY = "<set via secret store or environment>";
const DEV_API_KEY = "<set via secret store or environment>";
const WORKER_URL = "https://snail-worker.pixstash.workers.dev";
```

---

## Schritt 1: `api_keys.dart` — Build-Time-Konfiguration

**Datei:** `flutter_app/lib/services/api_keys.dart`

```dart
/// Hardcoded API keys for Snail test app.
/// DO NOT COMMIT TO PUBLIC REPOSITORY.
class ApiKeys {
  static const groq = "<set via secret store or environment>";
  static const fishaudio = "<set via secret store or environment>";
  static const deepgram = "<set via secret store or environment>";
  static const openai = "<set via secret store or environment>";
  static const devApiKey = "<set via build-time environment>";
  static const workerUrl = "<set via build-time environment>";
}
```

**Prüfung:** `flutter build apk --release` muss ohne Fehler durchlaufen.

---

## Schritt 2: `error_logger.dart` — Strukturiertes Error-Logging

**Datei:** `flutter_app/lib/services/error_logger.dart`

**Anforderungen:**
- Singleton `ErrorLogger` mit `log(provider, context, error, stackTrace)`
- Jeder Eintrag: `{timestamp, provider, context, message, stackTrace}`
- In-Memory-Liste (max 200 Einträge) + optional File-Persistenz
- Methode `getLogs()` → `List<ErrorEntry>`
- Methode `clearLogs()`
- Methode `exportLogs()` → String (JSON)

**Provider-Typen:** `"groq"`, `"deepgram"`, `"openai"`, `"fishaudio"`, `"websocket"`, `"audio"`, `"api"`

**Kontext-Beispiele:** `"stt.transcribe"`, `"mt.translate"`, `"tts.synthesize"`, `"ws.connect"`, `"ws.auth"`, `"audio.capture"`

**Prüfung:** Logge einen Test-Fehler und rufe `getLogs()` auf → muss den Eintrag enthalten.

---

## Schritt 3: `audio_processor.dart` — PCM-Resampling + S16LE

**Datei:** `flutter_app/lib/services/audio_processor.dart`

**Anforderungen:**
- Statische Methode `resample(Float32List input, int inRate, int outRate) → Float32List`
  - Lineare Interpolation (wie Viva's `resample()`)
- Statische Methode `toS16LE(Float32List samples) → Int16List`
  - Clamping auf [-1, 1], dann `s < 0 ? s * 0x8000 : s * 0x7FFF`
- Statische Methode `processAudioChunk(Uint8List rawPcm, int inRate, int outRate) → Uint8List`
  - Konvertiert raw PCM → Float32 → resample → S16LE → bytes

**Prüfung:** Unit-Test mit bekanntem Sinus-Signal (1kHz, 16kHz → 8kHz). Ausgabe muss halbe Sample-Anzahl haben.

---

## Schritt 4: `session_service.dart` — First-Run-Defaults + getUILanguage

**Datei:** `flutter_app/lib/services/session_service.dart` (bestehende Datei erweitern)

**Änderungen:**
- `static String detectMyLanguage()` → `Platform.localeName` parsen, auf unterstützte Sprachen mappen
- Beim ersten App-Start: `SharedPreferences` prüfen ob `first_run` key existiert
- Wenn First-Run: `myLanguage` auf `detectMyLanguage()` setzen, in SharedPreferences speichern
- `createRoom()` nutzt die gespeicherte Sprache als `sourceLang`

**Unterstützte Sprachen:** de, en, fr, es, it, ja, ko, zh

**Prüfung:** App deinstallieren → neu installieren → Sprache sollte automatisch erkannt werden.

---

## Schritt 5: `audio_service.dart` — Graceful Retry + Error-Logging

**Datei:** `flutter_app/lib/services/audio_service.dart` (bestehende Datei erweitern)

**Änderungen:**
- WebSocket-Reconnect mit exponentiellem Backoff:
  ```dart
  static const _reconnectDelays = [1, 2, 4, 8, 15, 30]; // seconds
  int _reconnectAttempt = 0;
  ```
- Bei `_onDone` oder `_onError`: automatischer Reconnect mit `_reconnectDelays[_reconnectAttempt]`
- Bei erfolgreichem Reconnect: `_reconnectAttempt = 0`
- Bei `auth_error`: KEIN Reconnect (Token-Problem)
- Alle Fehler via `ErrorLogger.log()` protokollieren
- Methode `isReconnecting` → bool

**Prüfung:** Worker stoppen → App zeigt "Reconnecting..." → Worker starten → App verbindet automatisch.

---

## Schritt 6: `transcript_history.dart` — Transkript-Speicherung & History

**Datei:** `flutter_app/lib/services/transcript_history.dart`

**Anforderungen:**
- `TranscriptEntry` Model: `{id, sessionId, timestamp, sourceLang, targetLang, originalText, translatedText, audioPath}`
- `TranscriptHistory` Service (ChangeNotifier):
  - `addEntry(entry)` → speichert in `SharedPreferences` (JSON-Liste)
  - `getEntries()` → `List<TranscriptEntry>`
  - `getEntriesForSession(sessionId)` → gefiltert
  - `clearHistory()`
  - Max 500 Einträge (älteste löschen)
- In `SessionScreen`: nach jeder erfolgreichen Übersetzung `TranscriptHistory.addEntry()` aufrufen

**Prüfung:** Session durchführen → History-Screen öffnen → Einträge müssen sichtbar sein.

---

## Schritt 7: `history_screen.dart` — History-UI

**Datei:** `flutter_app/lib/screens/history_screen.dart`

**Anforderungen:**
- `ListView.builder` mit allen Einträgen (neueste zuerst)
- Jeder Eintrag: Original-Text (fett), Übersetzung (darunter), Sprache + Timestamp (rechts)
- Swipe-to-delete (mit Bestätigungsdialog)
- "Alle löschen" Button in AppBar
- Leerer State: "Keine Transkripte" mit Icon

**Prüfung:** Navigation von Home-Screen aus erreichbar. Einträge sichtbar. Löschen funktioniert.

---

## Schritt 8: `settings_screen.dart` — API-Key-Show/Hide + Error-Log-Viewer

**Datei:** `flutter_app/lib/screens/settings_screen.dart` (bestehende Datei erweitern)

**Änderungen:**
- Neue Sektion "API-Keys" mit ListTile pro Provider:
  - Groq, Deepgram, OpenAI, fish.audio
  - Jeder: Key-Name + "●●●●●●●●" (maskiert) + Eye-Icon zum Toggle
  - Bei Toggle: Klartext anzeigen
- Neue Sektion "Fehlerprotokoll":
  - ListTile "Fehlerprotokoll anzeigen" → navigiert zu `error_log_screen.dart`
  - ListTile "Protokoll exportieren" → teilt JSON-Datei
  - ListTile "Protokoll löschen" → mit Bestätigung

**Prüfung:** Keys sind maskiert. Eye-Toggle zeigt Klartext. Error-Log-Viewer erreichbar.

---

## Schritt 9: `error_log_screen.dart` — Error-Log-Viewer

**Datei:** `flutter_app/lib/screens/error_log_screen.dart`

**Anforderungen:**
- `ListView` mit allen Error-Einträgen (neueste zuerst)
- Jeder Eintrag: Provider-Badge (farbig), Timestamp, Kontext, Fehlermeldung
- Tap auf Eintrag → expandiert mit StackTrace
- "Exportieren" Button → JSON-Datei teilen
- "Löschen" Button → mit Bestätigung

**Prüfung:** Fehler provozieren (z.B. Worker-URL falsch setzen) → Error-Log muss Eintrag zeigen.

---

## Schritt 10: `main.dart` — History-Screen registrieren

**Datei:** `flutter_app/lib/main.dart`

**Änderung:** Route `/history` → `HistoryScreen` hinzufügen.

---

## Schritt 11: `home_screen.dart` — History-Button

**Datei:** `flutter_app/lib/screens/home_screen.dart`

**Änderung:** "Verlauf" ActionCard unter "Session beitreten" hinzufügen.

---

## Schritt 12: Entwickler-README

**Datei:** `README.md` (Projekt-Root)

**Inhalt:**
```markdown
# Snail — Echtzeit-Konversationsübersetzer

## Architektur
- Flutter-App (Android) → WebSocket → Cloudflare Worker → Durable Object
- Audio-Pipeline: Mikrofon → AEC → VAD → STT → MT → TTS → Playback
- STT: Groq Whisper (primär) → Deepgram Nova-2 → OpenAI Whisper (Fallback)
- MT: Groq gpt-oss-20b
- TTS: fish.audio (primär) → edge-tts (Fallback)

## Setup (Entwicklung)
1. Flutter SDK 3.29+ installieren
2. Android SDK 34 + NDK 26.3
3. `cd flutter_app && flutter pub get`
4. `flutter run --release`

## API-Referenz
| Endpoint | Methode | Beschreibung |
|----------|---------|-------------|
| `/api/health` | GET | Health-Check |
| `/api/rooms` | POST | Raum erstellen (Host) |
| `/api/rooms/:id/join` | POST | Raum beitreten (Guest) |
| `/ws?room=<id>` | WS | WebSocket-Relay |

## Provider-Stack
| Schritt | Primär | Fallback 1 | Fallback 2 |
|---------|--------|-----------|-----------|
| STT | Groq Whisper (531ms P50) | Deepgram Nova-2 | OpenAI Whisper (1250ms P50) |
| MT | Groq gpt-oss-20b (430ms P50) | — | — |
| TTS | fish.audio (450ms TTFA) | edge-tts | — |

## Deployment
```bash
wrangler deploy  # Worker + DO auf Cloudflare
```
```

---

## Schritt 13: Finale Prüfung

1. `flutter build apk --release` → muss ohne Fehler durchlaufen
2. APK auf beiden Test-Geräten installieren
3. First-Run: Sprache wird automatisch erkannt
4. Session-Flow: Host erstellt Raum → Guest joined → beide verbunden
5. Settings: API-Keys maskiert, Eye-Toggle funktioniert
6. Error-Log: Fehler werden protokolliert und sind einsehbar
7. History: Transkripte werden gespeichert und angezeigt
8. Reconnect: WebSocket-Verbindung wird bei Abbruch automatisch wiederhergestellt

---

## Abhängigkeiten zwischen Schritten

```
Schritt 1 (api_keys.dart)
  ├── Schritt 2 (error_logger.dart)
  ├── Schritt 3 (audio_processor.dart)
  ├── Schritt 4 (session_service.dart)
  ├── Schritt 5 (audio_service.dart) ← braucht Schritt 2
  ├── Schritt 6 (transcript_history.dart)
  ├── Schritt 7 (history_screen.dart) ← braucht Schritt 6
  ├── Schritt 8 (settings_screen.dart) ← braucht Schritt 1, 2
  ├── Schritt 9 (error_log_screen.dart) ← braucht Schritt 2
  ├── Schritt 10 (main.dart) ← braucht Schritt 7, 9
  ├── Schritt 11 (home_screen.dart) ← braucht Schritt 7
  └── Schritt 12 (README.md)
```

**Empfohlene Reihenfolge:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13

---

## Wichtige Hinweise

- **Keine externen Abhängigkeiten hinzufügen**, die nicht in `pubspec.yaml` stehen (außer `shared_preferences` ist bereits drin)
- **Bestehende Dateien nicht überschreiben**, sondern mit `patch`-Tool gezielt erweitern
- **Nach jedem Schritt:** `flutter build apk --release` zum Verifizieren
- **Provider-Keys nie im Quelltext** — Entwicklung per Build-Time-Variable, BYOK per Secure Storage
- **Alle neuen Services als ChangeNotifier**, damit die UI automatisch updated
