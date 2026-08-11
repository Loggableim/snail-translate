# Snail — Echtzeit-Konversationsübersetzer („Babelfisch fürs Reisen")

> Zwei Personen mit je einem Headset. Die App erkennt, wer spricht,
> übersetzt das Gespräch live und gibt es dem jeweils anderen in seiner
> Sprache aus. Ideal für Reisen.

---

## Zielbild der App: BYOK-Messenger mit Live-Übersetzung

Snail ist eine BYOK-App (Bring Your Own Key) auf Session-Ebene. Der Nutzer,
der eine Session eröffnet, ist Provider-Owner und wählt Ollama, OpenAI oder
später Gemini Live.
Er übernimmt die Providerkosten für Live-Audio und Messenger-Nachrichten in
dieser Session. Der eingeladene Nutzer benötigt keinen eigenen Key.

### Verbindliche Produktentscheidung

Die alte Python-Kette STT → MT → TTS bleibt ausschließlich als historische
lokale Benchmark- und Entwicklungsreferenz erhalten.

### Sicherheitsmodell für die APK

Der Provider-Key wird verschlüsselt lokal gespeichert und nicht an den Peer
weitergegeben. Mit eigenem Live-Key übersetzt jede Seite ihre Richtung lokal
parallel. Fehlt einer Seite ein Live-Key, sendet sie Roh-Audio an die Seite mit
Providerzugang; nur das fertige Übersetzungs-Audio wird zurückgesendet. Bei
OpenAI Realtime kann der Worker optional ein kurzlebiges Secret für die
APK-Session ausstellen. Ollama wird über eine vom Nutzer konfigurierte
lokale oder private Netzwerk-URL angesprochen.

```text
Session-Owner (A) → Provider-Auswahl → Ollama, OpenAI oder Gemini Live
       │             Übersetzungsanfrage + Kosten
       ├── Messenger-Text → Übersetzung → Ergebnis an B
       └── Live-Audio → Realtime-Provider → Audio an B
                                      ▲
Gast (B) ───── eigener Key optional; sonst Provider-Fallback der Gegenseite ─┘
```

### Verantwortlichkeiten

| Komponente | Verantwortung im Zielbild |
|---|---|
| Flutter-App | Mikrofonaufnahme, AEC, Audio-Playback, Messenger-UI und lokale BYOK-Konfiguration |
| Snail Worker | Authentifizierung, Room, Quota, Conversation-State und optionale Client-Secrets |
| Ollama | Lokale/private Übersetzung für Chat und, sofern unterstützt, Audio-Pipeline |
| OpenAI | Chat-Modelle für Messenger; `gpt-realtime-translate` als primärer Live-Audio-Pfad |
| Gemini Live | Optionaler Live-Audio-Provider mit `gemini-3.5-live-translate-preview`; Chat-Text bleibt separat |
| Durable Object | Optionaler Room-/Peer-State und Signalling; kein serieller STT→MT→TTS-Proxy |
| Python-Prototyp | Benchmark, Regressionstests und Provider-Vergleich |

Der Flutter-Service `gemini_live_service.dart` bildet den aktuellen Gemini-
WebSocket-Vertrag ab: native Aufnahme mit 16-kHz-PCM16; der OpenAI-Client
resampelt für dessen Übersetzungs-WebSocket auf 24 kHz. Zurück kommen 24-kHz-
Audio-Chunks sowie Input-
und Output-Transkripte heraus. Die Anbindung an die konkrete Mikrofon- und
Playback-Schicht sowie kurzlebige Google-Ephemeral-Tokens folgt noch.

### Messenger-Modus über getrennte Räume und Netzwerke

Snail kann neben dem Live-Übersetzungsraum auch als Messenger verwendet
werden. User A und User B müssen sich weder im selben Raum noch im selben
WLAN befinden. Beide Geräte verbinden sich über das öffentliche Snail-Gateway
und werden über eine User-ID bzw. einen Conversation- bzw. Room-Identifier
einander zugeordnet.

Der Messenger-Modus unterscheidet sich vom Live-Modus:

```text
User A ── Internet ──► Snail Worker / Message Store ◄── Internet ── User B
                              │
                         Conversation
                         + Zustellung
```

Zielverhalten:

- Online-Nachrichten werden per WebSocket sofort zugestellt.
- Offline-Nachrichten werden serverseitig gespeichert und beim nächsten
  Verbinden nachgeliefert.
- Eine Nachricht kann Text, übersetzter Text, Audio oder eine Referenz auf
  eine Audio-/Sprachmemo enthalten.
- Für eine Live-Konversation wird zusätzlich ein temporärer Realtime-Room
  geöffnet; die Messenger-Konversation bleibt davon unabhängig bestehen.
- Die Spracheinstellung gilt pro Teilnehmer und Richtung. A kann Deutsch
  schreiben oder sprechen, B erhält Englisch und umgekehrt.
- Reconnect, Mehrfachgeräte und Zustellstatus gehören zum Messenger-Protokoll;
  ein flüchtiger Durable-Object-WebSocket allein reicht dafür nicht aus.

Für die Zielarchitektur übernimmt der Worker Authentifizierung, Conversation-
und Berechtigungsprüfung sowie kurzlebige Realtime-Client-Secrets. Ein
Durable Object übernimmt die Live-Verbindung und Online-Zustellung. Ein
persistent ausgelegter Message Store, bevorzugt D1 für Nachrichten und
Zustellstatus, hält den Verlauf unabhängig davon, ob ein Gerät gerade online
ist. Push-Benachrichtigungen werden als nachgelagerte Messenger-Funktion
vorgesehen.

### Dezentrale User-Identität und QR-Onboarding

Jeder Nutzer erhält bei der ersten Einrichtung automatisch eine individuelle
öffentliche User-ID als QR-Code. User A scannt den QR-Code von User B und kann
danach eine Conversation oder einen Live-Room anfragen.

Der sichtbare Username ist unabhängig von der technischen Identität und kann
jederzeit geändert werden. Die QR-Darstellung bzw. der öffentliche QR-Link
ändert sich dabei; die lokale Geräteidentität und bestehende Conversations
bleiben erhalten. Die Geräteidentität wird sicher lokal erzeugt und signiert
Anfragen, Conversations und Nachrichten. Der Username ist nur Darstellung
und Discovery-Metadatum, kein Authentifizierungsgeheimnis.

#### Gerätegebundene User-ID und eigener Kontakt-QR

Jede Installation erhält beim ersten Start automatisch eine eigene,
gerätegebundene Snail User-ID. Die Kontakte-Seite zeigt immer den **eigenen
QR-Code** mit dieser öffentlichen ID sowie eine Scan-Funktion für andere
Personen; dadurch ist die eigene Identität nicht nur implizit im Hintergrund
vorhanden, sondern direkt teilbar und überprüfbar.

Die ID wird aus einem zufälligen Schlüsselmaterial erzeugt und mit einem
Android-Keystore-Schlüssel an die Installation gebunden. Der öffentliche
Identifier wird daraus abgeleitet; Signaturen beweisen bei Room-, Kontakt- und
Nachrichtenanfragen den Besitz des lokalen Schlüssels. Bei Neuinstallation
entsteht eine neue Identität, außer der Nutzer hat eine explizite,
verschlüsselte Wiederherstellung gewählt.

