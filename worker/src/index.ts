/**
 * Snail Worker — Cloudflare Worker (Edge Gateway).
 *
 * Dev Mode (DEV_MODE=true): Simple API key auth, no Clerk.
 * Prod Mode: Clerk JWT verification.
 *
 * Routes:
 *   GET  /api/health          — Health check
 *   POST /api/rooms           — Create room (host)
 *   POST /api/rooms/:id/join  — Join room (guest)
 *   GET  /api/quota           — Quota status
 *   WS   /ws?room=<id>        — WebSocket → Durable Object
 */

import { SnailRelay } from "../../durable-object/src/SnailRelay";
import { AppShareRelay } from "../../durable-object/src/AppShareRelay";
export { SnailRelay, AppShareRelay };

// ── Types ────────────────────────────────────────────────────────────

export interface Env {
  SNAIL_KV: KVNamespace;
  SNAIL_RELAY: DurableObjectNamespace;
  SNAIL_APP_SHARE_RELAY: DurableObjectNamespace;
  CLERK_JWKS_URL: string;
  CLERK_ISSUER: string;
  GROQ_API_KEY: string;
  DEEPGRAM_API_KEY: string;
  FISHAUDIO_API_KEY: string;
  /** Optional platform-owned key used only to mint short-lived Realtime secrets. */
  OPENAI_API_KEY?: string;
  TURN_URL?: string;
  TURN_USERNAME?: string;
  TURN_CREDENTIAL?: string;
  SESSION_SECRET: string;
  DEV_MODE?: string;
  DEV_API_KEY?: string;
  /** Development-only: allow the app's persistent Snail identity as auth. */
  DEV_ALLOW_IDENTITY_AUTH?: string;
  /** Explicit production opt-in for device-identity deployments without Clerk. */
  DEVICE_ID_AUTH?: string;
  /** Comma-separated browser origins allowed to receive CORS headers. */
  CORS_ORIGINS?: string;
}

interface SessionTokenPayload {
  sub: string;
  room: string;
  role: "host" | "guest";
  tier: "free" | "paid";
  exp: number;
  iat: number;
}

// ── Constants ────────────────────────────────────────────────────────

const FREE_QUOTA_SECONDS = 30 * 60;
const SESSION_TOKEN_TTL = 3600;
const ROOM_ID_LENGTH = 8;
const ROOM_ID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MAX_ROOM_ID_ATTEMPTS = 5;
const APP_SHARE_TTL = 15 * 60;
const REALTIME_SECRET_LIMIT = 10;
const REALTIME_SECRET_WINDOW_SECONDS = 60;
const ROOM_RATE_WINDOW_SECONDS = 60;
const ROOM_RATE_LIMITS = { create: 10, join: 20, websocket: 40, failedJoin: 5 } as const;
const TELEMETRY_LIMIT = 30;
const TELEMETRY_WINDOW_SECONDS = 60;

function observabilityLog(event: string, fields: Record<string, string | number | boolean>): void {
  // Operational telemetry must never contain tokens, keys, message bodies, or
  // raw user identifiers.
  console.log(JSON.stringify({ service: "snail-worker", event, ...fields }));
}

function telemetryLabel(value: unknown, maxLength: number): string {
  if (typeof value !== "string") return "unknown";
  const trimmed = value.trim();
  if (!trimmed || !/^[A-Za-z0-9_.:/-]+$/.test(trimmed) ||
      /(?:AIza|sk-|gsk_|bot[0-9]+:)/i.test(trimmed)) return "unknown";
  return trimmed.slice(0, maxLength);
}

