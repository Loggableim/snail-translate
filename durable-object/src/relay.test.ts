import { describe, expect, it, beforeEach } from "vitest";
import { SignJWT } from "jose";
import { SnailRelay } from "./SnailRelay";
import { framePcm } from "./fish-tts";

const secret = "relay-test-secret";

class Storage {
  values = new Map<string, unknown>();
  alarmAt: number | undefined;
  alarmCalls = 0;
  async get<T>(key: string) { return this.values.get(key) as T | undefined; }
  async put(key: string, value: unknown) { this.values.set(key, value); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(at: number) { this.alarmAt = at; this.alarmCalls++; }
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
  const relay = new SnailRelay(context.durableState, { FISHAUDIO_API_KEY: "test-fish-key" });
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
  socket.addEventListener("message", (event) => {
    messages.push(JSON.parse(String(event.data)));
  });
  socket.send(JSON.stringify({ type: "auth", protocolVersion: 1, token: await token(role, sub) }));
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { socket, messages };
}

function messagesOf(connection: { messages: unknown[] }, type: string) {
  return connection.messages.filter((message) => (message as { type: string }).type === type) as Array<Record<string, any>>;
}

describe("SnailRelay lifecycle and limits", () => {
  it("rejects an incompatible protocol version explicitly", async () => {
    const { relay } = await initializedRelay();
    const response = await relay.fetch(new Request("https://internal/ws", { headers: { Upgrade: "websocket" } }));
    const socket = response.webSocket!;
    socket.accept();
    const messages: unknown[] = [];
    socket.addEventListener("message", (event) => {
      messages.push(JSON.parse(String(event.data)));
    });
    socket.send(JSON.stringify({ type: "auth", protocolVersion: 99, token: await token("host", "host") }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf({ messages }, "auth_error")[0].error).toContain("Protocol version mismatch");
  });

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

  it("prevents a peer from editing or deleting another user's message", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    const guest = await connect(relay, "guest", "guest");
    host.socket.send(JSON.stringify({ type: "chat", messageId: "owned-by-host", text: "hello" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    guest.socket.send(JSON.stringify({ type: "edit", messageId: "owned-by-host", text: "changed" }));
    guest.socket.send(JSON.stringify({ type: "delete", messageId: "owned-by-host" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    const errors = messagesOf(guest, "error").map((message) => message.error).join(" ");
    expect(errors).toContain("only edit your own");
    expect(errors).toContain("only delete your own");
  });

  it("rejects oversized chat and PCM messages", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    host.socket.send(JSON.stringify({ type: "chat", text: "x".repeat(10_001) }));
    host.socket.send(framePcm(new Uint8Array(32_001), 16_000, "peer_pcm"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "error").map((message) => message.error).join(" ")).toContain("too long");
    expect(messagesOf(host, "error").map((message) => message.error).join(" ")).toContain("Invalid binary PCM frame");
  });

  it("does not reschedule the alarm for every PCM frame", async () => {
    const { relay, storage } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    const before = storage.alarmCalls;
    for (let i = 0; i < 20; i++) {
      host.socket.send(framePcm(new Uint8Array(960), 24_000, "peer_pcm"));
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(storage.alarmCalls - before).toBe(0);
  });

  it("rejects oversized voice payloads before persisting them", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    host.socket.send(JSON.stringify({
      type: "voice",
      audioData: "A".repeat(128 * 1024 + 1),
      durationMs: 1_000,
    }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "error")[0].error).toContain("Voice message too large");
  });

  it("rejects unknown Fish voices and oversized TTS text", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host");
    host.socket.send(JSON.stringify({
      type: "fish_tts_config",
      voiceId: "unknown-voice",
      model: "s2-pro",
    }));
    host.socket.send(JSON.stringify({ type: "fish_tts_text", text: "x".repeat(2_001) }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    const errors = messagesOf(host, "error").map((message) => message.error).join(" ");
    expect(errors).toContain("Unsupported Fish TTS voice or model");
    expect(errors).toContain("Fish TTS quota exceeded");
  });

  it("alarm cleanup removes persisted session data", async () => {
    const { relay, storage } = await initializedRelay();
    (relay as unknown as { session: { lastActivity: number } }).session.lastActivity = Date.now() - 31 * 60 * 1000;
    await relay.alarm();
    expect(storage.values.size).toBe(0);
  });

  it("reschedules an alarm while a session remains active", async () => {
    const { relay, storage } = await initializedRelay();
    await connect(relay, "host", "host");
    const before = storage.alarmCalls;
    await relay.alarm();
    expect(storage.alarmCalls).toBeGreaterThan(before);
    expect(storage.values.size).toBeGreaterThan(0);
  });
});
