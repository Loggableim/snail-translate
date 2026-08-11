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

export async function verifySessionToken(
  token: string,
  secret: string
): Promise<SessionTokenPayload> {
  const key = new TextEncoder().encode(secret);
  const { payload } = await jwtVerify(token, key);
  return payload as unknown as SessionTokenPayload;
}
