import { describe, expect, it } from "vitest";
import {
  validateSessionTokenForRoom,
  type SessionTokenPayload,
} from "../../durable-object/src/auth";

const token = (overrides: Partial<SessionTokenPayload> = {}): SessionTokenPayload => ({
  sub: "device-a",
  room: "room-a",
  role: "host",
  tier: "free",
  iat: 1,
  exp: 2,
  ...overrides,
});

describe("Durable Object session-token admission", () => {
  it("accepts a token for the current room and valid role", () => {
    expect(() => validateSessionTokenForRoom(token(), "room-a")).not.toThrow();
  });

  it("rejects a signed token minted for another room", () => {
    expect(() => validateSessionTokenForRoom(token(), "room-b")).toThrow(
      "Token room mismatch",
    );
  });

  it("rejects roles outside the two-party protocol", () => {
    expect(() =>
      validateSessionTokenForRoom(token({ role: "admin" as never }), "room-a"),
    ).toThrow("Invalid token role");
  });
});