async function handleTelemetry(request: Request, env: Env): Promise<Response> {
  const origin = request.headers.get("Origin") || "";
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const window = Math.floor(Date.now() / (TELEMETRY_WINDOW_SECONDS * 1_000));
  const key = `telemetry:${ip}:${window}`;
  const count = Number(await env.SNAIL_KV.get(key) || "0");
  if (count >= TELEMETRY_LIMIT) {
    observabilityLog("rate_limit_hit", { action: "telemetry", limit: TELEMETRY_LIMIT });
    return json({ error: "Telemetry rate limit exceeded" }, 429, origin, env.CORS_ORIGINS);
  }
  await env.SNAIL_KV.put(key, String(count + 1), { expirationTtl: TELEMETRY_WINDOW_SECONDS + 5 });

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Invalid telemetry payload" }, 400, origin, env.CORS_ORIGINS);
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json({ error: "Invalid telemetry payload" }, 400, origin, env.CORS_ORIGINS);
  }
  const input = body as Record<string, unknown>;
  const provider = telemetryLabel(input.provider, 32);
  const context = telemetryLabel(input.context, 64);
  const code = telemetryLabel(input.code, 96);
  const status = typeof input.status === "number" && Number.isInteger(input.status)
    ? Math.max(0, Math.min(999, input.status))
    : undefined;
  observabilityLog("client_provider_error", {
    provider,
    context,
    code,
    ...(status === undefined ? {} : { status }),
  });
  return json({ ok: true }, 202, origin, env.CORS_ORIGINS);
}

function iceServers(env: Env): Array<Record<string, unknown>> {
  const servers: Array<Record<string, unknown>> = [{ urls: "stun:stun.l.google.com:19302" }];
  if (env.TURN_URL && env.TURN_USERNAME && env.TURN_CREDENTIAL) {
    servers.push({ urls: env.TURN_URL, username: env.TURN_USERNAME, credential: env.TURN_CREDENTIAL });
  }
  return servers;
}

// ── CORS ──────────────────────────────────────────────────────────────

