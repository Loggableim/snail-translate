# Vorbereitungs-Prompt: Zuhör-Modus (Guide Mode)

> Diesen Prompt **vor** `docs/ZUHOER-MODUS.md` an einen Coding-Agenten übergeben.
> Er richtet die Arbeitsumgebung ein, stellt die Baseline her und übergibt
> sauber an den Implementierungsauftrag. Er implementiert **kein** Feature.

---

## 1. Rolle und Auftrag

Du bist der **Vorbereitungs-Agent** für die Implementierung des Zuhör-Modus in
Snail. Dein Auftrag: Arbeitsumgebung einrichten, Baseline verifizieren, einen
bekannten Alt-Test reparieren, Branch anlegen, Baseline-Bericht schreiben.
Danach endet dein Auftrag — die Feature-Implementierung übernimmt ein zweiter
Agent mit `docs/ZUHOER-MODUS.md`.

**Projekt:** `snail/` — Echtzeit-Konversationsübersetzer (Flutter-Android-App,
Cloudflare Worker, Durable Objects). Repo `github.com/Loggableim/snail-translate`,
Arbeitsbranch `agent/snail-architecture`.

---

## 2. Arbeitsregeln

1. **Toolchain ist portabel und vorgegeben.** Niemals `flutter` direkt aufrufen:
   ```powershell
   .\tools\flutter.ps1 analyze
   .\tools\flutter.ps1 test
   ```
   Worker: `cd worker; npx vitest run`. Durable Objects:
   `cd durable-object; npx tsc --noEmit; npx vitest run`.
   Protokoll: `node tools/generate-protocol.mjs`.
2. **Keine Secrets** in Code, Logs, Tests, Commits. `--no-verify` ist verboten.
3. **Commits klein und thematisch**, englische Einzeiler mit Scope-Präfix
   (`test(relay): …`, `chore: …`).
4. **Niemals einen Test abschwächen, um ihn grün zu bekommen.** Der eine
   bekannte Alt-Test (Schritt 4) wird **begründet** korrigiert.
5. **Nichts implementieren.** Kein Feature-Code, keine neuen Screens, keine
   Protokoll-Typen. Nur Umgebung + Baseline + ein Testfix.

---

## 3. Schritte

### Schritt 1 — Arbeitsumgebung prüfen

```bash
cd snail
git status --short          # Arbeitsbaum: nur untracked .tmp-* Artefakte + docs/HAERTUNGS-MASTERPROMPT.md erwartet
git branch --show-current   # agent/snail-architecture
ls .tooling/flutter/bin     # vendored Flutter SDK vorhanden
ls .tooling/jdk-17.0.19+10  # vendored JDK vorhanden
```

- **Erwartet:** Branch `agent/snail-architecture`, keine uncommitteten
  Änderungen an getrackten Dateien. Die `.tmp-*`-Dateien sind Debug-Artefakte
  früherer Sessions und bleiben unangetastet (nicht committen, nicht löschen).
- **Falls getrackte Dateien dirty sind:** stoppen und melden, nicht committen.

### Schritt 2 — Branch anlegen

```bash
git checkout -b agent/guide-mode
```

Alle Arbeiten (Vorbereitung + Feature) laufen auf diesem Branch.

### Schritt 3 — Baseline verifizieren (sechs Checks)

| # | Befehl | Erwartet |
|---|---|---|
| 1 | `.\tools\flutter.ps1 analyze` | „No issues found!" |
| 2 | `.\tools\flutter.ps1 test` | 198 grün, 1 skip |
| 3 | `cd worker && npx vitest run` | 24/24 grün |
| 4 | `cd durable-object && npx tsc --noEmit` | clean |
| 5 | `cd durable-object && npx vitest run` | **23/24** — 1 bekannter Fehler, s. Schritt 4 |
| 6 | `node tools/generate-protocol.mjs && git diff --exit-code -- shared/dto/v1/generated flutter_app/lib/generated` | keine Drift |

### Schritt 4 — Bekannten Alt-Test reparieren

