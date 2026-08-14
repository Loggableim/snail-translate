import { describe, expect, it, beforeEach } from "vitest";
import { SignJWT } from "jose";
import { SnailRelay } from "./SnailRelay";

const secret = "relay-test-secret";

class Storage {
  values = new Map<string, unknown>();
  alarmAt: number | undefined;
  async get<T>(key: string) { return this.values.get(key) as T | undefined; }
  async put(key: string, value: unknown) { this.values.set(key, value); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(at: number) { this.alarmAt = at; }
}

async function token(role: "host" | "guest", sub: string) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sub, room: "snail-TEST", role, tier: "free", iat: now, exp: now + 3600 })
    .setProtectedHeader({ alg: "HS256" })
    .sign(new TextEncoder().encode(secret));
}

function state() {
  const storage = new Storage();
  const durableState = {
    storage,
    blockConcurrencyWhile: async (callback: () => Promise<void>) => callback(),
  } as unknown as DurableObjectState;
  return { durableState, storage };
}

async function initializedRelay() {
  const context = state();
  const relay = new SnailRelay(context.durableState, {});
  await relay.fetch(new Request("https://internal/init", {
    method: "POST",
    body: JSON.stringify({ roomId: "snail-TEST", hostId: "host", sourceLang: "de", targetLang: "en", sessionSecret: secret }),
  }));
  return { relay, ...context };
}

async function connect(relay: SnailRelay, role: "host" | "guest", sub: string) {
  const response = await relay.fetch(new Request("https://internal/ws", { headers: { Upgrade: "websocket" } }));
  const socket = response.webSocket!;
  socket.accept();
  const messages: unknown[] = [];
  socket.addEventListener("message", (event) => messages.push(JSON.parse(String(event.data))));
  socket.send(JSON.stringify({ type: "auth", token: await token(role, sub) }));
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { socket, messages };
}

function messagesOf(connection: { messages: unknown[] }, type: string) {
  return connection.messages.filter((message) => (message as { type: string }).type === type) as Array<Record<string, any>>;
}

describe("SnailRelay lifecycle and limits", () => {
  it("rejects a second host and a second guest", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    const secondHost = await connect(relay, "host", "host-2");
    const guest = await connect(relay, "guest", "guest");
    const secondGuest = await connect(relay, "guest", "guest-2");

    expect(messagesOf(host, "auth_ok")).toHaveLength(1);
    expect(messagesOf(secondHost, "auth_error")[0].error).toContain("Host already connected");
    expect(messagesOf(guest, "auth_ok")).toHaveLength(1);
    expect(messagesOf(secondGuest, "auth_error")[0].error).toContain("Guest already connected");
  });

  it("allows a guest to reconnect after disconnect", async () => {
    const { relay } = await initializedRelay();
    await connect(relay, "host", "host");
    const guest = await connect(relay, "guest", "guest");
    guest.socket.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const reconnected = await connect(relay, "guest", "guest");
    expect(messagesOf(reconnected, "auth_ok")).toHaveLength(1);
  });

  it("acknowledges a duplicate chat message once and stores one history entry", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    const guest = await connect(relay, "guest", "guest");
    host.socket.send(JSON.stringify({ type: "chat", messageId: "message-1", text: "hello" }));
    host.socket.send(JSON.stringify({ type: "chat", messageId: "message-1", text: "hello" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "delivery_ack")).toHaveLength(2);
    guest.socket.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const reconnectingGuest = await connect(relay, "guest", "guest");
    expect(messagesOf(reconnectingGuest, "chat_history")[0].history).toHaveLength(1);
  });

  it("rejects oversized chat and PCM messages", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    host.socket.send(JSON.stringify({ type: "chat", text: "x".repeat(10_001) }));
    host.socket.send(JSON.stringify({ type: "pcm_audio", audio: new Array(16_001).fill(0), sampleRate: 16_000 }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "error").map((message) => message.error).join(" ")).toContain("too long");
    expect(messagesOf(host, "error").map((message) => message.error).join(" ")).toContain("Invalid PCM audio");
  });

  it("alarm cleanup removes persisted session data", async () => {
    const { relay, storage } = await initializedRelay();
    (relay as unknown as { session: { lastActivity: number } }).session.lastActivity = Date.now() - 31 * 60 * 1000;
    await relay.alarm();
    expect(storage.values.size).toBe(0);
  });
});