**Keine IMEI als User-ID:** Normale Android-Apps können IMEIs auf aktuellen
Android-Versionen nicht zuverlässig lesen; außerdem wäre die IMEI eine
geräteübergreifend verfolgbare personenbezogene Hardwarekennung. Snail nutzt
sie daher weder als Identifier noch als Authentifizierungsmerkmal. Der
Keystore-gebundene Schlüssel erreicht die benötigte Eindeutigkeit ohne diese
Datenschutz- und Plattformprobleme.

#### Übersetzungsverlauf als Produktfunktion

Der Übersetzungsverlauf ist ein fester Bestandteil von Live-Session und
Messenger, nicht nur ein Debug-Log. Jede bestätigte Richtung speichert
Original, Übersetzung, Sprachen, Zeit, Providerstatus und eine lokale
Session-Referenz erst nach abgeschlossenem Turn. Vorläufige Deltas,
abgebrochene Turns und Reconnect-Reste werden nicht als Gesprächseintrag
ausgegeben.

- Während einer Live-Session erscheinen Quell- und Zieltext unmittelbar und
  werden nach Turn-Abschluss in den Verlauf übernommen.
- Der Verlauf ist über Home, Session und Messenger erreichbar, such- und
  löschbar; Löschen entfernt die lokalen Inhalte nachvollziehbar.
- Für private Gespräche bleibt der Volltext lokal verschlüsselt. Der Worker
  erhält nur die für das Messenger-Protokoll notwendigen, Ende-zu-Ende-
  geschützten Daten.
- Smoke-Tests müssen mindestens speichern, App-Neustart, Anzeige beider
  Richtungen, Duplikatvermeidung, Löschen und das Auslassen abgebrochener
  Realtime-Turns auf echten Geräten nachweisen.

### App teilen und Peer-Onboarding

Snail hat einen eigenen **App teilen**-Bereich, damit ein Gesprächspartner
ohne installierte App schnell eingeladen werden kann. Die Funktion ist vom
Kontakt- und Session-QR getrennt: Sie teilt keinen Provider-Key und keine
dauerhafte Geräteidentität.

```text
Snail-App (A) → „App direkt teilen"
  ├─ eröffnet einen kurzlebigen, binären Cloudflare-WebSocket-Tunnel
  ├─ QR-Code: https://snail-worker.pixstash.workers.dev/download/<token>
  └─ System-Share-Sheet: derselbe einmalige Link

Browser (B) ── Cloudflare-HTTPS-Seite + WebSocket-Tunnel ──► Snail-Gerät (A)
  └─ Host streamt seine signierte APK in kleinen Binärpaketen aus dem App-Speicher
       → Android-Installation → Snail öffnen → Kontakt-/Session-QR
       → verschlüsselte P2P-Verbindung
```

Regeln für den direkten Geräte-Share:

- **Das Host-Gerät ist der Download-Anbieter.** Die APK liegt nicht auf einem
  zentralen Snail-Server. Im gleichen WLAN bzw. über einen Hotspot geht der
  Download direkt von Gerät A zum Browser von B.
- Außerhalb desselben Netzes leitet ein kurzlebiger Cloudflare-Tunnel nur die
  verschlüsselte Verbindung zu Gerät A weiter. Der Worker speichert und
  verarbeitet die APK nicht; er erzeugt und beendet ausschließlich den
  temporären Rendezvous-Link.
- Der QR-Code und das System-Share-Sheet tragen einen zufälligen,
  einmal verwendbaren Download-Token. Dieser ist nicht die Geräte-ID,
  autorisiert weder Sessions noch Nachrichten und verfällt nach Download,
  manueller Beendigung oder spätestens 15 Minuten.
- Vor dem Download zeigt der Host Größe, Versionsnummer, Signatur-Fingerprint
  und Ablaufzeit. Der Browser zeigt denselben Fingerprint; nach dem Download
  validiert Android die normale APK-Signatur vor der Installation.
- Der Host darf den Share jederzeit abbrechen. Der Tunnel wird bei
  Sperrbildschirm-/App-Ende, Ablauf oder Abbruch geschlossen und gibt keine
  Provider-Keys, Konversationen oder Logs frei.
- P2P für Chat und Audio beginnt erst nach Installation und Einwilligung
  beider Personen. Der App-Download selbst ist ein direkter HTTPS-Dateitransfer
  vom Host-Gerät und benötigt keine Snail-App auf dem Empfänger.
- Android erlaubt diesen unabhängigen Installationsweg nach expliziter
  Nutzerfreigabe für unbekannte Quellen. iOS lässt eine frei verteilbare APK-
  Entsprechung nicht zu; dort ist ein gleichwertiger Standalone-Download ohne
  Apple-vertrauenswürdigen Distributionskanal technisch nicht möglich.

### P2P als bevorzugter Transport

Nach dem QR-Onboarding versucht Snail eine direkte, verschlüsselte WebRTC-
Verbindung zwischen den Geräten aufzubauen. Das gilt für Messenger-
Nachrichten, Sprachnachrichten und Live-Audio. Der Worker dient nur als
Rendezvous-/Signalling-Dienst und vermittelt Offers, ICE-Kandidaten und
Berechtigungen; Inhalte werden möglichst nicht über ihn geroutet.

```text
User A ── QR/Signalling ──► Rendezvous-Dienst ◄── QR/Signalling ── User B
   └────────────── direkte verschlüsselte P2P-Verbindung ──────────────┘
                 Chat, Audio, Realtime-Übersetzung
```

Bei NAT-, Firewall- oder Mobilfunkproblemen ist ein verschlüsselter TURN-
Relay der Fallback. Vollständig dezentrales Store-and-Forward ist nur
möglich, wenn mindestens ein Gerät später wieder online ist. Optional kann
ein Ende-zu-Ende-verschlüsselter Relay-Store als Backup dienen, ohne dass der
Relay die Inhalte lesen kann.

### Primärer Audiofluss

```text
Mikrofon A → AEC / Noise Suppression → gewählter Audio-Provider (DE → EN)
           → übersetzte Audio-Chunks → Playback auf Gerät B
```

Die Gegenrichtung läuft unabhängig parallel. Gemessen wird primär
Time-to-first-audio statt der Zeit bis zum Ende einer kompletten TTS-Datei.
Für Web- oder browserähnliche Clients ist WebRTC bevorzugt; für den
bestehenden Audio-Relay-Prototyp kann WebSocket mit 24-kHz-PCM16 verwendet
werden.

### Schnellübersetzer / Standalone-Modus

Der Schnellübersetzer ist ein eigenständiger Ein-Gerät-Modus für kurze
Touristen- und Alltagssituationen. Das Handy-Mikrofon nimmt bevorzugt die
Gesprächsperson auf; ein angeschlossenes Headset-Mikrofon nimmt den eigenen
Nutzer auf. Beide Quellen werden als getrennte Richtungen parallel verarbeitet.
Der Modus muss auch ohne Headset funktionieren und dann sichtbar in einen
Ein-Mikrofon-Modus mit klarer Einschränkung wechseln.

Verbindliche Audioanforderungen:

- Jede native Aufnahme liefert einen unveränderlichen Frame-Snapshot. Ein
  Aufnahmebuffer darf nicht erneut beschrieben werden, solange ein Frame noch
  über den Platform-/EventChannel zugestellt wird.
- Handy- und Headset-Recorder laufen unabhängig voneinander. Ein blockierter
  oder verspäteter Eingang darf den anderen Eingang nicht aufhalten.
