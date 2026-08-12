/**
 * Session token verification for Durable Object.
 * Verifies HS256 JWT tokens issued by the Worker.
 * Secret is passed from DO state (set during /init).
 */

import { jwtVerify } from "jose";

export interface SessionTokenPayload {
  sub: string;
  room: string;
  role: "host" | "guest";
  tier: "free" | "paid";
  exp: number;
  iat: number;
}

/** Bind a signed token to this room before admitting its WebSocket. */
export function validateSessionTokenForRoom(
  payload: SessionTokenPayload,
  roomId: string,
): void {
  if (payload.room !== roomId) throw new Error("Token room mismatch");
  if (payload.role !== "host" && payload.role !== "guest") {
    throw new Error("Invalid token role");
  }
  if (!payload.sub) throw new Error("Missing token subject");
}

export async function verifySessionToken(
  token: string,
  secret: string
): Promise<SessionTokenPayload> {
  const key = new TextEncoder().encode(secret);
  const { payload } = await jwtVerify(token, key);
  return payload as unknown as SessionTokenPayload;
}
