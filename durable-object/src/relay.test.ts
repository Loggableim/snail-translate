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
  async delete(key: string) { this.values.delete(key); }
  async deleteAll() { this.values.clear(); }
  async setAlarm(at: number) { this.alarmAt = at; this.alarmCalls++; }
}

async function token(role: "host" | "guest" | "listener", sub: string) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sub, room: "snail-TEST", role, tier: "free", iat: now, exp: now + 3600 })
    .setProtectedHeader({ alg: "HS256" })
    .sign(new TextEncoder().encode(secret));
}

function state() {
  const storage = new Storage();
  const sockets: WebSocket[] = [];
  const durableState = {
    storage,
    blockConcurrencyWhile: async (callback: () => Promise<void>) => callback(),
    // The relay restores host/guest/listener sockets from the hibernation
    // attachments after a wake-up; the mock must expose the same surface.
    // `acceptWebSocket` is deliberately absent so the relay keeps its
    // non-hibernation wiring (which registers the message/close listeners
    // the test sockets rely on).
    getWebSockets: () => sockets,
  } as unknown as DurableObjectState;
  return { durableState, storage, sockets };
}

async function initializedRelay(options: { mode?: "duo" | "guide"; listenerLanguages?: string[] } = {}) {
  const context = state();
  const relay = new SnailRelay(context.durableState, { FISHAUDIO_API_KEY: "test-fish-key" });
  await relay.fetch(new Request("https://internal/init", {
    method: "POST",
    body: JSON.stringify({
      roomId: "snail-TEST",
      hostId: "host",
      sourceLang: "de",
      targetLang: "en",
      sessionSecret: secret,
      ...(options.mode ? { mode: options.mode } : {}),
      ...(options.listenerLanguages ? { listenerLanguages: options.listenerLanguages } : {}),
    }),
  }));
  return { relay, ...context };
}