- Android-Audioquelle und tatsächlich gewähltes Ausgabegerät werden ermittelt
  und im UI angezeigt: Handy-Mikrofon, Headset-Mikrofon, Lautsprecher,
  Bluetooth oder kabelgebundenes Headset.
- AEC, Noise Suppression und lokales VAD sind Fähigkeiten mit Laufzeitstatus,
  keine stillen Annahmen. Nicht verfügbare Funktionen werden sichtbar als
  Fallback angezeigt.
- Die AEC darf nicht durch eine pauschale harte 500-ms-Sperre ersetzt werden.
  Echo- und Barge-in-Entscheidungen berücksichtigen Wiedergabereferenz,
  Sprachaktivität, Pegel, Richtung und Zeitversatz. Headset-Betrieb darf
  schneller unterbrechen; Lautsprecherbetrieb benötigt eine konservativere
  Sprecher-/Echoentscheidung.
- Ein Sprach-/Sprecherfilter darf erkannte Sprache, Mikrofonrichtung und eine
  konfigurierbare Muttersprache berücksichtigen. Fremde Sprache wird nur dann
  ignoriert, wenn der Nutzer diesen Filter ausdrücklich aktiviert.

Die Provideranbindung verwendet denselben primären OpenAI-Realtime-
Übersetzungspfad wie der Zwei-Geräte-Modus. Ein lokal gespeicherter BYOK-Key
ist optional; fehlt er, wird ein kurzlebiges Worker-Client-Secret angefordert,
erneuert und niemals dauerhaft in der APK gespeichert. Reconnects verwenden
begrenztes Exponential-Backoff, erneuern abgelaufene Secrets und zeigen den
Zustand `verbunden`, `wiederverbinden`, `degradiert` oder `Fehler` dauerhaft an.
Die gleiche Abstraktion gilt für Gemini Live, sofern der Nutzer diesen
Provider auswählt.

Die Ausgabe verwendet pro Richtung eine begrenzte, sequenzielle
FIFO-/Jitter-Queue. Es gibt keine parallelen `playPcm16`-Aufrufe; bei
Überlauf werden definierte alte Chunks verworfen und bei Sessionende,
Reconnect oder Richtungswechsel wird die Queue geleert. Für jede Quelle und
Richtung werden mindestens folgende Metriken erfasst: Zeit bis zum ersten
Input, ersten Transkript und ersten Audio, aktuelle Turn-Latenz, Queue-Tiefe,
Underruns, Overruns, verworfene Frames, Audioquelle, Ausgaberoute,
AEC-/NS-/VAD-Status, Reconnect-Anzahl und Providerfehler.

Die UI aktualisiert keine komplette Seite für jedes Audioframe. Audioframes
werden gepuffert und die sichtbare Quellen-/Statusanzeige gedrosselt oder über
einen separaten Modellzustand aktualisiert. Während des Starts zeigt der
Schnellübersetzer jeden Schritt an: Berechtigung, Mikrofonroute,
Providerverbindung, Audioaufnahme, erste Sprache und Audioausgabe. Bei fehlendem
Headset wird erklärt, welche Richtung nicht getrennt aufgenommen werden kann.

Vor jeder APK-Freigabe sind Smoke-Tests auf echten Android-Geräten mit und
ohne Headset verpflichtend: Start/Stop, Berechtigungsablehnung,
Headset-An-/Abstecken, nur Handy-Mikrofon, Sprachwechsel, Stille, Echo bei
Lautsprechern, Barge-in, Providerfehler, WLAN-Unterbrechung,
Secret-Erneuerung, App-Hintergrund/Screen-off und Freigabe aller
Audioressourcen. Alle sichtbaren Texte müssen UTF-8-kodiert und in Tag- und
Nachtmodus lesbar sein.

### OpenAI-Realtime-Translation als Referenzpfad