function corsHeaders(origin: string, configuredOrigins = ""): Record<string, string> {
  const allowlist = configuredOrigins.split(",").map((value) => value.trim()).filter(Boolean);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key, X-Snail-Identity, X-Snail-Public-Key, X-Snail-Signature, X-Snail-Timestamp",
    "Access-Control-Max-Age": "86400",
  };
  if (origin && allowlist.includes(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

// ── Auth ──────────────────────────────────────────────────────────────

function isDevMode(env: Env): boolean {
  return env.DEV_MODE === "true";
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function derEcdsaToRaw(der: Uint8Array): Uint8Array | null {
  // Android's SHA256withECDSA returns DER SEQUENCE(INTEGER r, INTEGER s),
  // while WebCrypto ECDSA verification expects the fixed 32+32 byte form.
  if (der.length < 8 || der[0] !== 0x30) return null;
  let offset = 2;
  if (der[1] & 0x80) offset += der[1] & 0x7f;
  if (der[offset++] !== 0x02) return null;
  const rLength = der[offset++];
  const r = der.slice(offset, offset + rLength);
  offset += rLength;
  if (der[offset++] !== 0x02) return null;
  const sLength = der[offset++];
  const s = der.slice(offset, offset + sLength);
  if (r.length > 33 || s.length > 33) return null;
  const raw = new Uint8Array(64);
  raw.set(r.slice(Math.max(0, r.length - 32)), 32 - Math.min(32, r.length));
  raw.set(s.slice(Math.max(0, s.length - 32)), 64 - Math.min(32, s.length));
  return raw;
}

async function verifyDeviceRequest(request: Request, identity: string): Promise<boolean> {
  const publicKey = request.headers.get("X-Snail-Public-Key") || "";
  const signature = request.headers.get("X-Snail-Signature") || "";
  const timestamp = request.headers.get("X-Snail-Timestamp") || "";
  const timestampMs = Number(timestamp);
  if (!publicKey || !signature || !/^\d+$/.test(timestamp) ||
      !Number.isFinite(timestampMs) || Math.abs(Date.now() - timestampMs) > 5 * 60 * 1000) {
    return false;
  }
  const body = request.method === "GET" ? "" : await request.clone().text();
  const payload = `${request.method}\n${new URL(request.url).pathname}\n${body}\n${timestamp}`;
  try {
    const key = await crypto.subtle.importKey(
      "spki", decodeBase64(publicKey), { name: "ECDSA", namedCurve: "P-256" },
      false, ["verify"]);
    const rawSignature = derEcdsaToRaw(decodeBase64(signature));
    if (!rawSignature) return false;
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, key, rawSignature,
      new TextEncoder().encode(payload));
  } catch {
    return false;
  }
}

async function getUserId(request: Request, env: Env): Promise<string | null> {
  const identity = getSnailIdentity(request);
  if (isDevMode(env)) {
    // Dev mode normally uses the configured API key. For local APK testing,
    // an explicit identity-auth flag allows the app's stable QR identity to
    // act as the user id without embedding a secret in the APK.
    if (env.DEV_ALLOW_IDENTITY_AUTH === "true" && identity) return identity;
    const apiKey = request.headers.get("X-API-Key");
    if (env.DEV_API_KEY && apiKey !== env.DEV_API_KEY) return null;
    return apiKey || "dev-user";
  }

  // Clerk remains supported, but a deployment may explicitly choose the
  // device-identity onboarding model instead. This is opt-in so production
  // cannot silently downgrade its authentication policy.
  if (env.DEVICE_ID_AUTH === "true" && identity) {
    const publicKey = request.headers.get("X-Snail-Public-Key")?.trim() || "";
    if (!publicKey || !(await verifyDeviceRequest(request, identity))) return null;

    // Bind the stable Snail identity to the first successfully verified
    // AndroidKeyStore public key. A valid signature alone is insufficient:
    // otherwise anyone who learned the public QR identity could replace the
    // key on every request. KV survives Worker isolates and DO lifetimes.
    const bindingKey = `device-key:${identity}`;
    const boundKey = await env.SNAIL_KV.get(bindingKey);
    if (boundKey && boundKey !== publicKey) return null;
    if (!boundKey) await env.SNAIL_KV.put(bindingKey, publicKey);
    return identity;
  }

  // Prod mode: verify Clerk JWT
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;
  try {
    const { jwtVerify, createRemoteJWKSet } = await import("jose");
    const jwks = createRemoteJWKSet(new URL(env.CLERK_JWKS_URL));
    const { payload } = await jwtVerify(authHeader.slice(7), jwks, {
      issuer: env.CLERK_ISSUER,
    });
    return (payload as any).sub || null;
  } catch {
    return null;
  }
}

// ── Quota ─────────────────────────────────────────────────────────────

async function getQuotaUsed(userId: string, env: Env): Promise<number> {
  const value = await env.SNAIL_KV.get(`quota:${userId}`);
  return value ? parseInt(value, 10) : 0;
}

async function checkQuota(userId: string, env: Env): Promise<{ allowed: boolean; remaining: number }> {
  if (isDevMode(env)) return { allowed: true, remaining: Infinity };
  const used = await getQuotaUsed(userId, env);
  const remaining = FREE_QUOTA_SECONDS - used;
  const allowed = remaining > 0;
  if (!allowed) observabilityLog("quota_exhausted", { tier: "free" });
  return { allowed, remaining };
}

async function checkRoomRateLimit(
  request: Request,
  env: Env,
  action: keyof typeof ROOM_RATE_LIMITS,
): Promise<Response | null> {
  const identity = request.headers.get("X-Snail-Identity")?.trim();
  const ip = request.headers.get("CF-Connecting-IP")?.trim() || "unknown";
  const subject = identity ? `identity:${identity}` : `ip:${ip}`;
  const window = Math.floor(Date.now() / (ROOM_RATE_WINDOW_SECONDS * 1_000));
  const key = `room-rate:${action}:${subject}:${window}`;
  const used = Number(await env.SNAIL_KV.get(key) || "0");
  if (used >= ROOM_RATE_LIMITS[action]) {
    observabilityLog("rate_limit_hit", { action, limit: ROOM_RATE_LIMITS[action] });
    return new Response(JSON.stringify({ error: "Rate limit exceeded" }), {
      status: 429,
      headers: {
        ...corsHeaders(request.headers.get("Origin") || "", env.CORS_ORIGINS),
        "Content-Type": "application/json",
        "Retry-After": String(ROOM_RATE_WINDOW_SECONDS),
      },
    });
  }
  await env.SNAIL_KV.put(key, String(used + 1), { expirationTtl: ROOM_RATE_WINDOW_SECONDS + 5 });
  return null;
}

// ── Room Management ───────────────────────────────────────────────────

function generateRoomId(): string {
  const random = new Uint8Array(ROOM_ID_LENGTH);
  crypto.getRandomValues(random);
  let id = "";
  for (let i = 0; i < ROOM_ID_LENGTH; i++) {
    id += ROOM_ID_ALPHABET[random[i] % ROOM_ID_ALPHABET.length];
  }
  return `snail-${id}`;
}

function getSnailIdentity(request: Request): string | null {
  const value = request.headers.get("X-Snail-Identity")?.trim() || "";
  return /^[a-f0-9-]{16,80}$/i.test(value) ? value : null;
}

// ── Session Token ─────────────────────────────────────────────────────

async function createSessionToken(
  payload: Omit<SessionTokenPayload, "iat" | "exp">,
  env: Env
): Promise<string> {
  const { SignJWT } = await import("jose");
  const secret = new TextEncoder().encode(env.SESSION_SECRET);
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ ...payload } as any)
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt(now)
    .setExpirationTime(now + SESSION_TOKEN_TTL)
    .sign(secret);
}

