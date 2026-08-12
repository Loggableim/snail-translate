# Snail – verbindliches Zielbild

## Fish Audio Realtime als zusätzliche Standalone-Engine

Fish Audio Realtime Streaming wird als eigenständige Live-Audio-Lösung neben
OpenAI Realtime Translation vorgesehen. Die Engine wird bewusst in der GUI
gewählt und nicht als stiller Fallback vermischt. Referenz:
[Fish-Audio-Best-Practices für Realtime Streaming](https://docs.fish.audio/developer-guide/best-practices/real-time-streaming).

Leitplanken sind vollständige Wörter bzw. Wortgruppen mit Leerzeichen, 5–10-
Wort-Puffer, 2–3 Audio-Chunks Prebuffer, wiederverwendete Verbindungen,
Disconnect-/Retry-Behandlung sowie Latenz- und Audio-Gap-Messung.

`Mikrofon → STT/Übersetzung → Fish-Audio-Realtime-TTS → Jitter-Queue → Playback`

- [x] 43. Fish Audio Realtime als eigenen Provider-/Engine-Typ modellieren.
- [x] 44. Fish Audio als Standalone-Live-Übersetzung neben OpenAI Realtime implementieren.
- [x] 45. Fish-Audio-BYOK-Key sicher konfigurieren, testen und niemals loggen.
- [x] 46. Fish-WebSocket mit Wiederverwendung, Disconnect-Erkennung und begrenzten Retries implementieren.
- [ ] 47. Übersetzungstext in vollständigen Wörtern bzw. 5–10-Wort-Puffern streamen.
- [ ] 48. Fish-Audio-Chunks mit Prebuffer und Jitter-/Playback-Handling abspielen.
- [x] 49. Fish-Latenzmodus `balanced` und Qualitätsmodus in der GUI anbieten.
- [ ] 50. Fish Audio in Session, Standalone-Modus, Quota und Verlauf kennzeichnen.
- [ ] 51. Mehrere auswählbare Fish-Audio-Stimmen in der GUI anzeigen.
- [ ] 52. Voice-Auswahl über `reference_id`/Voice-ID konfigurieren und persistieren.
- [ ] 53. Voice-Metadaten cachen und Stimmen für schnelle Sessions vorbereiten.
- [ ] 54. Voice-Wechsel zwischen abgeschlossenen Turns ermöglichen.
- [ ] 55. Temperatur, Top-p und Sprechgeschwindigkeit begrenzt anbieten.
- [ ] 56. Fish-Audio-Key-Test mit Voice-, Verbindungs- und Latenzdiagnose ergänzen.
- [ ] 57. Fish-vs.-OpenAI-Test für TTFA, Turn-Latenz und Audio-Gaps durchführen.
- [ ] 58. Fish-Fehler, Retry-Zustände und Providerwechsel verständlich anzeigen.
- [ ] 59. Fish-Integration mit Protokoll-, Audio-Queue- und Widget-Tests absichern.

Dieses Dokument ist die fortlaufende Zielbild- und Umsetzungs-Checkliste für Snail.
Jeder Punkt ist ein eigenständiges Ziel. Ein Agent bearbeitet pro Run genau einen
offenen Punkt, verifiziert ihn mit passenden Tests oder sichtbarer Laufzeitprüfung,
aktualisiert den Status und committet nur die zu diesem Punkt gehörenden Dateien.

## Arbeitsregel für Agenten

Bei den Fish-Audio-Punkten ist die offizielle Dokumentation verbindliche
technische Referenz: [Fish Audio – Real-time Voice Streaming](https://docs.fish.audio/developer-guide/best-practices/real-time-streaming).
Der Agent soll daraus insbesondere Streaming-Textpuffer, `reference_id`,
Latenzmodus, Connection-Management, Retry-Verhalten und Audio-Playback ableiten
und die aktuelle API-Signatur vor dem Implementieren erneut prüfen.

Bearbeite immer den ersten offenen Punkt in der Reihenfolge. Analysiere zuerst den
Ist-Zustand, ändere nur den gewählten Punkt, erhalte vorhandene Nutzeränderungen,
führe fokussierte Tests aus und dokumentiere verbleibende Einschränkungen. Nach
erfolgreicher Verifikation: Status auf `✅` setzen und einen kleinen, sachlichen
Commit erstellen. Danach endet der Run; der nächste Agent/Run beginnt mit dem
nächsten offenen Punkt.

## Zielpunkte

- [x] 01. Hauptnutzen im ersten Startbild erklären.
- [x] 02. Unterstützte Sprachen sichtbar dokumentieren.
- [x] 03. Provider-Auswahl verständlicher beschreiben.
- [x] 04. Nicht fertige Features aus der UI entfernen oder eindeutig als Vorschau markieren.
- [x] 05. Geführten Erststart mit Testaufnahme einführen.
- [x] 06. Mikrofonberechtigungen verständlich begründen.
- [x] 07. Headset-Prüfung vor der ersten Session durchführen.
- [x] 08. QR-Scan mit verständlichen Statusschritten versehen.
- [x] 09. Session-Code zusätzlich manuell eingeben lassen.
- [x] 10. Gastbeitritt ohne unnötige Login-Hürden ermöglichen.
- [x] 11. Sprache automatisch erkennen und bestätigen lassen.
- [x] 12. Tutorial für die Sprechrichtung einbauen.
- [x] 13. Verbindungstest vor dem Gespräch anbieten.
- [x] 14. Session-Abbruch mit klarer Rückfrage absichern.
- [x] 15. Input-, Output- und Gesamtlatenz anzeigen.
- [x] 16. Provider-Timeouts mit einer begrenzten Retry-Strategie behandeln.
- [x] 17. Reconnect ohne doppelte Audioausgabe implementieren.
- [x] 18. Sample-Rate-Konvertierung zentralisieren.
- [x] 19. Audiopegel visualisieren.
- [x] 20. Clipping erkennen und verständlich melden.
- [x] 21. Stille-Erkennung lokal optimieren.
- [x] 22. Lautsprecher- und Kopfhörermodus sauber trennen.
- [x] 23. Audio-Wiedergabe bei App-Wechsel absichern.
- [x] 24. Provider-Key-Test mit Diagnosebericht anbieten.
- [x] 25. Nachrichten mit eindeutigen IDs versehen.
- [x] 26. Nachrichtenstatus `queued`, `sent`, `delivered`, `read` einführen.
- [x] 27. Offline-Nachrichten persistent speichern.
- [x] 28. D1 als Message Store implementieren.
- [x] 29. Doppelte Nachrichten idempotent behandeln.
- [x] 30. Anhänge mit einem verbindlichen Größenlimit versehen.
- [x] 31. Sprachnachrichten ergänzen.
- [x] 32. Nachrichtensuche einbauen.
- [x] 33. Nachrichtenbearbeitung und Löschung spezifizieren und umsetzen.
- [x] 34. Kontaktanfragen akzeptierbar oder ablehnbar machen.
- [x] 35. Kontakte blockieren können.
- [x] 36. Inaktive Sessions automatisch bereinigen.
- [x] 37. Große Services in kleinere Komponenten teilen.
- [x] 38. UI, Domain-Logik und Transport konsequenter trennen.
- [x] 39. Gemeinsame DTOs zwischen Flutter und Worker versionieren.
- [x] 40. Fehlerklassen statt freier Fehlermeldungen verwenden.
- [x] 41. Historische Pipeline eindeutig als Legacy markieren.
- [x] 42. Lifecycle- und Dispose-Verhalten aller Services testen.

## Kurzer Persistent-Goal-Prompt für andere Agenten

> Arbeite am Snail-Zielbild in `zielbild.md`. Nimm genau den ersten offenen
> Checklistenpunkt, analysiere zuerst den Ist-Zustand, implementiere nur diesen
> Punkt, erhalte fremde Änderungen, ergänze fokussierte Tests und prüfe die
> sichtbare/runtime-relevante Wirkung. Setze den Punkt erst nach erfolgreicher
> Verifikation auf `✅`, dokumentiere kurz die Prüfung und committe ausschließlich
> die zugehörigen Änderungen. Beende den Run danach; im nächsten Run folgt der
> nächste offene Punkt. Für Fish-Audio-Punkte verwende zusätzlich die offizielle
> Referenz https://docs.fish.audio/developer-guide/best-practices/real-time-streaming
> und prüfe daraus den aktuellen Realtime-Vertrag. Bei Blockade nichts vortäuschen: Ursache und benötigte
> Entscheidung dokumentieren.