OpenAI Realtime Translation ist für Snail der primäre Live-Übersetzungspfad.
Die Translation-Session ist keine normale Voice-Agent-Conversation: Sie läuft
kontinuierlich aus dem Audio-Stream, verwendet kein `response.create` und
liefert parallel übersetztes Audio sowie Quell- und Zielsprach-Transkript-Deltas.
Protokollreferenzen: [Realtime translation](https://developers.openai.com/api/docs/guides/realtime-translation)
und [Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad).

```text
Flutter-Mikrofon
  → lokale AEC / Noise Suppression / Audio-Routing
  → 16-kHz-PCM16 intern
  → Resampling auf 24-kHz-PCM16
  → session.input_audio_buffer.append
  → OpenAI /v1/realtime/translations
       ├─ session.output_audio.delta       → Audio-Jitter-Queue → Playback
       ├─ session.input_transcript.delta   → Quelltext im Live-UI
       └─ session.output_transcript.delta  → Übersetzung im Live-UI/Chat
```

#### Session- und Transportregeln

- WebSocket: `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`.
- WebSocket-Audio wird als Base64-PCM16 mit 24 kHz übertragen; die native
  Android-Aufnahme darf intern mit 16 kHz laufen und wird im Client resampelt.
- Audio wird kontinuierlich gesendet, auch bei kurzen Pausen. Lokales VAD darf
  UI, Metriken und Echo-Steuerung unterstützen, aber nicht unkontrolliert den
  Providerstream in harte 500-ms-Blöcke zerschneiden.
- `session.update` setzt mindestens die Zielsprache. Quell- und Zielsprache
  werden zusätzlich im Snail-Session-State geführt, damit beide Richtungen
  und die Transkriptanzeige eindeutig bleiben.
- Beim Beenden wird `session.close` gesendet; der Client liest weiter, bis
  `session.closed` eingetroffen ist, damit letzte Audio- und Text-Deltas nicht
  verloren gehen.
- Jede Richtung besitzt eine eigene Translation-Session. Audio beider
  Sprecher wird nicht zu einem gemeinsamen Stream vermischt.

#### Transcript- und Turn-Modell

Jede Audio-Richtung führt einen laufenden Turn mit `sourceText`, `targetText`,
Zeitstempeln und Provider-Status. Delta-Events werden sofort angezeigt und
am Turn-Ende als unveränderlicher Verlaufseintrag gespeichert. Unvollständige
Deltas bleiben vorläufig und werden bei Abbruch oder Reconnect nicht als
vollständige Nachricht gespeichert.

VAD wird als lokale, konfigurierbare Strategie für AEC, UI und Turn-Metriken
modelliert. Der dedizierte Translation-Endpoint erhält dabei keine blind
übertragenen Conversation-/VAD-Felder: Die aktuelle OpenAI-Translation-
Dokumentation beschreibt `turn_detection` für Realtime-/Transcription-
Sessions, nicht für `/v1/realtime/translations`. Sobald der Translation-
Endpoint diese Felder offiziell unterstützt, können sie als neue
Session-Optionen ergänzt werden; bis dahin bleibt der Providerstream
kontinuierlich und die lokale Logik darf keinen harten Audioverlust erzeugen.

Lokale VAD-Profile:

Im Flutter-Client werden diese Profile als `AudioPolicy` persistent angeboten
und sowohl vom Zwei-Geräte-Session-Screen als auch vom Schnellübersetzer
verwendet: `auto` folgt der erkannten Route, `headset` vermeidet unnötige
Lautsprecher-Echounterdrückung, `speakerEcho` erzwingt den Echofilter und
`longerSpeech` verwirft laufende Ausgabe weniger aggressiv.

| Modus | Einsatz | Zielkonfiguration |
|---|---|---|
| `lokal-schnell` | Headset, kurze Antworten, niedrige Latenz | mittlerer Threshold, kurze/mittlere Stille |
| `lokal-echo` | Lautsprecher, Echo/Umgebungsgeräusch | höherer Threshold, längere Stille |
| `lokal-satz` | längere Sätze und natürliche Gesprächsführung | längere lokale Stille, keine Provider-Unterbrechung |
| lokales VAD | AEC-/UI-Steuerung und Diagnose | kein harter Audioverlust durch aggressive Sperren |

Die lokalen Parameter `threshold`, `prefix_padding_ms` und
`silence_duration_ms` werden zunächst über die vier verständlichen
Audio-Profile gekapselt; freie numerische Slider können später ergänzt werden.
Änderungen gelten erst für neue Sessions. Conversation-only-Optionen wie
`create_response` oder `interrupt_response` werden nicht auf den
Translation-Endpoint übertragen.

#### Barge-in und Audioausgabe

Die App unterscheidet zwischen aktivem Sprechen, ausstehender Audioausgabe und
bereits abgespieltem Audio. Beginnt der Nutzer zu sprechen, wird die lokale
Ausgabe abhängig vom Modus weich gedimmt bzw. die noch nicht abgespielten
Chunks werden verworfen. Headset-Betrieb darf unterbrechen; im
Lautsprechermodus entscheidet eine Echo-/Sprecherlogik, ob es echte Sprache
oder nur Rückkopplung ist. Ein globaler starrer Sperr-Timer ist nicht zulässig.

Die Audioausgabe läuft über eine begrenzte FIFO-/Jitter-Queue mit:

- sequenzieller Wiedergabe ohne parallele `AudioTrack`-Starts,
- Low-Watermark für kurze Netzwerklücken,
- High-Watermark als Schutz gegen Speicher- und Latenzaufbau,
- Underrun-, Overrun-, Drop- und Playback-Latenzmetriken,
- Flush bei Sessionwechsel, Abbruch und Reconnect.

#### Resilienz und Beobachtbarkeit

Eine Translation-Session hat einen expliziten Zustandsautomaten:
`connecting → ready → streaming → draining → closed` sowie `degraded` und
`reconnecting`. WebSocket-Abbrüche führen zu begrenztem Exponential-Backoff,
neuem kurzlebigem Secret und einer neuen Session; Audio- und Transcript-Turns
werden mit einer lokalen ID dedupliziert. Die UI zeigt Provider-, Netzwerk-,
Mikrofon- und Wiedergabestatus getrennt.

Pro Turn werden mindestens erfasst:

- capture timestamp,
- first input sent,
- first output audio,
- first source/target transcript delta,
- speech start/stop,
- playback start/end,
- reconnects, dropped chunks und Fehlercode.

Damit werden TTFA, Input-to-First-Transcript, Input-to-First-Audio, Turn-Latenz
und P50/P95 getrennt pro Richtung messbar.

### Sicherheits- und Betriebsregeln

- Kein permanenter OpenAI-Key in APK, Flutter-Code, Git oder Logs.
- Development und Production verwenden getrennte OpenAI-Projekte bzw. Keys.
- Das Development-Projekt erhält ein hartes Ausgabenlimit.
- Client-Secrets sind kurzlebig und an Nutzer, Room und Session gebunden.
- Bei Ablauf, Reconnect oder Room-Wechsel wird ein neues Client-Secret
  ausgestellt.
- AEC wird auf echten Android-Geräten mit Bluetooth-Headsets validiert.

---

## 1. Zielbild & Nutzungsszenario

- **Zwei Nutzer** (A und B), jeder mit eigenem Handy + Headset (Mikro + Kopfhörer).
- A spricht Deutsch, B spricht Englisch (beliebige Sprachpaare).
- A spricht → B hört die Übersetzung auf Englisch (und umgekehrt).
- Da jedes Gerät sein eigenes Mikro hat, ist **immer klar, wer spricht**
  (keine Diarization nötig).
- **Latenz-Ziel:** P50 < 2s, P95 < 4s pro Richtung (komfortabel für Reisegespräche).
  Ein harter Grenzwert ist bei mobilem Netz unrealistisch; P50/P95 spiegelt die
  echte Nutzererfahrung besser wider.

### Randbedingungen

- **Netzwerk:** Reisende haben oft schlechtes Netz (Flughafen-WLAN, Roaming,
  3G/4G). Die Architektur muss mit 200–400 ms RTT umgehen können.
- **Echo / Feedback-Loop:** Wenn B die Übersetzung von A hört und gleichzeitig
  spricht, fängt B's Mikro die Übersetzung auf. **AEC (Acoustic Echo
  Cancellation)** ist eine Pipeline-Voraussetzung, kein Nice-to-have.
- **Spracherkennung:** Die Pipeline nimmt feste Sprachpaare an (z.B. DE→EN,
  DE→UK oder UK→DE); Ukrainisch ist als Quell- und Zielsprache vorgesehen.
  Eine automatische Spracherkennung (Language ID) ist für MVP nicht nötig,
  aber als Fallback eingeplant, falls Nutzer falsche Sprachen wählen.
- **Offline-Modus:** Nicht Teil des MVP, aber die Pipeline-Architektur lässt
  on-device STT (Whisper small/tiny) als Fallback zu. Geplant für v2.
- **Mehr als zwei Personen:** MVP ist 1:1. Die Architektur schließt Multi-Party
  nicht strukturell aus, aber das implizite Diarization-Modell (2 Geräte)
  skaliert nicht auf N Personen. Multi-Party würde Diarization oder N Geräte
  erfordern — out of scope für v1.

---

## 2. Kern-Pipeline (eine Richtung)

Jede Sprechrichtung durchläuft dieselbe Kette. Da jedes Gerät sein eigenes
Mikro hat, ist die Sprecher-Zuordnung implizit gegeben — **keine
Diarization nötig.**

```
Mikrofon (A)
   │  Audio-Stream (16 kHz, mono)
   ▼
[0] AEC — Acoustic Echo Cancellation
   │  entfernt Echo des Gegenübers aus dem Mikrosignal
   │  (verhindert Feedback-Loop: B's Übersetzung → B's Mikro)
   ▼
[0b] Noise Suppression — Rauschunterdrückung
   │  entfernt Umgebungsgeräusche (Straße, Restaurant)
   │  verbessert STT-Qualität massiv
   ▼
[1] VAD — Voice Activity Detection
   │  erkennt Sprachsegmente, schneidet Stille weg (Silero, lokal, ~50ms)
   ▼
[1b] Audio-Encoding
   │  PCM → Opus/FLAC/μ-law (je nach API-Anforderung)
   ▼
[2] STT — Speech-to-Text (Streaming)
   │  liefert laufende Teiltranskripte
   ▼
[2b] Sentence Boundary Detection
   │  entscheidet: "übersetze jetzt" vs. "warte auf mehr Text"
   │  (Streaming-STT liefert oft unvollständige Sätze)
   ▼
[3] Übersetzung (LLM / MT-Engine, Streaming)
   │  übersetzt ins Zielsprachen-Paar
   │  ideal: inkrementelle Übersetzung von Teiltranskripten
   ▼
[4] TTS — Text-to-Speech (Chunked)
   │  erzeugt Sprachausgabe in Zielsprache
   │  ideal: synthetisiert Satzfragmente, nicht ganze Sätze
   ▼
[4b] Audio-Decoding + Jitter-Buffer
   │  dekodiert TTS-Output (MP3/PCM) → Playback-Buffer
   │  gleicht Netzwerkschwankungen aus
   ▼
[5] Playback
   │  Ausgabe auf dem Headset des Gegenübers
   ▼
Kopfhörer (B)
```

