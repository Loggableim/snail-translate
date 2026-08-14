import { describe, expect, it } from "vitest";
import { SignJWT } from "jose";
import { validateSessionTokenForRoom, verifySessionToken, type SessionTokenPayload } from "./auth";

const secret = "durable-object-test-secret";

async function token(overrides: Partial<SessionTokenPayload> = {}, signingSecret = secret) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    sub: "user-1", room: "snail-ABCD", role: "host", tier: "free",
    iat: now, exp: now + 3600, ...overrides,
  }).setProtectedHeader({ alg: "HS256" }).sign(new TextEncoder().encode(signingSecret));
}

describe("Durable Object session authentication", () => {
  it("accepts a valid token for the room", async () => {
    const payload = await verifySessionToken(await token(), secret);
    expect(() => validateSessionTokenForRoom(payload, "snail-ABCD")).not.toThrow();
  });

  it("rejects a token for another room", async () => {
    const payload = await verifySessionToken(await token(), secret);
    expect(() => validateSessionTokenForRoom(payload, "snail-WXYZ")).toThrow("Token room mismatch");
  });

  it("rejects an invalid role", async () => {
    const payload = await verifySessionToken(await token({ role: "operator" as SessionTokenPayload["role"] }), secret);
    expect(() => validateSessionTokenForRoom(payload, "snail-ABCD")).toThrow("Invalid token role");
  });

  it("rejects a missing subject", async () => {
    const payload = await verifySessionToken(await token({ sub: "" }), secret);
    expect(() => validateSessionTokenForRoom(payload, "snail-ABCD")).toThrow("Missing token subject");
  });

  it("rejects an expired token", async () => {
    await expect(verifySessionToken(await token({ exp: Math.floor(Date.now() / 1000) - 1 }), secret))
      .rejects.toThrow();
  });

  it("rejects a token signed with a foreign secret", async () => {
    await expect(verifySessionToken(await token({}, "foreign-secret"), secret)).rejects.toThrow();
  });
});
