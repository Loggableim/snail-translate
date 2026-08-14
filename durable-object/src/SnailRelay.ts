/**
 * Snail Relay — Cloudflare Durable Object.
 *
 * Responsibilities:
 * - Hold WebSocket connections (both devices)
 * - Session state (room ID, host/guest, languages)
 * - Audio streaming proxy (STT/MT/TTS APIs)
 * - Quota tracking (per session)
 */

import {
  validateSessionTokenForRoom,
  verifySessionToken,
  type SessionTokenPayload,
} from "./auth";
import { FishTtsConnection, framePcm, framePcmEnd } from "./fish-tts";

// ── Types ────────────────────────────────────────────────────────────

interface SessionState {
  roomId: string;
  hostId: string | null;
  guestId: string | null;
  inviteeId?: string | null;
  sourceLang: string;
  targetLang: string;
  tier: "free" | "paid";
  createdAt: number;
  lastActivity: number;
  hostSocket: WebSocket | null;
  guestSocket: WebSocket | null;
  quotaUsed: number;
  fishTtsChars: number;
  sessionSecret: string;  // Passed from Worker at /init
  chatHistory: ServerMessage[];
  deliveredMessageIds: Set<string>;
}

interface ClientMessage {
  type: "auth" | "fish_tts_config" | "fish_tts_text" | "fish_tts_flush" | "chat" | "voice" | "edit" | "delete" | "signal" | "ping" | "end";
  token?: string;
  protocolVersion?: number;
  sampleRate?: number;
  messageId?: string;
  text?: string;
  sourceLang?: string;
  targetLang?: string;
  mimeType?: string;
  signalType?: "offer" | "answer" | "ice";
  signal?: unknown;
  timestamp?: number;
  // Voice message fields
  audioData?: string;
  durationMs?: number;
  voiceId?: string;
  model?: string;
  temperature?: number;
  topP?: number;
  speed?: number;
}

interface ServerMessage {
  type: "auth_ok" | "auth_error" | "chat" | "voice" | "edit" | "delete" | "signal" | "ping" | "chat_history" | "delivery_ack" | "error" | "peer_joined" | "peer_left" | "session_end";
  sampleRate?: number;
  messageId?: string;
  text?: string;
  senderId?: string;
  sourceLang?: string;
  targetLang?: string;
  timestamp?: number;
  mimeType?: string;
  signalType?: "offer" | "answer" | "ice";
  signal?: unknown;
  history?: ServerMessage[];
  error?: string;
  protocolVersion?: number;
  peerId?: string;
  reason?: string;
  // Voice message fields
  audioData?: string;
  durationMs?: number;
  [key: string]: unknown;
}

// ── Constants ────────────────────────────────────────────────────────

const PING_INTERVAL_MS = 30_000;
const MAX_QUOTA_SECONDS = 30 * 60;
const MAX_PCM_SAMPLES_PER_MESSAGE = 16_000; // max 1 s mono PCM at 16 kHz
const MAX_CHAT_TEXT_LENGTH = 10_000;         // max chars per chat message
const MAX_VOICE_AUDIO_DATA_LENGTH = 128 * 1024; // max base64 payload per voice message
const MAX_FISH_TTS_CHARS = 10_000;
const MAX_FISH_TTS_TEXT_LENGTH = 2_000;
const ALLOWED_FISH_VOICES = new Set([
  "802e3bc2b27e49c2995d23ef70e6ac89",
  "2d4039641d67419fa132ca59fa2f61ad",
  "42039da0dcbd49bc8846fc1c12def1f4",
]);
const ALLOWED_FISH_MODELS = new Set(["s2-pro", "s1"]);
const SESSION_INACTIVITY_TIMEOUT_MS = 30 * 60 * 1_000; // 30 minutes
const PROTOCOL_VERSION = 1;

function relayLog(event: string, fields: Record<string, string | number | boolean>): void {
  // Never include tokens, provider keys, or message text in operational logs.
  console.log(JSON.stringify({ service: "snail-relay", event, ...fields }));
}