**Gegenrichtung** läuft parallel und unabhängig (A↔B gleichzeitig möglich).

### Pipeline-Optimierungen (gegenüber v1)

- **AEC + Noise Suppression** als Pipeline-Schritt [0]: On-device (OS-native
  oder RNNoise), vor VAD. Verhindert Feedback-Loop und verbessert STT-Qualität.
- **Streaming-Translation:** Statt STT abzuwarten und dann zu übersetzen,
  inkrementelle Übersetzung von Teiltranskripten (DeepL Streaming API oder
  LLM mit inkrementellem Prompting). Reduziert Latenz um 200–500 ms.
- **Chunked TTS:** TTS synthetisiert Satzfragmente, nicht ganze Sätze. Deepgram
  Aura und fish.audio unterstützen teilweise Chunked-Output.
- **Parallele Pipeline:** STT → Übersetzung → TTS nicht strikt seriell, sondern
  überlappend (Sobald STT ein Fragment liefert, startet Übersetzung; sobald
  Übersetzung ein Fragment liefert, startet TTS).

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
| 1 Handy + 2 Headsets (nur Audio-Ausgabe) | ⚠️ | Kein Mikro für den zweiten Sprecher |
| **2 Handys, je 1 Headset** | ✅ | Jedes Handy hat sein eigenes HFP |

> **LE Audio / Auracast (Stand 2026):** LE Audio unterstützt Broadcast
> (Auracast) für Audio-Ausgabe an mehrere Empfänger. Für **2× HFP** (zwei
> Headsets mit aktivem Mikrofon gleichzeitig) ist LE Audio **aktuell nicht
> zuverlässig** in der Praxis — die Multi-Stream-Profile sind noch nicht
> flächendeckend in Headsets implementiert. Die Entscheidung für 2 Geräte
> bleibt korrekt. LE Audio ist für eine spätere „Ein-Gerät"-Roadmap
> (v2+) zu reevaluieren, sobald die Hardware-Unterstützung ausgereift ist.

### 3b. Cloudflare Worker + Durable Objects + Geräteidentität

> **Aktueller Vorrang:** Die nachfolgende ältere Worker-Skizze enthält noch
> Clerk-Bezeichnungen aus einer früheren kommerziellen Variante. Für das
> aktuelle Zielbild gilt: signierte Geräte-ID und QR-Onboarding sind der
> Pflichtpfad; Clerk oder ein anderer Account-/Billing-Dienst ist optional.

Der Worker unterstützt dafür zwei explizite Authentifizierungsprofile: Clerk
für kontobasierte Deployments oder `DEVICE_ID_AUTH=true` für eine
geräteidentitätsbasierte Bereitstellung ohne Clerk. Die Geräte-ID-Variante
wird niemals implizit aktiviert; die finale Version muss zusätzlich den im
Zielbild vorgesehenen kryptografischen Identitätsnachweis statt eines bloßen
UUID-Headers verwenden. Im lokalen Development bleibt
`DEV_ALLOW_IDENTITY_AUTH=true` der bewusst vereinfachte Testpfad.
Im aktivierten Produktionspfad bindet der Worker den ersten erfolgreich
verifizierten P-256-Public-Key in KV an die Geräte-ID (`device-key:<id>`);
spätere Requests mit einem anderen Schlüssel werden abgelehnt. Ein
Gerätewechsel benötigt deshalb einen ausdrücklich vorgesehenen Recovery- oder
Neu-Onboarding-Prozess und darf nicht stillschweigend die Identität ersetzen.
> Serverseitige OpenAI-Keys bleiben Worker-Secrets, lokale BYOK-Keys bleiben
> verschlüsselt auf dem Gerät.

**Entscheidung (2026-08, überarbeitet):** Snail nutzt ein **serverless Backend
auf Cloudflare Workers + Durable Objects** als Rendezvous-, Quota-,
Client-Secret- und Audio-Relay-Schicht. Für den Basisbetrieb ist kein Clerk-
Login erforderlich: Jedes Gerät besitzt eine lokal erzeugte, signierte
Geräteidentität. Ein optionales Konto kann später für Cloud-Sync, Abos und
Recovery ergänzt werden.

#### Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Cloudflare Worker (Edge)                         │
│  • Geräteidentität / optionales Konto verifizieren                    │
│  • Tier-Quota prüfen (KV / D1)                                       │
│  • API-Keys als Worker-Secrets (Deepgram, DeepL, fish.audio, Google)│
│  • Gibt kurzlebige Session-Tokens aus                                 │
│  • Erstellt / verifiziert Room-IDs                                    │
└──────┬──────────────────────────────────────────────────────┬───────┘
       │                                                      │
       │  Session-Token + API-Endpoint-URL                    │  Session-Token + API-Endpoint-URL
       │  (API-Keys bleiben im Durable Object)                 │  (API-Keys bleiben im Durable Object)
       ▼                                                      ▼
┌─────────────┐                                          ┌─────────────┐
│  App (A)    │ ◀──── WebSocket (Audio + Steuerung) ────▶ │  App (B)    │
│  Flutter    │            │                              │  Flutter    │
│             │            │                              │             │
│  Mikro+Head │            ▼                              │  Mikro+Head │
└─────────────┘  ┌──────────────────────────┐             └─────────────┘
                 │  Durable Object (Relay)   │
                 │  • Hält WebSocket-Verbin-  │
                 │    dungen (beide Geräte)  │
                 │  • Session-State, Room-ID │
                 │  • API-Key-Injection:     │
                 │    injiziert Worker-       │
                 │    Secrets in API-Calls    │
                 │  • Streaming-Proxy:       │
                 │    Audio → Deepgram/      │
                 │    DeepL/fish.audio       │
                 │  • Quota-Tracking         │
                 └──────────────────────────┘
