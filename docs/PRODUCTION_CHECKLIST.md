# Snail Production-Handoff

Diese Schritte werden nur in der Cloudflare-/Clerk-Umgebung ausgeführt. Keine
Provider-Keys oder Secret-Werte in Git, `.env`-Dateien oder der APK speichern.

## Pflichtkonfiguration

```powershell
wrangler secret put SESSION_SECRET
wrangler secret put CLERK_JWKS_URL
wrangler secret put CLERK_ISSUER
```

`CLERK_JWKS_URL` und `CLERK_ISSUER` können alternativ als nicht geheime
Worker-Variablen gesetzt werden. In Production muss `DEV_MODE` deaktiviert
sein. `SESSION_SECRET` muss zufällig, lang und für Worker und Durable Object
identisch sein.

## Optionale Provider

```powershell
wrangler secret put OPENAI_API_KEY
wrangler secret put TURN_URL
wrangler secret put TURN_USERNAME
wrangler secret put TURN_CREDENTIAL
```

`OPENAI_API_KEY` wird ausschließlich zum Minten kurzlebiger Realtime-Secrets
verwendet. Lokale BYOK-Keys werden nicht an den Worker gesendet. TURN-Credentials
sollten kurzlebig und rotierbar sein.

## Deployment und Prüfung

```powershell
wrangler deploy
Invoke-RestMethod https://<worker-host>/api/health
```

Erwartet wird HTTP 200 mit `status: "ok"` sowie `configured.sessionSecret: true`
und `configured.clerk: true`. Fehlt eine Pflichtkonfiguration, antwortet der
Health-Endpoint mit HTTP 503 und `status: "degraded"`.

## APK-Konfiguration

```powershell
.\tools\flutter.ps1 build apk --release `
  --dart-define=CLERK_PUBLISHABLE_KEY=<publishable-key> `
  --dart-define=SNAIL_WORKER_URL=https://<worker-host>
```

Vor einer Veröffentlichung: Secret-Scan, Flutter-Test, Worker-Tests, Durable-
Object-Typecheck und ein Test auf mindestens zwei echten Android-Geräten.
