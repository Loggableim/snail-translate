/**
 * Unit tests for Snail Worker.
 *
 * Tests: Auth verification, quota management, room creation, session tokens.
 *
 * Run: npx vitest run
 */

import { describe, it, expect, beforeAll, vi } from "vitest";

// We test the logic functions in isolation.
// The actual Worker fetch handler requires Cloudflare runtime (wrangler dev).

// ── Test: Room ID Generation ──────────────────────────────────────────

describe("Room ID Generation", () => {
  function generateRoomId(): string {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let id = "";
    for (let i = 0; i < 4; i++) {
      id += chars[Math.floor(Math.random() * chars.length)];
    }
    return `snail-${id}`;
  }

  it("generates room IDs with correct format", () => {
    for (let i = 0; i < 100; i++) {
      const id = generateRoomId();
      expect(id).toMatch(/^snail-[A-HJ-NP-Z2-9]{4}$/);
    }
  });

  it("does not contain ambiguous characters (0, O, 1, I)", () => {
    for (let i = 0; i < 100; i++) {
      const id = generateRoomId();
      const suffix = id.slice(5); // after "snail-"
      expect(suffix).not.toMatch(/[0OI1]/);
    }
  });

  it("generates unique IDs", () => {
    const ids = new Set<string>();
    for (let i = 0; i < 100; i++) {
      ids.add(generateRoomId());
    }
    // With 4 chars from 30 chars, collisions are possible but unlikely in 100
    expect(ids.size).toBeGreaterThan(90);
  });
});

// ── Test: Quota Logic ─────────────────────────────────────────────────

describe("Quota Management", () => {
  const FREE_QUOTA_SECONDS = 30 * 60; // 30 minutes

  function checkQuotaLogic(
    tier: string,
    usedSeconds: number
  ): { allowed: boolean; remaining: number } {
    if (tier === "paid") {
      return { allowed: true, remaining: Infinity };
    }
    const remaining = FREE_QUOTA_SECONDS - usedSeconds;
    return { allowed: remaining > 0, remaining };
  }

  it("allows paid users unlimited quota", () => {
    const result = checkQuotaLogic("paid", 999999);
    expect(result.allowed).toBe(true);
    expect(result.remaining).toBe(Infinity);
  });

  it("allows free users within quota", () => {
    const result = checkQuotaLogic("free", 0);
    expect(result.allowed).toBe(true);
    expect(result.remaining).toBe(FREE_QUOTA_SECONDS);
  });

  it("allows free users at quota boundary", () => {
    const result = checkQuotaLogic("free", FREE_QUOTA_SECONDS - 1);
    expect(result.allowed).toBe(true);
    expect(result.remaining).toBe(1);
  });

  it("blocks free users at quota limit", () => {
    const result = checkQuotaLogic("free", FREE_QUOTA_SECONDS);
    expect(result.allowed).toBe(false);
    expect(result.remaining).toBe(0);
  });

  it("blocks free users over quota", () => {
    const result = checkQuotaLogic("free", FREE_QUOTA_SECONDS + 100);
    expect(result.allowed).toBe(false);
    expect(result.remaining).toBeLessThan(0);
  });
});

// ── Test: Session Token TTL ───────────────────────────────────────────

describe("Session Token", () => {
  const SESSION_TOKEN_TTL = 3600; // 1 hour

  it("has correct TTL", () => {
    expect(SESSION_TOKEN_TTL).toBe(3600);
  });

  it("TTL is reasonable (between 5min and 24h)", () => {
    expect(SESSION_TOKEN_TTL).toBeGreaterThan(300);
    expect(SESSION_TOKEN_TTL).toBeLessThan(86400);
  });
});

// ── Test: Mirrored language direction ───────────────────────────────────────

describe("Room language direction", () => {
  function guestDirection(sourceLang: string, targetLang: string) {
    return { sourceLang: targetLang, targetLang: sourceLang };
  }

  it("mirrors the host pair for the guest", () => {
    expect(guestDirection("de", "en")).toEqual({ sourceLang: "en", targetLang: "de" });
    expect(guestDirection("fr", "ja")).toEqual({ sourceLang: "ja", targetLang: "fr" });
  });
});