```

#### Warum Worker + Durable Objects (nicht nur Worker)

| Anforderung | Lösung | Warum |
|-------------|--------|-------|
| Keys sicher | Worker-Secrets | Nie in der App, nie im Client |
| Kein Server-Betrieb | Cloudflare serverless | Pay-per-Use, keine Wartung |
| Auth + Subscriptions | Geräte-ID; optionales Konto | Kein Login für Basisbetrieb; Konto nur für Sync/Abos |
| **Persistent WebSocket** | **Durable Object** | Workers können keine WS halten; DOs können |
| **Audio-Streaming-Proxy** | **Durable Object** | DOs haben keine CPU-Zeit-Limits wie Workers |
| **API-Key-Injection** | **Durable Object** | App sendet Audio + Session-Token; DO fügt API-Key hinzu und leitet an STT/MT/TTS weiter |
| Skalierung | Cloudflare automatisch | DOs skalieren per Session |

#### Das Session-Token-Modell (aufgelöst)

**Problem in v1:** Das Dokument sagte „App ruft APIs direkt" und „kein
Worker-Hop für Audio", aber die APIs (Deepgram, DeepL, fish.audio) kennen
keine Snail-Session-Tokens. Ein Snail-Token kann nicht als API-Key bei
diesen Anbietern verwendet werden. Das war ein Widerspruch.

**Lösung: Durable Object als Streaming-Proxy mit API-Key-Injection.**

1. **App authentifiziert beim Worker** mit Geräte-ID, Signatur und Nonce →
   Worker prüft Geräte- und Room-Berechtigung sowie Quota, erstellt eine
   **Room-ID** und ein **Session-Token** (kurzlebig, an die Session gebunden).
2. **App verbindet sich per WebSocket** mit dem Durable Object (Relay) und
   sendet das Session-Token.
3. **Durable Object verifiziert das Token** (gegen Worker/KV) und hält die
   WebSocket-Verbindung offen.
4. **App streamt Audio** (Opus-codiert) zum Durable Object.
5. **Durable Object injiziert den API-Key** (Worker-Secret) und leitet das
   Audio an die STT-API weiter (z.B. Deepgram Streaming).
6. **STT-Teiltranskript** kommt zurück zum DO → DO leitet an Übersetzungs-API
   weiter (DeepL) → Übersetzung kommt zurück → DO leitet an TTS-API weiter
   (fish.audio) → TTS-Audio kommt zurück.
7. **Durable Object streamt das TTS-Audio** über WebSocket an das
   Gegenüber-Gerät (B).
8. **Die App sieht nie einen API-Key.** Alle API-Calls laufen durch das DO.

**Vorteile:**
- API-Keys bleiben serverseitig (Worker-Secrets) — sicher.
- Durable Objects können WebSocket-Verbindungen halten (Workers können das
  nicht).
- Durable Objects haben keine CPU-Zeit-Limits wie Workers — geeignet für
  Audio-Streaming über Minuten.
- Quota-Tracking im DO (pro Session, pro User).

**Nachteile:**
- Audio läuft durch das DO (zusätzlicher Hop). Latenz-Overhead: ~20–50ms
  (Cloudflare Edge → API-Endpoint). Akzeptabel.
- DO-Kosten: $0.15/Mio. Requests + Speicher. Für ein 2-Personen-Session mit
  Audio-Streaming sind das wenige Cent pro Session. OK.

#### Rollen der Komponenten

- **Geräteidentität:** Wird bei der ersten Einrichtung sicher lokal erzeugt,
  signiert Anfragen und bleibt bei Username-Änderungen unverändert. Der QR-Code
  enthält die öffentliche Kontaktidentität, niemals Provider-Keys.
- **Cloudflare Worker:** Verifiziert Geräte-Signatur oder optionales Konto,
  prüft die Tier-Quota, erstellt Room-IDs, hält serverseitige Provider-Secrets
  und mintet kurzlebige Realtime-Client-Secrets. Der Worker ist stateless.
- **Durable Object (Relay):** Hält WebSocket-Verbindungen (beide Geräte),
  speichert Session-State, injiziert API-Keys in API-Calls, streamt Audio
  zu/von STT/MT/TTS-APIs, trackt Quota. **Pro Session ein DO.**
- **App:** Nutzt Gerätebeweis und Session-Token für die Verbindung. Im
  Produktionspfad sieht sie **nie** einen serverseitigen API-Key; BYOK bleibt
  ein ausdrücklich gewählter lokaler Nutzerpfad.

#### Session-Join-Flow

1. **Host (A) startet Session** → Worker verifiziert Gerätebeweis, prüft Quota,
   erzeugt eine **Room-ID** (z.B. `snail-4821`) und ein **Session-Token**.
   Worker erstellt ein Durable Object für diese Session.
2. **Host zeigt QR-Code** mit Deep-Link-URL (z.B.
   `https://snail.app/join?room=snail-4821&token=xxx`). QR-Code enthält
   URL, nicht nur Room-ID — ermöglicht Universal Links / App Links.
3. **Guest (B) scannt QR-Code** → App öffnet sich per Deep-Link, sendet
   Room-ID + eigenen Gerätebeweis an den Worker.
4. **Worker prüft Geräteberechtigung + Quota** von B, gibt Session-Token an B zurück.
5. **Beide Geräte verbinden sich** per WebSocket mit dem Durable Object
   (Relay) und streamen Audio.

**Session-Lebenszyklus:**
- **Timeout:** Session endet nach 30 Minuten Inaktivität (kein Audio-Stream).
- **Explizites Beenden:** Host oder Guest kann Session beenden → DO wird
  zerstört.
- **Reconnect:** Bei Netzwerkabbruch versucht die App, die WebSocket-
  Verbindung innerhalb 10s wiederherzustellen. Audio-Buffer wird verworfen
  (kein Nachsenden — Live-Gespräch, nicht Aufnahme).
- **Guest ohne Login:** MVP erfordert Clerk-Login für beide Nutzer. Alternative
  für v2: Guest-Join ohne Login (Free-Tier ohne Auth), Login erst bei
  Upgrade auf Paid.

#### Free- vs. Paid-Tier (API-Auswahl pro Tier)

| | **Free Tier** | **Paid Tier** |
|---|---|---|
| **Quota** | 30 Minuten/Monat | Unbegrenzt |
| **Sprachen** | DE/EN/FR/ES/UK | Alle verfügbaren |
| **STT** | Groq Whisper (streaming, sehr schnell) | Deepgram Nova-2 (Streaming, beste Qualität) |
| **Übersetzung** | DeepL Free-Tier (500k Zeichen/Monat kostenlos) | DeepL Pro (unbegrenzt, alle Sprachen) |
| **TTS** | Google Cloud TTS (Standardstimmen, $4/Mio Zeichen) | fish.audio (s2-pro, natürliche Stimmen) |

> Das Durable Object wählt **pro Tier unterschiedliche APIs**. Free-Nutzer
> bekommen die günstigen/schnellen Bausteine, Paid-Nutzer die Premium-
> Bausteine. Das Free-Tier ist ein bewusster Verlustbringer zum Anlocken,
> aber die API-Kosten sind kontrollierbar (Quota-Limit + günstige APIs).

#### Sicherheit gegen Key-Extraktion

1. **Keys nur als Worker-Secrets** — nie im App-Code oder Client.
2. **Produktions-App nutzt Gerätebeweis + Session-Token** — keine serverseitigen
   API-Keys im Client. Lokale BYOK-Keys werden nur verschlüsselt gespeichert.
3. **API-Calls laufen durch das Durable Object** — das DO injiziert den
   API-Key serverseitig. Die App sieht nie einen API-Key.
4. **Session-Tokens sind kurzlebig** (1 Stunde) und an die Session gebunden.
5. **Rate-Limiting pro User** im Worker (verhindert Missbrauch).
6. **Quota-Check** vor Token-Ausgabe und pro API-Call im DO.

---

## 4. Modul-Auswahl (pro Tier)

| Baustein | Free Tier | Paid Tier |
|----------|-----------|-----------|
| **AEC** | OS-native (Android AudioFX / iOS AVAudioSession) | OS-native |
| **Noise Suppression** | RNNoise (on-device, ~10ms) | RNNoise (on-device) |
| **VAD** | Silero VAD (lokal, ~50ms) | Silero VAD (lokal, ~50ms) |
| **STT** | Groq Whisper (streaming, ~100–300ms) | Deepgram Nova-2 (Streaming, ~300ms) |
| **Sentence Boundary** | Heuristik (Punkt/Komma + Längen-Schwellwert) | Heuristik + LLM-basiert |
| **Übersetzung** | DeepL Free-Tier (500k Zeichen/Monat) | DeepL Pro (unbegrenzt) |
| **TTS** | Google Cloud TTS (Standardstimmen) | fish.audio (s2-pro) |
| **Audio-Transport** | WebSocket über Durable Object (Opus) | WebSocket über Durable Object (Opus) |
| **Relay** | Cloudflare Durable Object | Cloudflare Durable Object |
| **TURN (fallback)** | Cloudflare TURN (für WebRTC-Fallback) | Cloudflare TURN |

