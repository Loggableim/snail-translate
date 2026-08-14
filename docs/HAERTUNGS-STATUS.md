# Härtungsstatus (Arbeitsstand)

Dieser Bericht ist ein belegter Zwischenstand zum Härtungs-Masterprompt. Er
behauptet keinen Abschluss, solange die offenen Betreiberentscheidungen und
die vollständige Gerätesession nicht nachgewiesen sind.

## Verifizierte Arbeitsbereiche

| Bereich | Evidenz | Ergebnis |
| --- | --- | --- |
| Worker-Fetch-Tests | `worker/src/index.test.ts`; `npx vitest run` | 24/24 Tests grün |
| Durable Objects | `durable-object/src/*.test.ts`; Vitest | 23/23 Tests grün |
| Durable-Object-Typen | `durable-object/tsconfig.json`; `npx tsc --noEmit` | grün |
| Flutter-Analyse | `flutter_app`; `tools/flutter.ps1 analyze` | keine Issues |
| Flutter-Tests | `flutter_app/test`; `tools/flutter.ps1 test` | 183 grün, 1 erwarteter Skip |
| Protokoll-Drift | `tools/generate-protocol.mjs` | keine Drift |
| CI-Release-Smoke | `.github/workflows/ci.yml` | Split-APK-Signatur- und Größenprüfung vorhanden |
| Deploy-Schutz | `tools/check-deploy-config.mjs` | blockiert aktuelle unsichere Produktionskonfiguration |

## Aktuelle Blocker

1. Die Produktionsauthentifizierung (`DEV_MODE`/Clerk bzw. signierte
   `DEVICE_ID_AUTH`-Anfragen) ist eine ausdrücklich offene Betreiberentscheidung
   des Masterprompts. Der Guard meldet sie aktuell als unsicher; keine
   Konfiguration wurde eigenmächtig umgeschaltet.
2. Ein vollständiger Host/Guest-Audiolauf auf echter Hardware mit Provider,
   Bluetooth und Bildschirm aus ist nicht nachgewiesen.
3. Der lokale Release-Build benötigt absichtlich eine außerhalb der
   Versionskontrolle gehaltene `android/key.properties`; der signierte Build
   ist als CI-Smoke definiert, aber lokal nicht ohne Betreiber-Schlüssel
   reproduzierbar.

## Arbeitsbaum

Die Referenzdatei `docs/HAERTUNGS-MASTERPROMPT.md` ist bewusst ungetrackt und
wird nicht verändert. Dieser Statusbericht ist ein separates Arbeitsartefakt.
