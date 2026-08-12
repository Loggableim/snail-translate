# Snail – verbindliches Zielbild

Dieses Dokument ist die fortlaufende Zielbild- und Umsetzungs-Checkliste für Snail.
Jeder Punkt ist ein eigenständiges Ziel. Ein Agent bearbeitet pro Run genau einen
offenen Punkt, verifiziert ihn mit passenden Tests oder sichtbarer Laufzeitprüfung,
aktualisiert den Status und committet nur die zu diesem Punkt gehörenden Dateien.

## Arbeitsregel für Agenten

Bearbeite immer den ersten offenen Punkt in der Reihenfolge. Analysiere zuerst den
Ist-Zustand, ändere nur den gewählten Punkt, erhalte vorhandene Nutzeränderungen,
führe fokussierte Tests aus und dokumentiere verbleibende Einschränkungen. Nach
erfolgreicher Verifikation: Status auf `✅` setzen und einen kleinen, sachlichen
Commit erstellen. Danach endet der Run; der nächste Agent/Run beginnt mit dem
nächsten offenen Punkt.

## Zielpunkte

- [x] 01. Hauptnutzen im ersten Startbild erklären.
- [x] 02. Unterstützte Sprachen sichtbar dokumentieren.
- [ ] 03. Provider-Auswahl verständlicher beschreiben.
- [ ] 04. Nicht fertige Features aus der UI entfernen oder eindeutig als Vorschau markieren.
- [ ] 05. Geführten Erststart mit Testaufnahme einführen.
- [ ] 06. Mikrofonberechtigungen verständlich begründen.
- [ ] 07. Headset-Prüfung vor der ersten Session durchführen.
- [ ] 08. QR-Scan mit verständlichen Statusschritten versehen.
- [ ] 09. Session-Code zusätzlich manuell eingeben lassen.
- [ ] 10. Gastbeitritt ohne unnötige Login-Hürden ermöglichen.
- [ ] 11. Sprache automatisch erkennen und bestätigen lassen.
- [ ] 12. Tutorial für die Sprechrichtung einbauen.
- [ ] 13. Verbindungstest vor dem Gespräch anbieten.
- [ ] 14. Session-Abbruch mit klarer Rückfrage absichern.
- [ ] 15. Input-, Output- und Gesamtlatenz anzeigen.
- [ ] 16. Provider-Timeouts mit einer begrenzten Retry-Strategie behandeln.
- [ ] 17. Reconnect ohne doppelte Audioausgabe implementieren.
- [ ] 18. Sample-Rate-Konvertierung zentralisieren.
- [ ] 19. Audiopegel visualisieren.
- [ ] 20. Clipping erkennen und verständlich melden.
- [ ] 21. Stille-Erkennung lokal optimieren.
- [ ] 22. Lautsprecher- und Kopfhörermodus sauber trennen.
- [ ] 23. Audio-Wiedergabe bei App-Wechsel absichern.
- [ ] 24. Provider-Key-Test mit Diagnosebericht anbieten.
- [ ] 25. Nachrichten mit eindeutigen IDs versehen.
- [ ] 26. Nachrichtenstatus `queued`, `sent`, `delivered`, `read` einführen.
- [ ] 27. Offline-Nachrichten persistent speichern.
- [ ] 28. D1 als Message Store implementieren.
- [ ] 29. Doppelte Nachrichten idempotent behandeln.
- [ ] 30. Anhänge mit einem verbindlichen Größenlimit versehen.
- [ ] 31. Sprachnachrichten ergänzen.
- [ ] 32. Nachrichtensuche einbauen.
- [ ] 33. Nachrichtenbearbeitung und Löschung spezifizieren und umsetzen.
- [ ] 34. Kontaktanfragen akzeptierbar oder ablehnbar machen.
- [ ] 35. Kontakte blockieren können.
- [ ] 36. Inaktive Sessions automatisch bereinigen.
- [ ] 37. Große Services in kleinere Komponenten teilen.
- [ ] 38. UI, Domain-Logik und Transport konsequenter trennen.
- [ ] 39. Gemeinsame DTOs zwischen Flutter und Worker versionieren.
- [ ] 40. Fehlerklassen statt freier Fehlermeldungen verwenden.
- [ ] 41. Historische Pipeline eindeutig als Legacy markieren.
- [ ] 42. Lifecycle- und Dispose-Verhalten aller Services testen.

## Kurzer Persistent-Goal-Prompt für andere Agenten

> Arbeite am Snail-Zielbild in `zielbild.md`. Nimm genau den ersten offenen
> Checklistenpunkt, analysiere zuerst den Ist-Zustand, implementiere nur diesen
> Punkt, erhalte fremde Änderungen, ergänze fokussierte Tests und prüfe die
> sichtbare/runtime-relevante Wirkung. Setze den Punkt erst nach erfolgreicher
> Verifikation auf `✅`, dokumentiere kurz die Prüfung und committe ausschließlich
> die zugehörigen Änderungen. Beende den Run danach; im nächsten Run folgt der
> nächste offene Punkt. Bei Blockade nichts vortäuschen: Ursache und benötigte
> Entscheidung dokumentieren.