> **VAD** und **AEC/Noise Suppression** laufen immer lokal — kein API-Call
> nötig, geringste Latenz. **Groq Whisper** ist für Free-Tier gewählt, weil
> es streaming-fähig ist (chunked) und sehr niedrige Latenz hat (~100ms für
> kurze Audio-Chunks). OpenAI Whisper API ist **Batch** (nicht streaming)
> und bricht das Latenz-Budget. **Google Cloud TTS** ist für Free-Tier
> gewählt, weil Edge-TTS inoffiziell ist (keine dokumentierte API, kann
> jederzeit geblockt werden). **fish.audio** ist die bevorzugte Paid-TTS
> (günstiger als ElevenLabs, natürliche Stimmen). API-Details: `reference_id`
> (nicht `voice_id`) im Request-Body, Modell `s2-pro`, Format MP3, API-Key
> via `FISHAUDIO_API_KEY`.

### Fehlende Bausteine (gegenüber v1 ergänzt)

- **AEC (Acoustic Echo Cancellation):** OS-native (Android AudioFX AEC,
  iOS AVAudioSession echoCancelation). Flutter-Plugin: Platform-Channel
  zu nativer Audio-API. **Kritisch** — ohne AEC entsteht Feedback-Loop.
- **Noise Suppression:** RNNoise (on-device, ~10ms CPU). Verbessert STT-
  Qualität in lauter Umgebung massiv.
- **Sentence Boundary Detection:** Heuristik (Satzzeichen + Längen-
  Schwellwert) oder LLM-basiert. Entscheidet, wann ein Teiltranskript
  übersetzt wird.
- **Relay-Server (Durable Object):** Hält WebSocket-Verbindungen, streamt
  Audio, injiziert API-Keys. **Zentraler Baustein**, in v1 fehlend.
- **TURN-Server:** Für WebRTC-Fallback (falls WebSocket nicht ausreicht).
  Cloudflare TURN oder coturn (self-hosted).

---

## 5. Latenz-Budget (Ziel P50 < 2s, P95 < 4s)

| Schritt | P50 (WiFi) | P95 (4G) | Anmerkung |
|---------|-----------|----------|-----------|
| AEC + Noise Suppression | ~10 ms | ~10 ms | On-device, konstant |
| VAD | ~50 ms | ~50 ms | On-device (Silero) |
| Audio-Encoding (Opus) | ~5 ms | ~5 ms | On-device |
| Netzwerk App → DO | ~30 ms | ~150 ms | Cloudflare Edge |
| STT (Streaming, first token) | ~300 ms | ~600 ms | Groq / Deepgram |
| Sentence Boundary | ~20 ms | ~20 ms | Heuristik |
| Übersetzung | ~200 ms | ~500 ms | DeepL |
| TTS (chunked) | ~200 ms | ~500 ms | Google TTS / fish.audio |
| Netzwerk DO → App (Gegenüber) | ~30 ms | ~150 ms | Cloudflare Edge |
| Audio-Decoding + Jitter-Buffer | ~20 ms | ~50 ms | On-device |
| **Summe (P50, WiFi)** | **~865 ms** | | ✅ Unter 2s |
| **Summe (P95, 4G)** | | **~2.035 ms** | ✅ Unter 4s |

> **Wichtig:** Diese Zahlen sind **Schätzungen** und müssen mit einem
> Benchmark validiert werden (siehe `API_BENCHMARK_PLAN.md`). Die
> Pipeline-Parallelierung (STT → Übersetzung → TTS überlappend) kann die
> effektive Latenz weiter reduzieren, da nicht auf jeden Schritt serialisiert
> gewartet wird.

### Größte Latenz-Risiken

1. **Mobilfunk-Latenz:** 4G hat 100–300ms RTT, 3G mehr. Zwei Netzwerk-Hops
   (App → DO, DO → App) verdoppeln das.
2. **STT bei langen Sätzen:** Streaming-STT liefert Teiltranskripte, aber
   die Übersetzung wird erst sinnvoll, wenn eine Satzgrenze erkannt wird.
   Bei langen Sätzen steigt die Latenz.
3. **TTS-Latenz:** fish.audio ist nicht für Echtzeit optimiert (kein
   Streaming-TTS). Wartet auf kompletten Text → generiert MP3 → sendet.
   Alternative: Deepgram Aura (~150ms, streaming) als Paid-TTS.
4. **DO-Overhead:** Audio läuft durch das Durable Object (zusätzlicher Hop).
   Overhead: ~20–50ms. Akzeptabel, aber messen.

---

## 6. Technologie-Stack

- **Frontend (Mobile):** **Flutter** — eine Codebasis für **Android
  (jetzt)** und **iOS (später)**. Flutter hat starke Audio-Streaming-
  Bibliotheken und native Performance. → **Cross-Platform ist die
  Grundsatzentscheidung.**
  - **Audio-Kritische Pfade (AEC, Noise Suppression):** Native Platform-
    Channels (Kotlin/Swift), da Flutter-Plugins für AEC dünn sind.
  - **Audio-I/O:** `record` (Mikrofon) + `just_audio` (Playback) +
    `flutter_soloud` (Low-Latency).
- **Backend (serverless):**
  - **Cloudflare Worker** (TypeScript) — Key-Vault, Clerk-Auth-
    Verifikation, Session-Token-Ausgabe, Room-ID-Erstellung, Quota-Check.
    Stateless, request/response.
  - **Cloudflare Durable Objects** (TypeScript) — WebSocket-Relay, Session-
    State, API-Key-Injection, Audio-Streaming-Proxy, Quota-Tracking. Pro
    Session ein DO.
- **Auth & Subscriptions:** **Clerk** — User-Management, Login/Register,
  Subscription-Status (Free/Paid).
- **Echtzeit-Transport:** WebSocket über Durable Object (Audio-Streams +
  Steuerung). WebRTC als Fallback (mit TURN-Server) für sehr niedrige
  Latenz oder P2P.
- **Audio-Codec:** Opus (16 kHz, mono) für WebSocket-Transport. PCM intern.

### Flutter vs. React Native (Kurzvergleich)

| Kriterium | Flutter | React Native |
|-----------|---------|--------------|
| Audio-Streaming | Sehr gut (record/just_audio) | Gut (react-native-audio) |
| Performance | Nativ (kompiliert) | JS-Bridge (leicht langsamer) |
| AEC / Noise Suppression | Native Platform-Channels nötig | Native Module nötig |
| UI-Konsistenz | Pixel-identisch auf beiden OS | Native Komponenten |
| iOS-Setup | Einfach | Xcode/CocoaPods nötig |
| Empfehlung | ✅ **Start hier** | Solide Alternative |

> **Warum Flutter:** Für eine latenzkritische Audio-App ist die native
> Performance und die ausgereifte Audio-Pipeline ein klarer Vorteil. Du
> baust einmal und deployst auf Android + iOS ohne doppelte Arbeit.
> Audio-kritische Pfade (AEC, Noise Suppression) werden über Platform-
> Channels nativ implementiert (Kotlin/Swift).

### Cloudflare Worker vs. Durable Objects