async function connect(relay: SnailRelay, role: "host" | "guest" | "listener", sub: string, agreementPublicKey?: string) {
  const response = await relay.fetch(new Request("https://internal/ws", { headers: { Upgrade: "websocket" } }));
  const socket = response.webSocket!;
  socket.accept();
  const messages: unknown[] = [];
  socket.addEventListener("message", (event) => {
    messages.push(JSON.parse(String(event.data)));
  });
  socket.send(JSON.stringify({
    type: "auth",
    protocolVersion: 1,
    token: await token(role, sub),
    ...(agreementPublicKey ? { agreementPublicKey } : {}),
  }));
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
    await new Promise((resolve) => setTimeout(resolve, 20));
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

  it("exchanges agreement public keys only through peer state", async () => {
    const { relay } = await initializedRelay();
    const host = await connect(relay, "host", "host", "host-key");
    const guest = await connect(relay, "guest", "guest", "guest-key");

    expect(messagesOf(host, "peer_joined").at(-1)?.peerAgreementPublicKey)
      .toBe("guest-key");
    expect(messagesOf(guest, "peer_joined").at(-1)?.peerAgreementPublicKey)
      .toBe("host-key");
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
    host.socket.send(JSON.stringify({ type: "chat", text: "x".repeat(16_385) }));
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

  it("rejects binary PCM and end messages before authentication", async () => {
    const { relay, storage } = await initializedRelay();
    const response = await relay.fetch(new Request("https://internal/ws", { headers: { Upgrade: "websocket" } }));
    const socket = response.webSocket!;
    socket.accept();
    const messages: unknown[] = [];
    socket.addEventListener("message", (event) => {
      messages.push(JSON.parse(String(event.data)));
    });
    socket.send(framePcm(new Uint8Array(960), 24_000, "peer_pcm"));
    socket.send(JSON.stringify({ type: "end" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    const errors = messages
      .filter((message) => (message as { type: string }).type === "error")
      .map((message) => (message as { error: string }).error);
    expect(errors.join(" ")).toContain("Not authenticated");
    expect(storage.values.size).toBeGreaterThan(0);
  });

  it("alarm cleanup removes persisted session data", async () => {
    const { relay, storage } = await initializedRelay();
    (relay as unknown as { session: { lastActivity: number } }).session.lastActivity = Date.now() - 31 * 60 * 1000;
    await relay.alarm();
    expect(storage.values.size).toBe(0);
  });

  it("migrates legacy session storage into separate metadata and history keys", async () => {
    const context = state();
    await context.storage.put("session", {
      roomId: "snail-TEST",
      hostId: "host",
      guestId: null,
      inviteeId: null,
      sourceLang: "de",
      targetLang: "en",
      tier: "free",
      createdAt: Date.now(),
      lastActivity: Date.now(),
      hostSocket: null,
      guestSocket: null,
      quotaUsed: 0,
      fishTtsChars: 0,
      sessionSecret: "",
      chatHistory: [{ type: "chat", messageId: "legacy", text: "opaque", timestamp: 1 }],
      deliveredMessageIds: ["legacy"],
    });
    const relay = new SnailRelay(context.durableState, { FISHAUDIO_API_KEY: "test-fish-key" });
    await new Promise((resolve) => setTimeout(resolve, 20));

    expect(context.storage.values.has("session")).toBe(false);
    expect(context.storage.values.has("session_meta")).toBe(true);
    expect(context.storage.values.has("chat_history")).toBe(false);
    expect(context.storage.values.has("chat_history_page_0")).toBe(true);
    expect((relay as unknown as { session: { chatHistory: unknown[] } }).session.chatHistory)
      .toHaveLength(1);
  });

  it("paginates large history entries below the storage page limit", async () => {
    const { relay } = await initializedRelay();
    const entries = Array.from({ length: 3 }, (_, index) => ({
      type: "voice" as const,
      messageId: `voice-${index}`,
      audioData: "A".repeat(70_000),
      durationMs: 1,
      timestamp: index,
    }));
    const pages = (relay as unknown as {
      paginateHistory(value: Array<Record<string, unknown>>): Array<unknown[]>;
    }).paginateHistory(entries);

    expect(pages).toHaveLength(3);
    for (const page of pages) {
      expect(new TextEncoder().encode(JSON.stringify(page)).length).toBeLessThan(
        96 * 1024,
      );
    }
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

describe("SnailRelay guide mode", () => {
  it("reports mode and listener count through /status", async () => {
    const duo = await initializedRelay();
    const duoStatus = await (await duo.relay.fetch(new Request("https://internal/status"))).json() as any;
    expect(duoStatus.mode).toBe("duo");
    expect(duoStatus.listenerCount).toBe(0);

    const guide = await initializedRelay({ mode: "guide", listenerLanguages: ["en", "fr"] });
    const guideStatus = await (await guide.relay.fetch(new Request("https://internal/status"))).json() as any;
    expect(guideStatus.mode).toBe("guide");
    expect(guideStatus.listenerLanguages).toEqual(["en", "fr"]);
    expect(guideStatus.listenerCount).toBe(0);
  });

  it("rejects a listener on a duo room and a guest on a guide room", async () => {
    const duo = await initializedRelay();
    const listenerOnDuo = await connect(duo.relay, "listener", "listener-1");
    expect(messagesOf(listenerOnDuo, "auth_error")[0].error).toContain("Not a listening room");

    const guide = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const guestOnGuide = await connect(guide.relay, "guest", "guest-1");
    expect(messagesOf(guestOnGuide, "auth_error")[0].error).toContain("Not a listening room");
  });

  it("admits listeners up to the cap and rejects the next one", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    await connect(relay, "host", "host");
    for (let index = 0; index < 50; index++) {
      const listener = await connect(relay, "listener", `listener-${index}`);
      expect(messagesOf(listener, "auth_ok")).toHaveLength(1);
    }
    const overflow = await connect(relay, "listener", "listener-51");
    expect(messagesOf(overflow, "auth_error")[0].error).toContain("Room is full");
  });

  it("replaces the socket when the same listener reconnects", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const first = await connect(relay, "listener", "listener-1");
    const second = await connect(relay, "listener", "listener-1");
    expect(messagesOf(second, "auth_ok")).toHaveLength(1);
    // Only one admission: the reconnect replaced the slot, it did not add one.
    const joins = messagesOf(host, "listener_joined");
    expect(joins.at(-1)?.count).toBe(1);
  });

  it("notifies the host about joins and leaves with a running count", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const first = await connect(relay, "listener", "listener-1");
    const second = await connect(relay, "listener", "listener-2");
    expect(messagesOf(host, "listener_joined").map((message) => message.count)).toEqual([1, 2]);

    first.socket.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "listener_left").at(-1)?.count).toBe(1);
    expect(messagesOf(host, "listener_left").at(-1)?.listenerId).toBe("listener-1");
    expect(messagesOf(second, "auth_ok")).toHaveLength(1);
  });

  it("fans subtitles out to every listener and stores them as transcript", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en", "fr"] });
    const host = await connect(relay, "host", "host");
    const first = await connect(relay, "listener", "listener-1");
    const second = await connect(relay, "listener", "listener-2");
    host.socket.send(JSON.stringify({
      type: "subtitle",
      messageId: "subtitle-1",
      text: "Guten Tag",
      sourceLang: "de",
      targetLang: "en",
      timestamp: 1,
    }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(first, "subtitle")).toHaveLength(1);
    expect(messagesOf(second, "subtitle")).toHaveLength(1);
    expect(messagesOf(host, "delivery_ack")).toHaveLength(1);

    // A late listener receives the transcript through the history replay.
    const late = await connect(relay, "listener", "listener-3");
    const history = messagesOf(late, "chat_history")[0].history as Array<Record<string, unknown>>;
    expect(history.some((entry) => entry.type === "subtitle" && entry.text === "Guten Tag")).toBe(true);
  });

  it("rejects subtitles from a listener and on a duo room", async () => {
    const guide = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    await connect(guide.relay, "host", "host");
    const listener = await connect(guide.relay, "listener", "listener-1");
    listener.socket.send(JSON.stringify({ type: "subtitle", text: "I am the guide now" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(listener, "error")[0].error).toContain("Only the host can send subtitles");

    const duo = await initializedRelay();
    const duoHost = await connect(duo.relay, "host", "host");
    duoHost.socket.send(JSON.stringify({ type: "subtitle", text: "hello" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(duoHost, "error")[0].error).toContain("Only the host can send subtitles");
  });

  it("routes guide chat: host fans out, listener reaches only the host", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const first = await connect(relay, "listener", "listener-1");
    const second = await connect(relay, "listener", "listener-2");

    host.socket.send(JSON.stringify({ type: "chat", messageId: "announce-1", text: "Welcome" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(first, "chat")).toHaveLength(1);
    expect(messagesOf(second, "chat")).toHaveLength(1);

    first.socket.send(JSON.stringify({ type: "chat", messageId: "question-1", text: "Where are we?" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(host, "chat").at(-1)?.text).toBe("Where are we?");
    // The other listener must not see a private question.
    expect(messagesOf(second, "chat")).toHaveLength(1);
  });

  it("rejects signaling, audio frames and end from listeners in guide mode", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    await connect(relay, "host", "host");
    const listener = await connect(relay, "listener", "listener-1");
    listener.socket.send(JSON.stringify({ type: "signal", signalType: "offer", signal: {} }));
    listener.socket.send(framePcm(new Uint8Array(960), 24_000, "peer_pcm"));
    listener.socket.send(JSON.stringify({ type: "end" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    const errors = messagesOf(listener, "error").map((message) => message.error).join(" | ");
    expect(errors).toContain("Signaling is not available in guide mode");
    expect(errors).toContain("Audio streaming is not available in guide mode");
    expect(errors).toContain("Only the host can end the session");
  });

  it("tells the audience when the host disconnects", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const listener = await connect(relay, "listener", "listener-1");
    host.socket.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(messagesOf(listener, "peer_left").at(-1)?.peerId).toBe("host");
  });

  it("closes every listener socket on cleanup", async () => {
    const { relay, storage } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    await connect(relay, "listener", "listener-1");
    await connect(relay, "listener", "listener-2");
    host.socket.send(JSON.stringify({ type: "end" }));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(storage.values.size).toBe(0);
  });

  it("restores listener sockets from hibernation attachments", async () => {
    const { durableState, sockets } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    // A wake-up only sees hibernation attachments. The non-hibernation test
    // path stores attachments in a WeakMap instead, so the registry is fed a
    // socket that exposes the same `deserializeAttachment` surface the
    // production runtime provides.
    const restoredSocket = {
      deserializeAttachment: () => ({
        authenticated: true,
        peerRole: "listener",
        userId: "listener-1",
      }),
    } as unknown as WebSocket;
    sockets.push(restoredSocket);

    const revived = new SnailRelay(durableState, { FISHAUDIO_API_KEY: "test-fish-key" });
    await new Promise((resolve) => setTimeout(resolve, 20));
    const restored = (revived as unknown as { session: { listenerSockets: Map<string, WebSocket> } })
      .session.listenerSockets;
    expect(restored.size).toBe(1);
    expect(restored.get("listener-1")).toBe(restoredSocket);
  });

  it("never persists live listener sockets", async () => {
    const { relay, storage } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    await connect(relay, "host", "host");
    await connect(relay, "listener", "listener-1");
    const meta = storage.values.get("session_meta") as Record<string, unknown>;
    expect(meta).toBeDefined();
    expect("listenerSockets" in meta).toBe(false);
    expect(meta.mode).toBe("guide");
  });

  it("lets the host remove one listener without touching the others", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const first = await connect(relay, "listener", "listener-1");
    const second = await connect(relay, "listener", "listener-2");

    host.socket.send(JSON.stringify({ type: "listener_kick", listenerId: "listener-1" }));
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messagesOf(first, "listener_kicked")).toHaveLength(1);
    // The remaining listener is untouched and the counter reflects the removal.
    expect(messagesOf(second, "listener_kicked")).toHaveLength(0);
    expect(messagesOf(host, "listener_left").at(-1)?.count).toBe(1);
    expect(messagesOf(host, "listener_left").at(-1)?.listenerId).toBe("listener-1");
  });

  it("rejects a kick from a listener and for an unknown id", async () => {
    const { relay } = await initializedRelay({ mode: "guide", listenerLanguages: ["en"] });
    const host = await connect(relay, "host", "host");
    const listener = await connect(relay, "listener", "listener-1");

    listener.socket.send(JSON.stringify({ type: "listener_kick", listenerId: "listener-1" }));
    host.socket.send(JSON.stringify({ type: "listener_kick", listenerId: "nobody" }));
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(messagesOf(listener, "error")[0].error).toContain("Only the host can remove listeners");
    expect(messagesOf(host, "error")[0].error).toContain("Listener not found");
  });
});
