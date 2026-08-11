/**
 * Snail Relay — Cloudflare Durable Object.
 *
 * Responsibilities:
 * - Hold WebSocket connections (both devices)
 * - Session state (room ID, host/guest, languages)
 * - Audio streaming proxy (STT/MT/TTS APIs)
 * - Quota tracking (per session)
 */

import { verifySessionToken, type SessionTokenPayload } from "./auth";
import { processAudioPipeline } from "./pipeline";

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
  sessionSecret: string;  // Passed from Worker at /init
  chatHistory: ServerMessage[];
  deliveredMessageIds?: string[];
}

interface ClientMessage {
  type: "auth" | "audio" | "pcm_audio" | "fallback_pcm_audio" | "chat" | "sticker" | "signal" | "ping" | "end";
  token?: string;
  audio?: number[];
  sampleRate?: number;
  messageId?: string;
  text?: string;
  sourceLang?: string;
  targetLang?: string;
  assetUrl?: string;
  emoji?: string;
  packShortName?: string;
  stickerId?: string;
  fileUniqueId?: string;
  isAnimated?: boolean;
  isVideo?: boolean;
  mimeType?: string;
  signalType?: "offer" | "answer" | "ice";
  signal?: unknown;
  timestamp?: number;
}

interface ServerMessage {
  type: "auth_ok" | "auth_error" | "audio" | "pcm_audio" | "fallback_pcm_audio" | "chat" | "sticker" | "signal" | "ping" | "chat_history" | "delivery_ack" | "error" | "peer_joined" | "peer_left" | "session_end";
  audio?: number[];
  sampleRate?: number;
  messageId?: string;
  text?: string;
  senderId?: string;
  sourceLang?: string;
  targetLang?: string;
  timestamp?: number;
  assetUrl?: string;
  emoji?: string;
  packShortName?: string;
  stickerId?: string;
  fileUniqueId?: string;
  isAnimated?: boolean;
  isVideo?: boolean;
  mimeType?: string;
  signalType?: "offer" | "answer" | "ice";
  signal?: unknown;
  history?: ServerMessage[];
  error?: string;
  peerId?: string;
  reason?: string;
}

// ── Constants ────────────────────────────────────────────────────────

const PING_INTERVAL_MS = 30_000;
const MAX_QUOTA_SECONDS = 30 * 60;

// ── Durable Object ────────────────────────────────────────────────────

export class SnailRelay implements DurableObject {
  private state: DurableObjectState;
  private session: SessionState;
  private secret: string = "";

  constructor(state: DurableObjectState, _env: any) {
    this.state = state;
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
      sessionSecret: "",
      chatHistory: [],
      deliveredMessageIds: [],
    };

    this.state.blockConcurrencyWhile(async () => {
      const saved = await this.state.storage.get<SessionState>("session");
      if (saved) {
        this.session = saved;
        // Sessions created before chat history was introduced may not have
        // this field yet.
        this.session.chatHistory ??= [];
        this.session.deliveredMessageIds ??= [];
      }
      // Restore secret from storage
      const savedSecret = await this.state.storage.get<string>("secret");
      if (savedSecret) {
        this.secret = savedSecret;
      }
    });
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
      // Read session secret from header (set by Worker)
      const secretHeader = request.headers.get("X-Session-Secret");
      if (secretHeader) {
        this.secret = secretHeader;
        await this.state.storage.put("secret", secretHeader);
      }

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
      try {
        msg = JSON.parse(event.data as string);
      } catch {
        this.send(ws, { type: "error", error: "Invalid JSON" });
        return;
      }

