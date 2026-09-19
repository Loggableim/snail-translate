import { afterEach, describe, expect, it, vi } from "vitest";
import worker, { type Env } from "./index";

type Fetcher = { fetch(request: Request): Promise<Response> };

function kv(values: Record<string, string> = {}): KVNamespace {
  return {
    get: async (key: string) => values[key] ?? null,
    put: async (key: string, value: string) => { values[key] = value; },
    delete: async (key: string) => { delete values[key]; },
    list: async () => ({ keys: [] }),
    getWithMetadata: async () => ({ value: null, metadata: null }),
  } as unknown as KVNamespace;
}

function namespace(response: Response = new Response("{}", { status: 200 })): DurableObjectNamespace {
  const fetcher: Fetcher = { fetch: async () => response };
  return {
    idFromName: (name: string) => ({ toString: () => name } as DurableObjectId),
    get: () => fetcher,
    newUniqueId: () => ({} as DurableObjectId),
    getByName: () => fetcher,
  } as unknown as DurableObjectNamespace;
}

function recordingNamespace() {
  const requests: Request[] = [];
  const fetcher: Fetcher = {
    fetch: async (request) => {
      requests.push(request);
      // Room allocation probes /status and expects 404 for a free code; the
      // /init call that follows must succeed.
      if (new URL(request.url).pathname === "/status") {
        return new Response("Not found", { status: 404 });
      }
      return new Response("{}", { status: 200 });
    },
  };
  const binding = {
    idFromName: (name: string) => ({ toString: () => name } as DurableObjectId),
    get: () => fetcher,
    newUniqueId: () => ({} as DurableObjectId),
    getByName: () => fetcher,
  } as unknown as DurableObjectNamespace;
  return { binding, requests };
}

function env(overrides: Partial<Env> = {}): Env {
  return {
    SNAIL_KV: kv(),
    SNAIL_RELAY: namespace(),
    SNAIL_APP_SHARE_RELAY: namespace(),
    CLERK_JWKS_URL: "",
    CLERK_ISSUER: "",
    GROQ_API_KEY: "",
    DEEPGRAM_API_KEY: "",
    FISHAUDIO_API_KEY: "",
    SESSION_SECRET: "test-session-secret",
    DEV_MODE: "true",
    DEV_API_KEY: "test-api-key",
    CORS_ORIGINS: "https://snail.app",
    ...overrides,
  };
}

async function call(path: string, init: RequestInit = {}, bindings: Partial<Env> = {}) {
  return worker.fetch(new Request(`https://snail.test${path}`, init), env(bindings));
}