// ── Handlers ──────────────────────────────────────────────────────────

async function handleCreateRoom(request: Request, env: Env): Promise<Response> {
  const origin = request.headers.get("Origin") || "";
  const userId = await getUserId(request, env);
  if (!userId) {
    observabilityLog("auth_failure", { route: "rooms_create", reason: "missing_or_invalid_token" });
    return json({ error: "Unauthorized" }, 401, origin, env.CORS_ORIGINS);
  }

  let body: any = {};
  try { body = await request.json(); } catch {}

  const tier = isDevMode(env) ? "paid" : "free";
  const quota = await checkQuota(userId, env);
  if (!quota.allowed) {
    observabilityLog("quota_rejected", { route: "rooms_create" });
    return json({ error: "Quota exceeded", remaining: quota.remaining }, 403, origin, env.CORS_ORIGINS);
  }

  const inviteeId = typeof body.inviteeId === "string" && /^[a-f0-9-]{16,80}$/i.test(body.inviteeId.trim())
    ? body.inviteeId.trim()
    : null;
  let roomId = "";
  let doStub: DurableObjectStub | null = null;
  for (let attempt = 0; attempt < MAX_ROOM_ID_ATTEMPTS; attempt++) {
    const candidate = generateRoomId();
    const candidateStub = env.SNAIL_RELAY.get(env.SNAIL_RELAY.idFromName(candidate));
    const status = await candidateStub.fetch(new Request("https://internal/status"));
    if (status.status === 404) {
      roomId = candidate;
      doStub = candidateStub;
      break;
    }
  }
  if (!roomId || !doStub) {
    return json({ error: "Could not allocate a unique room code" }, 503, origin, env.CORS_ORIGINS);
  }
  const sessionToken = await createSessionToken(
    { sub: userId, room: roomId, role: "host", tier: tier as "free" | "paid" },
    env
  );

  // Init DO
  await doStub.fetch(new Request("https://internal/init", {
    method: "POST",
    body: JSON.stringify({
      roomId, hostId: userId,
      inviteeId,
      sourceLang: body.sourceLang || "de",
      targetLang: body.targetLang || "en",
      tier,
      sessionSecret: env.SESSION_SECRET,
    }),
  }));

  const relayHost = new URL(request.url).host;
  return json({
    roomId, sessionToken,
    relayUrl: `wss://${relayHost}/ws?room=${roomId}`,
    iceServers: iceServers(env),
    sourceLang: body.sourceLang || "de",
    targetLang: body.targetLang || "en",
    inviteeId,
    tier, quotaRemaining: quota.remaining,
  }, 201, origin, env.CORS_ORIGINS);
}

