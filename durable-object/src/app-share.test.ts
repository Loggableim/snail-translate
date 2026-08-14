import { describe, expect, it } from "vitest";
import { AppShareRelay } from "./AppShareRelay";

class Storage {
  values = new Map<string, unknown>();
  async get<T>(key: string) { return this.values.get(key) as T | undefined; }
  async put(key: string, value: unknown) { this.values.set(key, value); }
  async deleteAll() { this.values.clear(); }
  async setAlarm() {}
}

function createRelay() {
  const storage = new Storage();
  const state = {
    storage,
    blockConcurrencyWhile: async (callback: () => Promise<void>) => callback(),
  } as unknown as DurableObjectState;
  return { relay: new AppShareRelay(state, {}), storage };
}

async function init(relay: AppShareRelay, expiresAt = Date.now() + 60_000) {
  await relay.fetch(new Request("https://internal/init", {
    method: "POST",
    body: JSON.stringify({ version: "0.3.0", bytes: 4, expiresAt }),
  }));
}

async function connect(relay: AppShareRelay, role: "host" | "guest") {
  const response = await relay.fetch(new Request(`https://internal/ws?role=${role}`, {
    headers: { Upgrade: "websocket" },
  }));
  const socket = response.webSocket!;
  socket.accept();
  const messages: unknown[] = [];
  socket.addEventListener("message", (event) => {
    if (typeof event.data === "string") messages.push(JSON.parse(event.data));
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { socket, messages };
}

describe("AppShareRelay", () => {
  it("pairs one host and guest and forwards binary frames", async () => {
    const { relay } = createRelay();
    await init(relay);
    const host = await connect(relay, "host");
    const guest = await connect(relay, "guest");

    const received: ArrayBuffer[] = [];
    guest.socket.addEventListener("message", (event) => {
      if (event.data instanceof ArrayBuffer) received.push(event.data);
    });
    host.socket.send(new Uint8Array([1, 2, 3, 4]).buffer);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(received).toHaveLength(1);
    expect(new Uint8Array(received[0])).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(host.messages).toContainEqual({ type: "guest_connected" });
    expect(guest.messages).toContainEqual({ type: "host_ready" });
    host.socket.send(new Uint8Array([5]).buffer);
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(received).toHaveLength(1);
    expect(host.messages).toContainEqual({
      type: "transfer_error",
      error: "Transfer exceeds announced size",
    });
  });

  it("rejects duplicate roles and cleans expired storage", async () => {
    const { relay, storage } = createRelay();
    await init(relay);
    await connect(relay, "host");
    expect((await relay.fetch(new Request("https://internal/ws?role=host", {
      headers: { Upgrade: "websocket" },
    }))).status).toBe(409);

    await relay.alarm();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(storage.values.size).toBe(0);
    expect((await relay.fetch(new Request("https://internal/ws?role=guest", {
      headers: { Upgrade: "websocket" },
    }))).status).toBe(410);
  });

  it("rejects invalid share metadata", async () => {
    const { relay, storage } = createRelay();
    const response = await relay.fetch(new Request("https://internal/init", {
      method: "POST",
      body: JSON.stringify({ version: "", bytes: -1, expiresAt: 0 }),
    }));
    expect(response.status).toBe(400);
    expect(storage.values.size).toBe(0);
  });
});