describe("Worker fetch handler", () => {
  afterEach(() => { vi.unstubAllGlobals(); });

  it("reports a configured development health state", async () => {
    const response = await call("/api/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "ok", devMode: true });
  });

  it("reports degraded health when production auth is incomplete", async () => {
    const response = await call("/api/health", {}, { DEV_MODE: "false" });
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ status: "degraded", devMode: false });
  });

  it("handles CORS preflight with the production header set", async () => {
    const response = await call("/api/rooms", {
      method: "OPTIONS",
      headers: { Origin: "https://snail.app" },
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("https://snail.app");
    expect(response.headers.get("Access-Control-Allow-Headers")).toContain("X-Snail-Identity");
  });

  it("omits CORS access for an origin outside the configured allowlist", async () => {
    const response = await call("/api/rooms", {
      method: "OPTIONS",
      headers: { Origin: "https://evil.example" },
    });
    expect(response.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });

  it("rejects protected routes without development credentials", async () => {
    const response = await call("/api/quota", { method: "GET" }, { DEV_API_KEY: "configured-key" });
    expect(response.status).toBe(401);
  });

  it("serves quota through the real handler for an authenticated development user", async () => {
    const response = await call("/api/quota", {
      method: "GET",
      headers: { "X-API-Key": "test-api-key" },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ tier: "paid", remainingSeconds: null });
  });

  it("validates room creation through the real handler", async () => {
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-api-key" },
      body: JSON.stringify({ sourceLang: "de", targetLang: "en", inviteeId: "not-an-identity" }),
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(response.status).toBe(201);
    const body = await response.json() as { roomId: string };
    expect(body).toMatchObject({
      sourceLang: "de", targetLang: "en", inviteeId: null,
    });
    expect(body.roomId).toMatch(/^snail-[A-HJ-NP-Z2-9]{8}$/);
  });

  it("rejects an unknown room through the real join route", async () => {
    const response = await call("/api/rooms/snail-ABCD/join", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, {
      SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })),
    });
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Room not found" });
  });

  it("fails safely when every generated room code is already initialized", async () => {
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
      body: "{}",
    }, { SNAIL_RELAY: namespace(new Response("{}", { status: 200 })) });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Could not allocate a unique room code" });
  });

  it("creates a guide room with listener languages and forwards the mode to the relay", async () => {
    const { binding, requests } = recordingNamespace();
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-api-key" },
      body: JSON.stringify({ mode: "guide", sourceLang: "de", listenerLanguages: ["en", "fr"] }),
    }, { SNAIL_RELAY: binding });
    expect(response.status).toBe(201);
    const body = await response.json() as { mode: string; listenerLanguages: string[] };
    expect(body.mode).toBe("guide");
    expect(body.listenerLanguages).toEqual(["en", "fr"]);

    const initRequest = requests.find((request) => new URL(request.url).pathname === "/init");
    expect(initRequest).toBeDefined();
    const initBody = JSON.parse(await initRequest!.text());
    expect(initBody.mode).toBe("guide");
    expect(initBody.listenerLanguages).toEqual(["en", "fr"]);
  });

  it("defaults to duo mode when no mode is requested", async () => {
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-api-key" },
      body: JSON.stringify({ sourceLang: "de", targetLang: "en" }),
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ mode: "duo" });
  });

  it("rejects a guide room with an unsupported listener language", async () => {
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-api-key" },
      body: JSON.stringify({ mode: "guide", listenerLanguages: ["en", "xx"] }),
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "Invalid listener languages" });
  });

  it("rejects a guide room without any listener language", async () => {
    const response = await call("/api/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-api-key" },
      body: JSON.stringify({ mode: "guide", listenerLanguages: [] }),
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(response.status).toBe(400);
  });

  it("mints a listener token for a guide room without consuming quota", async () => {
    const guideStatus = new Response(JSON.stringify({
      mode: "guide",
      sourceLang: "de",
      listenerLanguages: ["en", "fr"],
    }), { status: 200 });
    const response = await call("/api/rooms/snail-GUIDE1/listen", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, { SNAIL_RELAY: namespace(guideStatus) });
    expect(response.status).toBe(200);
    const body = await response.json() as { sessionToken: string; listenerLanguages: string[]; sourceLang: string };
    expect(body.sourceLang).toBe("de");
    expect(body.listenerLanguages).toEqual(["en", "fr"]);
    // The JWT carries the listener role — the relay admits on that basis.
    const payload = JSON.parse(atob(body.sessionToken.split(".")[1]));
    expect(payload.role).toBe("listener");
  });

  it("rejects listening on a duo room and on an unknown room", async () => {
    const duoStatus = new Response(JSON.stringify({ mode: "duo" }), { status: 200 });
    const onDuo = await call("/api/rooms/snail-DUO123/listen", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, { SNAIL_RELAY: namespace(duoStatus) });
    expect(onDuo.status).toBe(409);
    expect(await onDuo.json()).toEqual({ error: "Not a listening room" });

    const unknown = await call("/api/rooms/snail-NONE12/listen", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, { SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })) });
    expect(unknown.status).toBe(404);
  });

  it("rejects a guest join on a guide room with the listener fallback code", async () => {
    const guideStatus = new Response(JSON.stringify({
      mode: "guide",
      sourceLang: "de",
      targetLang: "en",
    }), { status: 200 });
    const response = await call("/api/rooms/snail-GUIDE1/join", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, { SNAIL_RELAY: namespace(guideStatus) });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "This is a listening room",
      code: "guide_room_use_listen",
    });
  });

  it("rate-limits repeated room joins and advertises the retry window", async () => {
    const sharedKv = kv();
    const bindings = {
      SNAIL_KV: sharedKv,
      SNAIL_RELAY: namespace(new Response("Not found", { status: 404 })),
    };
    for (let i = 0; i < 20; i++) {
      const response = await call("/api/rooms/ABCD2345/join", {
        method: "POST",
        headers: { "X-API-Key": "test-api-key" },
      }, bindings);
      expect(response.status).toBe(404);
    }
    const response = await call("/api/rooms/ABCD2345/join", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key" },
    }, bindings);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("60");
  });

  it("reports an unavailable realtime secret through the real route", async () => {
    const response = await call("/api/realtime/client-secret", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key", "Content-Type": "application/json" },
      body: JSON.stringify({ targetLanguage: "en" }),
    });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Realtime client secrets are not configured" });
  });

  it("rate-limits realtime secret issuance per authenticated user", async () => {
    vi.stubGlobal("fetch", async () => new Response(JSON.stringify({ value: "short-lived" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }));
    const bindings = { OPENAI_API_KEY: "configured", SNAIL_KV: kv() };
    for (let i = 0; i < 10; i++) {
      const response = await call("/api/realtime/client-secret", {
        method: "POST",
        headers: { "X-API-Key": "test-api-key", "Content-Type": "application/json" },
        body: JSON.stringify({ targetLanguage: "en" }),
      }, bindings);
      expect(response.status).toBe(200);
    }
    const response = await call("/api/realtime/client-secret", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key", "Content-Type": "application/json" },
      body: JSON.stringify({ targetLanguage: "en" }),
    }, bindings);
    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({ error: "Realtime secret rate limit exceeded" });
  });

  it("rejects a WebSocket upgrade without a room through the real handler", async () => {
    const response = await call("/ws", { headers: { Upgrade: "websocket" } });
    expect(response.status).toBe(400);
    expect(await response.text()).toBe("Missing room");
  });

  it("does not forward a client-provided relay secret to the Durable Object", async () => {
    const relay = recordingNamespace();
    const response = await call("/ws?room=snail-ABCD", {
      headers: {
        Upgrade: "websocket",
        Connection: "Upgrade",
        "Sec-WebSocket-Key": "dGVzdA==",
        "Sec-WebSocket-Version": "13",
        "X-Session-Secret": "attacker-secret",
      },
    }, { SNAIL_RELAY: relay.binding });

    expect(response.status).toBe(200);
    expect(relay.requests).toHaveLength(2);
    expect(await relay.requests[0].clone().json()).toEqual({ sessionSecret: "test-session-secret" });
    expect(relay.requests[1].headers.get("X-Session-Secret")).toBeNull();
  });

  it("returns the handler's 404 fallback", async () => {
    const response = await call("/api/does-not-exist");
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "Not found" });
  });

  it("accepts bounded content-free client telemetry", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const response = await call("/api/telemetry", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "198.51.100.4" },
      body: JSON.stringify({
        provider: "openai",
        context: "realtime.connect",
        code: "provider_unavailable",
        status: 503,
        text: "must never reach logs",
      }),
    });
    expect(response.status).toBe(202);
    const payload = log.mock.calls
      .map((call) => String(call[0]))
      .find((value) => value.includes('"event":"client_provider_error"'));
    expect(payload).toBeDefined();
    expect(payload).toContain("client_provider_error");
    expect(payload).toContain("provider_unavailable");
    expect(payload).not.toContain("must never reach logs");
  });

  it("rate-limits client telemetry per source window", async () => {
    const values: Record<string, string> = {};
    const bindings = { SNAIL_KV: kv(values) };
    const init = {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "198.51.100.5" },
      body: JSON.stringify({ provider: "fish", context: "tts", code: "failed" }),
    };
    for (let index = 0; index < 30; index++) {
      expect((await call("/api/telemetry", init, bindings)).status).toBe(202);
    }
    expect((await call("/api/telemetry", init, bindings)).status).toBe(429);
  });

  it("discards free-form telemetry labels", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const response = await call("/api/telemetry", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "198.51.100.6" },
      body: JSON.stringify({
        provider: "fish audio secret text",
        context: "provider.error\nconversation body",
        code: "AIzaSyA12345678901234567890123456789012",
      }),
    });
    expect(response.status).toBe(202);
    const payload = log.mock.calls
      .map((call) => String(call[0]))
      .find((value) => value.includes('"event":"client_provider_error"'));
    expect(payload).toBeDefined();
    expect(payload).not.toContain("secret text");
    expect(payload).not.toContain("conversation body");
    expect(payload).not.toContain("AIzaSyA12345678901234567890123456789012");
    expect(payload).toContain('"provider":"unknown"');
    expect(payload).toContain('"context":"unknown"');
    expect(payload).toContain('"code":"unknown"');
  });
});