      switch (msg.type) {
        case "auth": {
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

        case "audio": {
          if (!authenticated || !msg.audio) {
            this.send(ws, { type: "error", error: "Not authenticated or no audio" });
            return;
          }

          if (this.session.tier === "free" && this.session.quotaUsed >= MAX_QUOTA_SECONDS) {
            this.send(ws, { type: "error", error: "Quota exceeded" });
            return;
          }

          try {
            const audioOutput = await processAudioPipeline(
              msg.audio,
              this.session.sourceLang,
              this.session.targetLang,
              this.session.tier
            );

            const peer = this.getPeer(ws);
            if (peer) {
              this.send(peer, { type: "audio", audio: Array.from(audioOutput) });
            }

            this.session.quotaUsed += 0.02;
            await this.saveState();
          } catch (err) {
            this.send(ws, { type: "error", error: `Pipeline error: ${(err as Error).message}` });
          }
          break;
        }

        case "chat": {
          if (!authenticated || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Not authenticated or empty message" });
            return;
          }

          const messageId = msg.messageId || crypto.randomUUID();
          this.session.deliveredMessageIds ??= [];
          if (this.session.deliveredMessageIds.includes(messageId)) {
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
          // The relay is the durable store-and-forward path. Persist before
          // looking up the peer so a message sent while the recipient is
          // offline is available immediately after the next authentication.
          this.session.chatHistory.push(chatMessage);
          this.session.chatHistory = this.session.chatHistory.slice(-500);
          this.session.deliveredMessageIds.push(messageId);
          this.session.deliveredMessageIds = this.session.deliveredMessageIds.slice(-500);
          await this.saveState();
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, chatMessage);
          this.send(ws, { type: "delivery_ack", messageId: chatMessage.messageId });
          break;
        }

        case "pcm_audio": {
          if (!authenticated || !msg.audio?.length || !msg.sampleRate) {
            this.send(ws, { type: "error", error: "Invalid PCM audio" });
            return;
          }
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, { type: "pcm_audio", audio: msg.audio, sampleRate: msg.sampleRate });
          break;
        }

        case "fallback_pcm_audio": {
          if (!authenticated || !msg.audio?.length || !msg.sampleRate) {
            this.send(ws, { type: "error", error: "Invalid fallback PCM audio" });
            return;
          }
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, { type: "fallback_pcm_audio", audio: msg.audio, sampleRate: msg.sampleRate });
          break;
        }

        case "sticker": {
          if (!authenticated || !msg.assetUrl || !msg.mimeType) {
            this.send(ws, { type: "error", error: "Invalid sticker" });
            return;
          }
          const messageId = msg.messageId || crypto.randomUUID();
          this.session.deliveredMessageIds ??= [];
          if (this.session.deliveredMessageIds.includes(messageId)) {
            this.send(ws, { type: "delivery_ack", messageId });
            break;
          }
          const stickerMessage = {
            type: "sticker",
            messageId,
            senderId: userId || undefined,
            assetUrl: msg.assetUrl,
            emoji: msg.emoji || '🙂',
            packShortName: msg.packShortName || 'snail-local',
            stickerId: msg.stickerId,
            fileUniqueId: msg.fileUniqueId,
            isAnimated: msg.isAnimated === true,
            isVideo: msg.isVideo === true,
            mimeType: msg.mimeType,
            timestamp: msg.timestamp || Date.now(),
          } as ServerMessage;
          this.session.chatHistory.push(stickerMessage);
          this.session.chatHistory = this.session.chatHistory.slice(-500);
          this.session.deliveredMessageIds.push(messageId);
          this.session.deliveredMessageIds = this.session.deliveredMessageIds.slice(-500);
          await this.saveState();
          const peer = this.getPeer(ws);
          if (peer) this.send(peer, stickerMessage);
          this.send(ws, { type: "delivery_ack", messageId: stickerMessage.messageId });
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
          this.cleanup();
          break;
        }
      }
    });

    ws.addEventListener("close", async () => {
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

      if (peer) {
        this.send(peer, { type: "peer_left", peerId: peerRole || "unknown" });
      }

      await this.saveState();

      if (!this.session.hostSocket && !this.session.guestSocket) {
        setTimeout(() => this.cleanup(), 60_000);
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

  private broadcast(msg: ServerMessage): void {
    if (this.session.hostSocket) this.send(this.session.hostSocket, msg);
    if (this.session.guestSocket) this.send(this.session.guestSocket, msg);
  }

  private startPingInterval(ws: WebSocket): void {
    const interval = setInterval(() => {
      try { ws.send(JSON.stringify({ type: "ping" })); } catch { clearInterval(interval); }
    }, PING_INTERVAL_MS);
  }

  private async saveState(): Promise<void> {
    // WebSocket instances are live runtime objects and cannot be persisted.
    // Store only the durable session metadata; sockets are restored on connect.
    const persisted: SessionState = {
      ...this.session,
      hostSocket: null,
      guestSocket: null,
    };
    await this.state.storage.put("session", persisted);
  }

  private cleanup(): void {
    if (this.session.hostSocket) {
      try { this.session.hostSocket.close(4000, "Session ended"); } catch {}
    }
    if (this.session.guestSocket) {
      try { this.session.guestSocket.close(4000, "Session ended"); } catch {}
    }
    this.session.hostSocket = null;
    this.session.guestSocket = null;
  }
}