async function handleJoinRoom(request: Request, env: Env, roomId: string): Promise<Response> {
  const origin = request.headers.get("Origin") || "";
  const userId = await getUserId(request, env);
  if (!userId) {
    observabilityLog("auth_failure", { route: "rooms_join", reason: "missing_or_invalid_token" });
    return json({ error: "Unauthorized" }, 401, origin, env.CORS_ORIGINS);
  }

  const tier = isDevMode(env) ? "paid" : "free";
  const quota = await checkQuota(userId, env);
  if (!quota.allowed) {
    observabilityLog("quota_rejected", { route: "rooms_join" });
    return json({ error: "Quota exceeded" }, 403, origin, env.CORS_ORIGINS);
  }

  const doId = env.SNAIL_RELAY.idFromName(roomId);
  const doStub = env.SNAIL_RELAY.get(doId);
  const roomCheck = await doStub.fetch(new Request("https://internal/status"));
  if (roomCheck.status !== 200) {
    observabilityLog("room_lookup_failed", { route: "rooms_join", status: roomCheck.status });
    await checkRoomRateLimit(request, env, "failedJoin");
    return json({ error: "Room not found" }, 404, origin, env.CORS_ORIGINS);
  }

  const roomState: any = await roomCheck.json();
  if (roomState.inviteeId && roomState.inviteeId !== getSnailIdentity(request)) {
    await checkRoomRateLimit(request, env, "failedJoin");
    return json({ error: "This session was invited for another Snail identity" }, 403, origin, env.CORS_ORIGINS);
  }
  // Do not use the persisted `guestId` as a capacity lock here. It is
  // intentionally durable metadata and can outlive a dropped WebSocket;
  // treating it as liveness makes a room permanently report "Room is full".
  // The Durable Object owns the authoritative, race-safe admission check when
  // the guest WebSocket authenticates (`guestSocket`).

  const sessionToken = await createSessionToken(
    { sub: userId, room: roomId, role: "guest", tier: tier as "free" | "paid" },
    env
  );

  const relayHost = new URL(request.url).host;
  return json({
    roomId, sessionToken,
    relayUrl: `wss://${relayHost}/ws?room=${roomId}`,
    iceServers: iceServers(env),
    // The guest hears the host's language translated into the guest-side
    // direction, so the room's negotiated pair is mirrored for this client.
    sourceLang: roomState.targetLang,
    targetLang: roomState.sourceLang,
    inviteeId: roomState.inviteeId || null,
    tier, quotaRemaining: quota.remaining,
  }, 200, origin, env.CORS_ORIGINS);
}

async function handleQuota(request: Request, env: Env): Promise<Response> {
  const origin = request.headers.get("Origin") || "";
  const userId = await getUserId(request, env);
  if (!userId) {
    observabilityLog("auth_failure", { route: "quota", reason: "missing_or_invalid_token" });
    return json({ error: "Unauthorized" }, 401, origin, env.CORS_ORIGINS);
  }

  const tier = isDevMode(env) ? "paid" : "free";
  const used = await getQuotaUsed(userId, env);
  const remaining = tier === "paid" ? Infinity : FREE_QUOTA_SECONDS - used;

  return json({
    userId, tier, usedSeconds: used,
    remainingSeconds: remaining,
    totalSeconds: tier === "paid" ? Infinity : FREE_QUOTA_SECONDS,
  }, 200, origin, env.CORS_ORIGINS);
}

/**
 * Mint a short-lived OpenAI Realtime Translation client secret.
 *
 * This is deliberately separate from BYOK: a user-provided key is never sent
 * to this Worker. The endpoint is only available when the deployment owns a
 * server-side OPENAI_API_KEY.
 */
async function handleRealtimeClientSecret(request: Request, env: Env): Promise<Response> {
  const origin = request.headers.get("Origin") || "";
  const userId = await getUserId(request, env);
  if (!userId) {
    observabilityLog("auth_failure", { route: "realtime_client_secret", reason: "missing_or_invalid_token" });
    return json({ error: "Unauthorized" }, 401, origin, env.CORS_ORIGINS);
  }
  if (!env.OPENAI_API_KEY) {
    observabilityLog("provider_unavailable", { provider: "openai_realtime", reason: "missing_server_key" });
    return json({ error: "Realtime client secrets are not configured" }, 503, origin, env.CORS_ORIGINS);
  }
  const window = Math.floor(Date.now() / (REALTIME_SECRET_WINDOW_SECONDS * 1_000));
  const rateKey = `realtime-secret:${userId}:${window}`;
  const issued = Number(await env.SNAIL_KV.get(rateKey) || "0");
  if (issued >= REALTIME_SECRET_LIMIT) {
    observabilityLog("rate_limit_hit", { action: "realtime_client_secret", limit: REALTIME_SECRET_LIMIT });
    return json({ error: "Realtime secret rate limit exceeded" }, 429, origin, env.CORS_ORIGINS);
  }
  await env.SNAIL_KV.put(rateKey, String(issued + 1), { expirationTtl: REALTIME_SECRET_WINDOW_SECONDS + 5 });

  let body: any = {};
  try { body = await request.json(); } catch {}
  const targetLanguage = typeof body.targetLanguage === "string" ? body.targetLanguage.trim().toLowerCase() : "en";
  if (!/^[a-z]{2,3}(?:-[A-Z]{2})?$/.test(targetLanguage)) {
    return json({ error: "Invalid targetLanguage" }, 400, origin, env.CORS_ORIGINS);
  }

  const upstream = await fetch("https://api.openai.com/v1/realtime/translations/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
      "OpenAI-Safety-Identifier": userId,
    },
    body: JSON.stringify({
      session: {
        model: "gpt-realtime-translate",
        audio: { output: { language: targetLanguage } },
      },
    }),
  });

  const responseBody = await upstream.text();
  observabilityLog(
    upstream.ok ? "provider_request_ok" : "provider_request_failed",
    { provider: "openai_realtime", status: upstream.status },
  );
  return new Response(responseBody, {
    status: upstream.status,
    headers: { ...corsHeaders(origin, env.CORS_ORIGINS), "Content-Type": upstream.headers.get("Content-Type") || "application/json" },
  });
}