**Befund:** `durable-object/src/relay.test.ts:144` — Test „rejects oversized chat
and PCM messages" schlägt fehl:

```
AssertionError: expected 'Invalid binary PCM frame' to include 'too long'
```

**Ursache (verifiziert):** Der Test sendet `"x".repeat(10_001)` und erwartet
„too long". Das Chat-Limit wurde in Commit `aae2c4e` von 10 000 auf
`MAX_CHAT_TEXT_LENGTH = 16_384` erhöht (`SnailRelay.ts:101`), der Test wurde
nicht mitgezogen. **Der Test schreibt altes Verhalten fest — er ist falsch, nicht
der Code.**

**Fix:** Die Chat-Nachricht im Test auf eine Länge oberhalb des aktuellen Limits
bringen (z. B. `"x".repeat(16_385)`) und den PCM-Teil unverändert lassen. Die
Assertion auf „too long" bleibt.

**Achtung:** Nicht das Limit im Code senken — 16 384 ist die gewollte,
dokumentierte Grenze. Nur den Test anpassen.

**Commit:** `test(relay): align oversized-chat case with the 16k message limit`

**Abnahme:** `cd durable-object && npx vitest run` → 24/24 grün.

### Schritt 5 — Baseline-Bericht schreiben

Datei `docs/ZUHOER-MODUS-BASELINE.md` im Format von `docs/HAERTUNGS-STATUS.md`:

```markdown
# Zuhör-Modus — Baseline-Bericht

Stand: <Datum>, Branch `agent/guide-mode`, Basis-Commit <sha>

## Verifizierte Baseline

| Check | Befehl | Ergebnis |
|---|---|---|
| Flutter-Analyse | `.\tools\flutter.ps1 analyze` | <Ergebnis> |
| Flutter-Tests | `.\tools\flutter.ps1 test` | <N> grün, <M> skip |
| Worker-Tests | `cd worker && npx vitest run` | <N>/<N> grün |
| DO-Typcheck | `cd durable-object && npx tsc --noEmit` | <Ergebnis> |
| DO-Tests | `cd durable-object && npx vitest run` | <N>/<N> grün |
| Protokoll-Drift | `node tools/generate-protocol.mjs` + diff | keine Drift |

## Reparierter Alt-Test

- `durable-object/src/relay.test.ts:144` — Chat-Limit 10k → 16k (Commit `aae2c4e`)
  nicht nachgezogen; Test korrigiert, Code unverändert.

## Arbeitsbaum

- Branch `agent/guide-mode` von `agent/snail-architecture` (<sha>).
- Untracked: `.tmp-*`-Debug-Artefakte (unangetastet), `docs/HAERTUNGS-MASTERPROMPT.md`
  (bewusst ungetrackt).

## Übergabe

Baseline grün. Nächster Schritt: `docs/ZUHOER-MODUS.md` (Implementierungsauftrag,
Phasen 1–4, Punkte G-01…G-28).
```

**Commit:** `document guide-mode baseline`

### Schritt 6 — Push und Übergabe

```bash
git push -u origin agent/guide-mode
```

**Abschlussmeldung** (kurz, mit Evidenz):

1. Branch + Basis-Commit
2. Baseline-Tabelle (sechs Checks, Befehl → Ergebnis)
3. Reparierter Test + Commit-Hash
4. Explizite Zeile: was **nicht** verifiziert wurde (z. B. Gerätetest)
5. Übergabehinweis: nächster Agent startet mit `docs/ZUHOER-MODUS.md`, Phase 1

---

## 4. Nicht-Ziele

- Kein Feature-Code (keine Screens, keine Relay-Änderungen, keine neuen
  Protokoll-Typen).
- Kein Gerätetest (kein adb, kein APK-Build) — das ist Phase 4 des
  Implementierungsauftrags.
- Kein Aufräumen der `.tmp-*`-Dateien.
- Keine Änderung an `docs/HAERTUNGS-MASTERPROMPT.md`.