// ── Durable Object ────────────────────────────────────────────────────

export class SnailRelay implements DurableObject {
  private state: DurableObjectState;
  private session: SessionState;
  private secret: string = "";
  private pingIntervals = new Map<WebSocket, ReturnType<typeof setInterval>>();
  private fishApiKey: string;
  private fishTts = new Map<"host" | "guest", FishTtsConnection>();

  constructor(state: DurableObjectState, env: any) {
    this.state = state;
    this.fishApiKey = env.FISHAUDIO_API_KEY || "";
    this.session = {
      roomId: "",
      hostId: null,
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
      chatHistory: [],
      deliveredMessageIds: new Set(),
    };

    this.state.blockConcurrencyWhile(async () => {
      const saved = await this.state.storage.get<SessionState>("session");
      if (saved) {
        this.session = saved;
        // Sessions created before chat history was introduced may not have
        // this field yet.
        this.session.chatHistory ??= [];
        this.session.deliveredMessageIds = new Set(
          Array.isArray(saved.deliveredMessageIds)
            ? saved.deliveredMessageIds
            : [...(saved.deliveredMessageIds ?? new Set())],
        );
        this.session.fishTtsChars ??= 0;
      }
      // Restore secret from storage
      const savedSecret = await this.state.storage.get<string>("secret");
      if (savedSecret) {
        this.secret = savedSecret;
      }
    });
  }

  // ── Alarm Handler ──────────────────────────────────────────────────

  async alarm(): Promise<void> {
    const now = Date.now();
    const inactiveMs = now - this.session.lastActivity;
    if (inactiveMs >= SESSION_INACTIVITY_TIMEOUT_MS) {
      console.log(
        `Session ${this.session.roomId} inactive for ${Math.round(inactiveMs / 1000)}s — cleaning up`
      );
      this.broadcast({ type: "session_end", reason: "Session timed out due to inactivity" });
      await this.cleanup();
    } else if (this.session.hostSocket || this.session.guestSocket) {
      await this.scheduleInactivityAlarm();
    }
  }

