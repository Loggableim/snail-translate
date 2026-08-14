import { describe, expect, it } from "vitest";
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
    ...overrides,
  };
}

async function call(path: string, init: RequestInit = {}, bindings: Partial<Env> = {}) {
  return worker.fetch(new Request(`https://snail.test${path}`, init), env(bindings));
}

describe("Worker fetch handler", () => {
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
    });
    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("https://snail.app");
    expect(response.headers.get("Access-Control-Allow-Headers")).toContain("X-Snail-Identity");
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
    });
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

  it("reports an unavailable realtime secret through the real route", async () => {
    const response = await call("/api/realtime/client-secret", {
      method: "POST",
      headers: { "X-API-Key": "test-api-key", "Content-Type": "application/json" },
      body: JSON.stringify({ targetLanguage: "en" }),
    });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "Realtime client secrets are not configured" });
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
});