| Anforderung | Worker | Durable Object |
|-------------|--------|----------------|
| Key-Vault (Secrets) | ✅ | ✅ (via Worker erstellt) |
| Clerk-JWT verifizieren | ✅ | — |
| Quota-Check | ✅ (KV/D1) | ✅ (in-memory) |
| WebSocket-Verbindung halten | ❌ | ✅ |
| Audio-Streaming-Proxy | ❌ (CPU-Limit) | ✅ (kein CPU-Limit) |
| API-Key-Injection | ❌ | ✅ |
| Session-State | ❌ (stateless) | ✅ (persistent) |

> **Worker** für stateless Gateway (Auth, Quota, Token-Ausgabe).
> **Durable Object** für stateful Relay (WebSocket, Audio-Streaming,
> Session-State). Das ist die natürliche Cloudflare-Architektur für
> Echtzeit-Anwendungen.

---

## 7. Offene Fragen

### Kritisch (vor Implementierung klären)

1. ~~**Wie funktioniert das Session-Token technisch?**~~ → **Geklärt:**
   Durable Object als Streaming-Proxy mit API-Key-Injection. App sendet
   Audio + Session-Token, DO injiziert API-Key und leitet an APIs weiter.
2. **AEC auf Zielhardware:** Funktioniert OS-native AEC (Android AudioFX,
   iOS AVAudioSession) zuverlässig mit Bluetooth-Headsets? Muss mit
   Prototyp auf echten Geräten getestet werden.
3. **Durable Object Performance:** Wie hoch ist die Latenz für Audio-
   Streaming durch ein DO? Muss gemessen werden (Benchmark).
4. **Unequal Tiers:** Was passiert, wenn A=Free und B=Paid? Welche APIs
   gelten für die gemeinsame Session? → Vorschlag: Das niedrigere Tier
   bestimmt die APIs (Free-APIs für beide), oder: jeder bekommt seine
   eigene Pipeline-Qualität (komplexer).

### Wichtig

5. **WebRTC vs. WebSocket:** WebSocket über DO ist einfacher (kein NAT-
   Traversal). WebRTC hat niedrigere Latenz (P2P möglich), aber komplexeres
   NAT-Traversal (TURN nötig). → Vorschlag: WebSocket für MVP, WebRTC
   für v2 (Latenz-Optimierung).
6. **Quota-Zählung:** Pro User, pro Session oder pro API-Call? → Vorschlag:
   Pro User (Clerk-User-ID), gezählt im DO, gespeichert in KV/D1.
7. **Datenschutz (DSGVO):** Audio-Streams gehen zu US-Anbietern (Deepgram,
   Google, Groq). Für EU-Nutzer relevant. → Datenschutzerklärung nötig,
   Opt-In für Audio-Verarbeitung. DeepL ist EU-basiert (DE) — Vorteil.
8. **Offline-Modus:** On-device Whisper (small/tiny) als Fallback? → v2.

### Sekundär

9. **QR-Code vs. manueller Code:** Beides (QR-Code primär, manueller Code
   als Fallback).
10. **Welche Sprachen zuerst?** → DE/EN als Start, dann FR/ES.
11. **Dolmetscher-Modus:** Eine Person spricht, Übersetzung laut für alle.
    → v2, Nice-to-have.

---

## 8. Nächste Schritte

**Reihenfolge (risikobasiert — höchstes Risiko zuerst):**

1. **Pipeline-Prototyp (lokal, ein Gerät)** — Mikro → AEC → VAD → STT →
   Übersetzung → TTS → Playback auf **einem Gerät** mit festen API-Keys
   (ohne Worker/Auth). Validiert die Kernhypothese: Kann die Pipeline
   P50 < 2s erreichen?
2. **Latenz-Benchmark** — Messe jede API einzeln (P50/P95, WiFi + 4G).
   Siehe `API_BENCHMARK_PLAN.md`.
3. **AEC-Prototyp** — Teste OS-native AEC mit Flutter + BT-Headset auf
   Android. Wenn AEC nicht funktioniert, ist das Produkt unbrauchbar.
4. **Durable Object Prototyp** — WebSocket-Relay + API-Key-Injection +
   Audio-Streaming zwischen zwei Geräten.
5. **Cloudflare Worker-Skeleton** — Key-Vault, Clerk-Auth-Verifikation,
   Session-Token-Ausgabe, Tier-Quota-Logik, Room-ID-Erstellung.
6. **Clerk-Integration** — User-Auth in der Flutter-App, Subscription-
   Status abfragen.
7. **Tier-Logik** — DO wählt APIs pro Tier, trackt Quota.
8. **Session-Join-Flow** — Room-ID, QR-Code (Deep-Link), WebSocket-
   Verbindung zwischen den Geräten.
9. **Zwei-Geräte-Integration** — Pipeline über zwei Geräte, Audio-Stream
   über DO-Relay.

> **Begründung der Reihenfolge:** Die Pipeline (Schritt 1) und AEC (Schritt 3)
> sind die höchsten Risiken — technische Machbarkeit der Latenz und Echo-
> Vermeidung. Auth und Backend sind lösbare Ingenieursaufgaben. Validiere
> das Risiko zuerst.

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
   │  3. QR-Code zeigt auf https://xyz.trycloudflare.com/join?session=***
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

### Wann der Ansatz sinnvoll ist

- **Proof-of-Concept / Weekend-Prototyp:** Schnellster Weg, die Pipeline
  über zwei Geräte zu testen, ohne Backend.
- **Persönliches Tool ohne Monetarisierung:** Wenn nur du und eine Person
  es nutzt und API-Key-Sicherheit irrelevant ist.
- **Nicht sinnvoll für:** Alles mit Monetarisierung, Multi-User, Skalierung,
  oder öffentlichen Launch.

---

## Anhang B: Änderungsprotokoll (v1 → v2)

| Änderung | Begründung |
|----------|-----------|
| Latenz-Ziel: hart < 2s → P50 < 2s, P95 < 4s | Mobilfunk-Latenz realistisch abgebildet |
| Pipeline: AEC + Noise Suppression als Schritt [0] | Feedback-Loop-Vermeidung, STT-Qualität |
| Pipeline: Audio-Encoding/Decoding + Jitter-Buffer | Vollständige Pipeline |
| Pipeline: Sentence Boundary Detection | Streaming-STT braucht Satzgrenzen |
| Pipeline: Streaming-Translation + Chunked TTS | Latenz-Reduktion durch Parallelierung |
| Architektur: Worker-only → Worker + Durable Objects | DO für WebSocket-Relay + Audio-Streaming |
| Session-Token-Modell: aufgelöst | DO als Streaming-Proxy mit API-Key-Injection |
| Free STT: Whisper API → Groq Whisper | Whisper API ist Batch (nicht streaming) |
| Free TTS: Edge-TTS → Google Cloud TTS | Edge-TTS ist inoffiziell/instabil |
| Free Übersetzung: Google Translate → DeepL Free | Google Translate API ist nicht kostenlos |
| Modul-Auswahl: Relay (DO) + TURN ergänzt | Fehlender Baustein in v1 |
| LE Audio: Begründung aktualisiert | "Aktuell nicht zuverlässig für 2× HFP", nicht "nicht mobil-tauglich" |
| Nächste Schritte: Pipeline-Prototyp zuerst | Risikobasierte Priorisierung |
| Offene Fragen: priorisiert (kritisch/wichtig/sekundär) | Klarheit für Implementierung |