async function handleAppShareCreate(request: Request, env: Env, token: string): Promise<Response> {
  const userId = await getUserId(request, env);
  if (!userId || !/^[a-f0-9]{48}$/.test(token)) return new Response('Unauthorized', { status: 401 });
  let body: any; try { body = await request.json(); } catch { return new Response('Invalid share metadata', { status: 400 }); }
  const bytes = Number(body.bytes);
  if (!Number.isFinite(bytes) || bytes <= 0 || bytes > 1024 * 1024 * 1024) return new Response('Invalid APK size', { status: 400 });
  const expiresAt = Date.now() + APP_SHARE_TTL * 1000;
  const relay = env.SNAIL_APP_SHARE_RELAY.get(env.SNAIL_APP_SHARE_RELAY.idFromName(`app-share:${token}`));
  await relay.fetch(new Request('https://internal/init', { method: 'POST', body: JSON.stringify({ version: String(body.version || 'Snail'), bytes, expiresAt }) }));
  return json({ url: `${new URL(request.url).origin}/download/${token}`, expiresAt }, 201, request.headers.get('Origin') || '', env.CORS_ORIGINS);
}

function appShareDownloadPage(token: string): Response {
  const safe = JSON.stringify(token);
  const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Snail herunterladen</title><style>body{margin:0;background:#0c102c;color:#f8f6ff;font:16px system-ui;display:grid;min-height:100vh;place-items:center}.card{max-width:420px;text-align:center;padding:32px}progress{width:100%;height:16px}small{color:#9de8cb}</style><main class="card"><h1>Snail wird übertragen</h1><p id="state">Verbinde mit dem Gerät, das die App teilt …</p><progress id="bar" value="0" max="100"></progress><p id="detail"></p><small>Die APK wird direkt vom anderen Gerät übertragen und nicht bei Cloudflare gespeichert.</small></main><script>const token=${safe},state=document.querySelector('#state'),bar=document.querySelector('#bar'),detail=document.querySelector('#detail'),chunks=[];let total=0,received=0;const ws=new WebSocket((location.protocol==='https:'?'wss:':'ws:')+'//'+location.host+'/app-share?token='+token+'&role=guest');ws.binaryType='arraybuffer';ws.onopen=()=>ws.send(JSON.stringify({type:'guest_ready'}));ws.onmessage=e=>{if(typeof e.data!=='string'){chunks.push(e.data);received+=e.data.byteLength;bar.value=total?received/total*100:0;detail.textContent=(received/1048576).toFixed(1)+' MB von '+(total/1048576).toFixed(1)+' MB';return}const m=JSON.parse(e.data);if(m.bytes){total=m.bytes;bar.max=100}if(m.type==='host_ready')state.textContent='Gerät verbunden — Übertragung startet …';if(m.type==='transfer_start')state.textContent='Download läuft …';if(m.type==='transfer_complete'){state.textContent='Fertig. Download startet …';const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(chunks,{type:'application/vnd.android.package-archive'}));a.download='snail.apk';a.click();}if(m.type==='host_disconnected'||m.type==='transfer_error')state.textContent='Übertragung unterbrochen. Bitte Link erneut öffnen.'};</script>`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
}

// ── Helpers ───────────────────────────────────────────────────────────

function json(data: any, status: number, origin: string, configuredOrigins = ""): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders(origin, configuredOrigins), "Content-Type": "application/json" },
  });
}