  // ── HTTP Handler ──────────────────────────────────────────────────

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // Internal: initialize session (called by Worker on room creation)
    if (url.pathname === "/init" && request.method === "POST") {
      const body: any = await request.json();
      this.session.roomId = body.roomId;
      this.session.hostId = body.hostId;
      this.session.inviteeId = body.inviteeId || null;
      this.session.sourceLang = body.sourceLang || "de";
      this.session.targetLang = body.targetLang || "en";
      this.session.tier = body.tier || "free";
      this.session.sessionSecret = body.sessionSecret || "";
      if (body.sessionSecret) {
        this.secret = body.sessionSecret;
        await this.state.storage.put("secret", body.sessionSecret);
      }
      this.session.createdAt = Date.now();
      this.session.lastActivity = Date.now();
      await this.saveState();
      await this.scheduleInactivityAlarm();
      return new Response(JSON.stringify({ status: "ok" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Internal: set session secret (called before WebSocket upgrade)
    if (url.pathname === "/init-secret" && request.method === "POST") {
      const body: any = await request.json();
      if (body.sessionSecret) {
        this.secret = body.sessionSecret;
        await this.state.storage.put("secret", body.sessionSecret);
      }
      return new Response(JSON.stringify({ status: "ok" }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Internal: get status
    if (url.pathname === "/status") {
      return new Response(
        JSON.stringify({
          roomId: this.session.roomId,
          hostId: this.session.hostId,
          guestId: this.session.guestId,
          inviteeId: this.session.inviteeId || null,
          sourceLang: this.session.sourceLang,
          targetLang: this.session.targetLang,
          tier: this.session.tier,
        }),
        {
          status: this.session.roomId ? 200 : 404,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    // WebSocket upgrade
    if (request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.handleWebSocket(server);
      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("Not found", { status: 404 });
  }

  // ── WebSocket Handler ──────────────────────────────────────────────

  private async handleWebSocket(ws: WebSocket): Promise<void> {
    let authenticated = false;
    let peerRole: "host" | "guest" | null = null;
    let userId: string | null = null;

    ws.accept();
    this.startPingInterval(ws);

    ws.addEventListener("message", async (event) => {
      this.session.lastActivity = Date.now();

      let msg: ClientMessage;
      if (event.data instanceof ArrayBuffer || event.data instanceof Uint8Array) {
        const frame = event.data instanceof Uint8Array ? event.data : new Uint8Array(event.data);
        if (frame.length < 5 || frame[0] < 2 || frame[0] > 3) {
          this.send(ws, { type: "error", error: "Invalid binary PCM frame" });
          return;
        }
        const sampleRate = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint32(1, true);
        if ((sampleRate === 0 && frame.length !== 5) || frame.length - 5 > MAX_PCM_SAMPLES_PER_MESSAGE * 2) {
          this.send(ws, { type: "error", error: "Invalid binary PCM frame" });
          return;
        }
        const peer = this.getPeer(ws);
        if (peer) peer.send(frame);
        return;
      }
      try {
        msg = JSON.parse(event.data as string);
      } catch {
        this.send(ws, { type: "error", error: "Invalid JSON" });
        return;
      }

      switch (msg.type) {
        case "auth": {
          if (msg.protocolVersion !== PROTOCOL_VERSION) {
            this.send(ws, {
              type: "auth_error",
              error: `Protocol version mismatch: expected ${PROTOCOL_VERSION}`,
              protocolVersion: PROTOCOL_VERSION,
            });
            ws.close(4003, "Protocol version mismatch");
            return;
          }
          if (!msg.token) {
            this.send(ws, { type: "auth_error", error: "Missing token" });
            ws.close(4001, "Missing token");
            return;
          }

          try {
            // The Worker must initialize the shared secret first.
            let payload: SessionTokenPayload;
            if (!this.secret) {
              // Dev mode — parse token without verification
              throw new Error("Relay session secret is not initialized");
              /* const parts = msg.token.split(".");
              if (parts.length === 3) {
                const decoded = JSON.parse(atob(parts[1]));
                payload = decoded as SessionTokenPayload;
              } else {
                throw new Error("Invalid token format");
              } */
            } else {
              payload = await verifySessionToken(msg.token, this.secret);
            }
            validateSessionTokenForRoom(payload, this.session.roomId);
            userId = payload.sub;
            peerRole = payload.role;

            if (payload.role === "host") {
              if (this.session.hostSocket) {
                this.send(ws, { type: "auth_error", error: "Host already connected" });
                ws.close(4002, "Host already connected");
                return;
              }
              this.session.hostSocket = ws;
              this.session.hostId = userId;
            } else {
              if (this.session.guestSocket) {
                this.send(ws, { type: "auth_error", error: "Guest already connected" });
                ws.close(4002, "Guest already connected");
                return;
              }
              this.session.guestSocket = ws;
              this.session.guestId = userId;
            }

            authenticated = true;
            await this.scheduleInactivityAlarm();
            this.send(ws, { type: "auth_ok", peerId: payload.role });

            if (this.session.chatHistory.length > 0) {
              this.send(ws, { type: "chat_history", history: this.session.chatHistory });
            }

            // Notify peer
            const peer = this.getPeer(ws);
            if (peer) {
              this.send(peer, { type: "peer_joined", peerId: payload.role });
              // The newly authenticated socket also needs the peer state.
              // Otherwise the guest remains stuck on "waiting" when the host
              // was already connected before the guest joined.
              this.send(ws, { type: "peer_joined", peerId: peerRole === "host" ? "guest" : "host" });
            }

            await this.saveState();
          } catch (err) {
            const reason = (err as Error).message || "unknown token error";
            console.error("Auth error:", reason);
            this.send(ws, { type: "auth_error", error: `Invalid token: ${reason}` });
            ws.close(4001, "Invalid token");
          }
          break;
        }

        case "chat": {
          if (!authenticated || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Not authenticated or empty message" });
            return;
          }

          if (msg.text!.length > MAX_CHAT_TEXT_LENGTH) {
            this.send(ws, { type: "error", error: `Message too long (max ${MAX_CHAT_TEXT_LENGTH} characters)` });
            return;
          }

          const messageId = msg.messageId || crypto.randomUUID();

          if (this.session.deliveredMessageIds.has(messageId)) {
            this.send(ws, { type: "delivery_ack", messageId });
            break;
          }

          const chatMessage: ServerMessage = {
            type: "chat",
            messageId,
            senderId: userId || undefined,
            text: msg.text.trim(),
            sourceLang: msg.sourceLang || this.session.sourceLang,
            targetLang: msg.targetLang || this.session.targetLang,
            timestamp: msg.timestamp || Date.now(),
          };

          this.session.chatHistory.push(chatMessage);
          this.session.chatHistory = this.session.chatHistory.slice(-500);
          this.session.deliveredMessageIds.add(messageId);
          this.trimDeliveredMessageIds();
          await this.saveState();
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, chatMessage);
          this.send(ws, { type: "delivery_ack", messageId: chatMessage.messageId });
          break;
        }

        case "fish_tts_config": {
          if (!authenticated || !peerRole || !msg.voiceId?.trim()) {
            this.send(ws, { type: "error", error: "Invalid Fish TTS configuration" });
            return;
          }
          if (!this.fishApiKey) {
            this.send(ws, { type: "error", error: "Server Fish TTS is not configured" });
            return;
          }
          if (!ALLOWED_FISH_VOICES.has(msg.voiceId) ||
              (msg.model != null && !ALLOWED_FISH_MODELS.has(msg.model))) {
            this.send(ws, { type: "error", error: "Unsupported Fish TTS voice or model" });
            return;
          }
          try {
            await this.fishConnection(peerRole).configure({
              voiceId: msg.voiceId,
              model: msg.model,
              temperature: msg.temperature,
              topP: msg.topP,
              speed: msg.speed,
            });
          } catch (err) {
            relayLog("provider_request_failed", { provider: "fish_tts", operation: "configure" });
            this.send(ws, { type: "error", error: `Fish TTS connect failed: ${(err as Error).message}` });
          }
          break;
        }

        case "fish_tts_text": {
          if (!authenticated || !peerRole || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Invalid Fish TTS text" });
            return;
          }
          if (msg.text.length > MAX_FISH_TTS_TEXT_LENGTH ||
              this.session.fishTtsChars + msg.text.length > MAX_FISH_TTS_CHARS) {
            relayLog("provider_quota_rejected", { provider: "fish_tts", limit: MAX_FISH_TTS_CHARS });
            this.send(ws, { type: "error", error: "Fish TTS quota exceeded" });
            return;
          }
          this.session.fishTtsChars += msg.text.length;
          await this.saveState();
          try {
            await this.fishConnection(peerRole).sendText(msg.text);
          } catch (err) {
            relayLog("provider_request_failed", { provider: "fish_tts", operation: "send_text" });
            this.send(ws, { type: "error", error: `Fish TTS send failed: ${(err as Error).message}` });
          }
          break;
        }

        case "fish_tts_flush": {
          if (!authenticated || !peerRole) {
            this.send(ws, { type: "error", error: "Not authenticated" });
            return;
          }
          try {
            await this.fishConnection(peerRole).flush();
          } catch (err) {
            relayLog("provider_request_failed", { provider: "fish_tts", operation: "flush" });
            this.send(ws, { type: "error", error: `Fish TTS flush failed: ${(err as Error).message}` });
          }
          break;
        }

        case "voice": {
          if (!authenticated || !msg.audioData || !msg.durationMs) {
            this.send(ws, { type: "error", error: "Invalid voice message" });
            return;
          }
          if (msg.audioData.length > MAX_VOICE_AUDIO_DATA_LENGTH) {
            this.send(ws, {
              type: "error",
              error: `Voice message too large (max ${MAX_VOICE_AUDIO_DATA_LENGTH} characters)`,
            });
            return;
          }

          const messageId = msg.messageId || crypto.randomUUID();

          if (this.session.deliveredMessageIds.has(messageId)) {
            this.send(ws, { type: "delivery_ack", messageId });
            break;
          }

          const voiceMessage: ServerMessage = {
            type: "voice",
            messageId,
            senderId: userId || undefined,
            audioData: msg.audioData,
            mimeType: msg.mimeType || "audio/pcm16",
            sampleRate: msg.sampleRate || 16000,
            durationMs: msg.durationMs,
            timestamp: msg.timestamp || Date.now(),
          };

          this.session.chatHistory.push(voiceMessage);
          this.session.chatHistory = this.session.chatHistory.slice(-500);
          this.session.deliveredMessageIds.add(messageId);
          this.trimDeliveredMessageIds();
          await this.saveState();
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, voiceMessage);
          this.send(ws, { type: "delivery_ack", messageId: voiceMessage.messageId });
          break;
        }

        case "edit": {
          if (!authenticated || !msg.messageId || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Invalid edit message" });
            return;
          }
          // Update in-memory chat history
          const idx = this.session.chatHistory.findIndex(
            (m) => m.messageId === msg.messageId
          );
          if (idx !== -1 && this.session.chatHistory[idx].senderId !== userId) {
            this.send(ws, { type: "error", error: "You can only edit your own messages" });
            return;
          }
          if (idx !== -1) {
            this.session.chatHistory[idx] = {
              ...this.session.chatHistory[idx],
              text: msg.text.trim(),
            };
            await this.saveState();
          }
          // Forward to peer
          const peer = this.getPeer(ws);
          if (peer) {
            this.send(peer, {
              type: "edit",
              messageId: msg.messageId,
              text: msg.text.trim(),
            });
          }
          break;
        }

        case "delete": {
          if (!authenticated || !msg.messageId) {
            this.send(ws, { type: "error", error: "Invalid delete message" });
            return;
          }
          const message = this.session.chatHistory.find((m) => m.messageId === msg.messageId);
          if (message && message.senderId !== userId) {
            this.send(ws, { type: "error", error: "You can only delete your own messages" });
            return;
          }
          // Remove from in-memory chat history
          this.session.chatHistory = this.session.chatHistory.filter(
            (m) => m.messageId !== msg.messageId
          );
          await this.saveState();
          // Forward to peer
          const peer = this.getPeer(ws);
          if (peer) {
            this.send(peer, {
              type: "delete",
              messageId: msg.messageId,
            });
          }
          break;
        }

        case "signal": {
          if (!authenticated || !msg.signalType || msg.signal == null) {
            this.send(ws, { type: "error", error: "Invalid WebRTC signal" });
            return;
          }
          const peer = this.getPeer(ws);
          if (peer) {
            this.send(peer, {
              type: "signal",
              signalType: msg.signalType,
              signal: msg.signal,
            });
          }
          break;
        }

        case "ping": {
          this.send(ws, { type: "ping" });
          break;
        }

        case "end": {
          this.broadcast({ type: "session_end", reason: "Session ended" });
          await this.cleanup();
          break;
        }

        default: {
          console.warn("Unknown relay message type", msg.type);
          this.send(ws, { type: "error", error: `Unknown message type: ${String(msg.type)}` });
          break;
        }
      }
    });

    ws.addEventListener("close", async () => {
      this.stopPingInterval(ws);
      // Resolve the counterpart before clearing the closing socket. Looking it
      // up afterwards always returns null, which leaves the other device
      // visually stuck on "Verbunden" after a peer disconnects.
      const peer = this.getPeer(ws);
      if (peerRole === "host" && this.session.hostSocket === ws) {
        this.session.hostSocket = null;
      } else if (peerRole === "guest" && this.session.guestSocket === ws) {
        this.session.guestSocket = null;
        // `guestId` is the Worker-side capacity marker. Keeping it after a
        // disconnected guest permanently turns a one-to-one room into
        // "Room is full" and prevents the same device from reconnecting.
        // Guard by socket identity so a delayed close from an old connection
        // cannot evict a newly authenticated guest.
        this.session.guestId = null;
      }
      if (peerRole) {
        this.fishTts.get(peerRole)?.close();
        this.fishTts.delete(peerRole);
      }

      if (peer) {
        this.send(peer, { type: "peer_left", peerId: peerRole || "unknown" });
      }

      await this.saveState();
      await this.scheduleInactivityAlarm();

      if (!this.session.hostSocket && !this.session.guestSocket) {
        void this.scheduleInactivityAlarm();
      }
    });

    ws.addEventListener("error", (err) => {
      console.error("WebSocket error:", err);
    });
  }

  // ── Helpers ────────────────────────────────────────────────────────

  private getPeer(ws: WebSocket): WebSocket | null {
    if (ws === this.session.hostSocket) return this.session.guestSocket;
    if (ws === this.session.guestSocket) return this.session.hostSocket;
    return null;
  }

  private send(ws: WebSocket, msg: ServerMessage): void {
    try { ws.send(JSON.stringify(msg)); } catch {}
  }

  private fishConnection(role: "host" | "guest"): FishTtsConnection {
    let connection = this.fishTts.get(role);
    if (connection) return connection;
    connection = new FishTtsConnection(
      this.fishApiKey,
      (audio) => {
        const target = role === "host" ? this.session.guestSocket : this.session.hostSocket;
        if (target) {
          try { target.send(framePcm(audio, 24000, "fish_tts")); } catch {}
        }
      },
      () => {
        const target = role === "host" ? this.session.guestSocket : this.session.hostSocket;
        if (target) {
          try { target.send(framePcmEnd("fish_tts")); } catch {}
        }
      },
    );
    this.fishTts.set(role, connection);
    return connection;
  }

  private broadcast(msg: ServerMessage): void {
    if (this.session.hostSocket) this.send(this.session.hostSocket, msg);
    if (this.session.guestSocket) this.send(this.session.guestSocket, msg);
  }

  private startPingInterval(ws: WebSocket): void {
    const interval = setInterval(() => {
      try {
        ws.send(JSON.stringify({ type: "ping" }));
      } catch {
        this.stopPingInterval(ws);
      }
    }, PING_INTERVAL_MS);
    this.pingIntervals.set(ws, interval);
  }

  private stopPingInterval(ws: WebSocket): void {
    const interval = this.pingIntervals.get(ws);
    if (interval) clearInterval(interval);
    this.pingIntervals.delete(ws);
  }

  private async scheduleInactivityAlarm(): Promise<void> {
    await this.state.storage.setAlarm(Date.now() + SESSION_INACTIVITY_TIMEOUT_MS);
  }

  private async saveState(): Promise<void> {
    // WebSocket instances are live runtime objects and cannot be persisted.
    // Store only the durable session metadata; sockets are restored on connect.
    const persisted = {
      ...this.session,
      hostSocket: null,
      guestSocket: null,
      deliveredMessageIds: [...this.session.deliveredMessageIds],
    };
    await this.state.storage.put("session", persisted);
  }

  private trimDeliveredMessageIds(): void {
    while (this.session.deliveredMessageIds.size > 500) {
      const oldest = this.session.deliveredMessageIds.values().next().value as string | undefined;
      if (oldest === undefined) break;
      this.session.deliveredMessageIds.delete(oldest);
    }
  }

  private async cleanup(): Promise<void> {
    for (const connection of this.fishTts.values()) connection.close();
    this.fishTts.clear();
    if (this.session.hostSocket) {
      try { this.session.hostSocket.close(4000, "Session ended"); } catch {}
    }
    if (this.session.guestSocket) {
      try { this.session.guestSocket.close(4000, "Session ended"); } catch {}
    }
    this.session.hostSocket = null;
    this.session.guestSocket = null;
    await this.state.storage.deleteAll();
  }
}