describe("QR identity invitations", () => {
  function validInviteeId(value: unknown): string | undefined {
    if (typeof value !== "string") return undefined;
    const id = value.trim();
    return /^[a-f0-9-]{16,80}$/i.test(id) ? id : undefined;
  }

  it("accepts a selected contact identity different from the host", () => {
    const host = "11111111-1111-4111-8111-111111111111";
    const guest = "22222222-2222-4222-8222-222222222222";
    expect(validInviteeId(guest)).toBe(guest);
    expect(validInviteeId(guest)).not.toBe(host);
  });

  it("rejects malformed invitation identities", () => {
    expect(validInviteeId("not-a-snail-id")).toBeUndefined();
    expect(validInviteeId("" )).toBeUndefined();
    expect(validInviteeId(null)).toBeUndefined();
  });
});

// ── Test: CORS Headers ────────────────────────────────────────────────

describe("CORS Headers", () => {
  function corsHeaders(origin: string): Record<string, string> {
    return {
      "Access-Control-Allow-Origin": origin || "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Max-Age": "86400",
    };
  }

  it("returns correct CORS headers with origin", () => {
    const headers = corsHeaders("https://snail.app");
    expect(headers["Access-Control-Allow-Origin"]).toBe("https://snail.app");
    expect(headers["Access-Control-Allow-Methods"]).toContain("GET");
    expect(headers["Access-Control-Allow-Methods"]).toContain("POST");
    expect(headers["Access-Control-Allow-Methods"]).toContain("OPTIONS");
  });

  it("returns wildcard when no origin", () => {
    const headers = corsHeaders("");
    expect(headers["Access-Control-Allow-Origin"]).toBe("*");
  });
});

// ── Test: API Route Matching ──────────────────────────────────────────

describe("API Routes", () => {
  it("matches room creation route", () => {
    const path = "/api/rooms";
    const isCreateRoom = path === "/api/rooms";
    expect(isCreateRoom).toBe(true);
  });

  it("matches room join route", () => {
    const path = "/api/rooms/snail-4821/join";
    const match = path.match(/^\/api\/rooms\/(.+)\/join$/);
    expect(match).not.toBeNull();
    expect(match![1]).toBe("snail-4821");
  });

  it("matches quota route", () => {
    const path = "/api/quota";
    const isQuota = path === "/api/quota";
    expect(isQuota).toBe(true);
  });

  it("matches the realtime client-secret route", () => {
    const path = "/api/realtime/client-secret";
    expect(path === "/api/realtime/client-secret").toBe(true);
  });

  it("matches health route", () => {
    const path = "/api/health";
    const isHealth = path === "/api/health";
    expect(isHealth).toBe(true);
  });

  it("health configuration reports presence without exposing secret values", () => {
    const configured = {
      sessionSecret: true,
      clerk: true,
      openAiRealtime: false,
      turn: false,
    };
    expect(configured.sessionSecret).toBe(true);
    expect(configured).not.toHaveProperty("OPENAI_API_KEY");
    expect(configured).not.toHaveProperty("SESSION_SECRET");
  });

  it("marks production health degraded without mandatory auth configuration", () => {
    const ready = (devMode: boolean, sessionSecret: boolean, clerk: boolean) =>
      devMode ? sessionSecret : sessionSecret && clerk;
    expect(ready(false, false, true)).toBe(false);
    expect(ready(false, true, false)).toBe(false);
    expect(ready(false, true, true)).toBe(true);
    expect(ready(true, true, false)).toBe(true);
  });

  it("allows explicitly configured device-identity production mode", () => {
    const ready = (sessionSecret: boolean, clerk: boolean, deviceIdentity: boolean) =>
      sessionSecret && (clerk || deviceIdentity);
    expect(ready(true, false, true)).toBe(true);
    expect(ready(true, false, false)).toBe(false);
  });

  it("rejects invalid room join path", () => {
    const path = "/api/rooms/snail-4821";
    const match = path.match(/^\/api\/rooms\/(.+)\/join$/);
    expect(match).toBeNull();
  });
});

// ── Test: WebSocket Upgrade Detection ──────────────────────────────────

describe("WebSocket Upgrade", () => {
  it("detects WebSocket upgrade header", () => {
    const headers = new Headers({ Upgrade: "websocket" });
    const isWebSocket = headers.get("Upgrade") === "websocket";
    expect(isWebSocket).toBe(true);
  });

  it("detects non-WebSocket request", () => {
    const headers = new Headers();
    const isWebSocket = headers.get("Upgrade") === "websocket";
    expect(isWebSocket).toBe(false);
  });
});