// ── Main Handler ──────────────────────────────────────────────────────

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const origin = request.headers.get("Origin") || "";

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(origin, env.CORS_ORIGINS) });
    }

    const appShareMatch = url.pathname.match(/^\/app-share$/);
    if (appShareMatch && request.headers.get('Upgrade') === 'websocket') {
      const token = url.searchParams.get('token') || '';
      if (!/^[a-f0-9]{48}$/i.test(token)) return new Response('Not found', { status: 404 });
      return env.SNAIL_APP_SHARE_RELAY.get(env.SNAIL_APP_SHARE_RELAY.idFromName(`app-share:${token.toLowerCase()}`)).fetch(request);
    }

    // WebSocket upgrade → Durable Object
    if (request.headers.get("Upgrade") === "websocket") {
      const roomId = url.searchParams.get("room");
      if (!roomId) return new Response("Missing room", { status: 400 });
      const limited = await checkRoomRateLimit(request, env, "websocket");
      if (limited) return limited;
      const doId = env.SNAIL_RELAY.idFromName(roomId);
      const doStub = env.SNAIL_RELAY.get(doId);
      // Ensure DO has the session secret before handling WebSocket
      await doStub.fetch(new Request("https://internal/init-secret", {
        method: "POST",
        body: JSON.stringify({ sessionSecret: env.SESSION_SECRET }),
      }));
      // Never forward the client request wholesale: in particular, a client
      // must not be able to provide a replacement X-Session-Secret header.
      // The DO receives only headers needed for the WebSocket upgrade and
      // device-request authentication.
      const upgradeHeaders = new Headers();
      for (const name of [
        "Upgrade", "Connection", "Sec-WebSocket-Key", "Sec-WebSocket-Version",
        "Sec-WebSocket-Protocol", "Origin", "X-Snail-Identity",
        "X-Snail-Public-Key", "X-Snail-Signature", "X-Snail-Timestamp",
      ]) {
        const value = request.headers.get(name);
        if (value) upgradeHeaders.set(name, value);
      }
      return doStub.fetch(new Request(request.url, {
        method: request.method,
        headers: upgradeHeaders,
      }));
    }

    const path = url.pathname;

    const appUpload = path.match(/^\/api\/app-share\/([a-f0-9]{48})$/i);
    if (appUpload && request.method === 'POST') return handleAppShareCreate(request, env, appUpload[1].toLowerCase());
    const appDownload = path.match(/^\/download\/([a-f0-9]{48})$/i);
    if (appDownload && request.method === 'GET') return appShareDownloadPage(appDownload[1].toLowerCase());

    // Health
    if (path === "/api/health") {
      const configured = {
        sessionSecret: Boolean(env.SESSION_SECRET),
        clerk: Boolean(env.CLERK_JWKS_URL && env.CLERK_ISSUER),
        deviceIdentity: env.DEVICE_ID_AUTH === "true",
        openAiRealtime: Boolean(env.OPENAI_API_KEY),
        turn: Boolean(env.TURN_URL && env.TURN_USERNAME && env.TURN_CREDENTIAL),
      };
      const ready = isDevMode(env)
        ? configured.sessionSecret
        : configured.sessionSecret && (configured.clerk || configured.deviceIdentity);
      return json({
        status: ready ? "ok" : "degraded",
        devMode: isDevMode(env),
        configured,
  }, ready ? 200 : 503, origin, env.CORS_ORIGINS);
    }

    // Create room
    if (path === "/api/rooms" && request.method === "POST") {
      const limited = await checkRoomRateLimit(request, env, "create");
      if (limited) return limited;
      return handleCreateRoom(request, env);
    }

    // Join room
    const joinMatch = path.match(/^\/api\/rooms\/(.+)\/join$/);
    if (joinMatch && request.method === "POST") {
      const limited = await checkRoomRateLimit(request, env, "join");
      if (limited) return limited;
      return handleJoinRoom(request, env, joinMatch[1]);
    }

    // Quota
    if (path === "/api/quota" && request.method === "GET") {
      return handleQuota(request, env);
    }

    // Opt-in, content-free client diagnostics. The payload is deliberately
    // limited to bounded provider context and an error code.
    if (path === "/api/telemetry" && request.method === "POST") {
      return handleTelemetry(request, env);
    }

    // Short-lived OpenAI Realtime Translation secret (platform-owned key).
    if (path === "/api/realtime/client-secret" && request.method === "POST") {
      return handleRealtimeClientSecret(request, env);
    }

    return json({ error: "Not found" }, 404, origin, env.CORS_ORIGINS);
  },
};
