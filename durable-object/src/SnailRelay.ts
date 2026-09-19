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
import {
  type FishTtsConfig,
  FishTtsConnection,
  framePcm,
  framePcmEnd,
} from "./fish-tts";
import { PROTOCOL_VERSION } from "../../shared/dto/v1/generated/protocol";

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
  // Guide mode: one speaker, N listeners. `mode` is fixed at room creation;
  // duo and guide route differently (fan-out vs. single peer), so mixing them
  // would be a third mode rather than a flag.
  mode: "duo" | "guide";
  listenerLanguages: string[];
  // Live listener sockets keyed by userId. Never persisted — WebSocket
  // instances are runtime objects (see saveState()).
  listenerSockets: Map<string, WebSocket>;
  quotaUsed: number;
  fishTtsChars: number;
  sessionSecret: string;  // Passed from Worker at /init
  hostAgreementPublicKey: string | null;
  guestAgreementPublicKey: string | null;
  historyPageCount?: number;
  chatHistory: ServerMessage[];
  deliveredMessageIds: Set<string>;
  // Last configured Fish TTS voice per direction. Persisted so a hibernated
  // DO can rebuild its warm Fish connections after wake-up.
  fishTtsConfig?: Partial<Record<"host" | "guest", FishTtsConfig>>;
}

interface ClientMessage {
  type: "auth" | "fish_tts_config" | "fish_tts_text" | "fish_tts_flush" | "chat" | "voice" | "edit" | "delete" | "signal" | "ping" | "end" | "subtitle" | "listener_kick" | "contact_request" | "contact_response";
  token?: string;
  protocolVersion?: number;
  agreementPublicKey?: string;
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
  // Guide-mode moderation and contact exchange
  listenerId?: string;
  userId?: string;
  accepted?: boolean;
}

interface ServerMessage {
  type: "auth_ok" | "auth_error" | "chat" | "voice" | "edit" | "delete" | "signal" | "ping" | "chat_history" | "delivery_ack" | "error" | "peer_joined" | "peer_left" | "session_end" | "subtitle" | "listener_joined" | "listener_left" | "listener_kicked" | "contact_request" | "contact_response";
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
  peerAgreementPublicKey?: string;
  reason?: string;
  // Listener bookkeeping
  listenerId?: string;
  count?: number;
  // Voice message fields
  audioData?: string;
  durationMs?: number;
  [key: string]: unknown;
}

interface SocketAttachment {
  authenticated: boolean;
  peerRole: "host" | "guest" | "listener" | null;
  userId: string | null;
}

// ── Constants ────────────────────────────────────────────────────────

const MAX_QUOTA_SECONDS = 30 * 60;
const MAX_PCM_SAMPLES_PER_MESSAGE = 16_000; // max 1 s mono PCM at 16 kHz
const MAX_CHAT_TEXT_LENGTH = 16_384;         // max chars per chat message
const MAX_SUBTITLE_TEXT_LENGTH = 2_000;      // max chars per subtitle
const MAX_LISTENERS = 50;                    // guide mode fan-out cap
const MAX_VOICE_AUDIO_DATA_LENGTH = 64 * 1024; // keeps one voice entry below a history page
const MAX_HISTORY_PAGE_BYTES = 96 * 1024;
const MAX_FISH_TTS_CHARS = 10_000;
const MAX_FISH_TTS_TEXT_LENGTH = 2_000;
const ALLOWED_FISH_VOICES = new Set([
  "802e3bc2b27e49c2995d23ef70e6ac89",
  "2d4039641d67419fa132ca59fa2f61ad",
  "42039da0dcbd49bc8846fc1c12def1f4",
]);
const ALLOWED_FISH_MODELS = new Set(["s2-pro", "s1"]);
const SESSION_INACTIVITY_TIMEOUT_MS = 30 * 60 * 1_000; // 30 minutes
function relayLog(event: string, fields: Record<string, string | number | boolean>): void {
  // Never include tokens, provider keys, or message text in operational logs.
  console.log(JSON.stringify({ service: "snail-relay", event, ...fields }));
}

// ── Durable Object ────────────────────────────────────────────────────

export class SnailRelay implements DurableObject {
  private state: DurableObjectState;
  private session: SessionState;
  private secret: string = "";
  private fishApiKey: string;
  private fishTts = new Map<"host" | "guest", FishTtsConnection>();
  private localAttachments = new WeakMap<WebSocket, SocketAttachment>();

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
      mode: "duo",
      listenerLanguages: [],
      listenerSockets: new Map(),
      quotaUsed: 0,
      fishTtsChars: 0,
      sessionSecret: "",
      hostAgreementPublicKey: null,
      guestAgreementPublicKey: null,
      historyPageCount: 0,
      chatHistory: [],
      deliveredMessageIds: new Set(),
    };

    this.state.blockConcurrencyWhile(async () => {
      const saved = await this.state.storage.get<SessionState>("session");
      const savedMeta = await this.state.storage.get<Partial<SessionState>>(
        "session_meta",
      );
      const savedHistory = await this.state.storage.get<ServerMessage[]>(
        "chat_history",
      );
      const pagedHistory: ServerMessage[] = [];
      const historyPageCount = savedMeta?.historyPageCount ?? 0;
      for (let page = 0; page < historyPageCount; page++) {
        const entries = await this.state.storage.get<ServerMessage[]>(
          `chat_history_page_${page}`,
        );
        if (Array.isArray(entries)) pagedHistory.push(...entries);
      }
      if (saved || savedMeta) {
        this.session = {
          ...this.session,
          ...(saved ?? savedMeta),
          chatHistory: saved?.chatHistory ??
            (pagedHistory.length > 0 ? pagedHistory : savedHistory ?? []),
          hostSocket: null,
          guestSocket: null,
          // Live sockets are never restored from storage — only from the
          // hibernation attachments (restoreSockets below).
          listenerSockets: new Map(),
        };
        // Sessions created before chat history was introduced may not have
        // this field yet.
        this.session.chatHistory ??= [];
        // Sessions created before guide mode existed are duo rooms.
        this.session.mode ??= "duo";
        this.session.listenerLanguages ??= [];
        const storedDeliveredMessageIds =
          saved?.deliveredMessageIds ?? savedMeta?.deliveredMessageIds;
        this.session.deliveredMessageIds = new Set(
          Array.isArray(storedDeliveredMessageIds)
            ? storedDeliveredMessageIds
            : [...(storedDeliveredMessageIds ?? new Set())],
        );
        this.session.fishTtsChars ??= 0;
        this.session.hostAgreementPublicKey ??= null;
        this.session.guestAgreementPublicKey ??= null;
        this.session.historyPageCount = historyPageCount;
        if (saved) {
          await this.saveState();
        }
      }
      // Restore secret from storage
      const savedSecret = await this.state.storage.get<string>("secret");
      if (savedSecret) {
        this.secret = savedSecret;
      }
      this.restoreSockets();
    });
    // Older local Miniflare versions expose the hibernation API but not the
    // automatic response helper. workerd additionally requires a real
    // WebSocketRequestResponsePair instance — a plain object throws a
    // TypeError at construction time and kills every request that touches
    // this DO. Cloudflare handles protocol ping frames in production; keep
    // local runtimes compatible by tolerating both gaps.
    try {
      this.state.setWebSocketAutoResponse?.(
        new WebSocketRequestResponsePair("ping", "pong"),
      );
    } catch {
      // Auto-response is an optimization, not a correctness requirement.
    }
  }

  // ── Alarm Handler ──────────────────────────────────────────────────

  async alarm(): Promise<void> {
    const now = Date.now();
    const inactiveMs = now - this.session.lastActivity;
    if (inactiveMs >= SESSION_INACTIVITY_TIMEOUT_MS) {
      relayLog("room_inactive_cleanup", {
        inactiveSeconds: Math.round(inactiveMs / 1000),
        connectedSockets: Number(Boolean(this.session.hostSocket)) +
          Number(Boolean(this.session.guestSocket)),
      });
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
      this.session.mode = body.mode === "guide" ? "guide" : "duo";
      this.session.listenerLanguages = Array.isArray(body.listenerLanguages)
        ? body.listenerLanguages.filter((lang: unknown) => typeof lang === "string")
        : [];
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
          mode: this.session.mode,
          listenerLanguages: this.session.listenerLanguages,
          listenerCount: this.session.listenerSockets.size,
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
      const attachment = { authenticated: false, peerRole: null, userId: null } satisfies SocketAttachment;
      if (this.state.acceptWebSocket) {
        this.state.acceptWebSocket(server);
        server.serializeAttachment?.(attachment);
      } else {
        // The repository's older local Miniflare runtime does not implement
        // the hibernation hooks. Keep its event delivery usable while the
        // production path uses the hibernatable API above.
        server.accept();
        this.localAttachments.set(server, attachment);
        server.addEventListener("message", (event) => {
          void this.webSocketMessage(server, event.data as string | ArrayBuffer);
        });
        server.addEventListener("close", () => {
          void this.webSocketClose(server, 1000, "", true);
        });
        server.addEventListener("error", (error) => this.webSocketError(server, error));
      }
      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("Not found", { status: 404 });
  }

  // ── WebSocket Handler ──────────────────────────────────────────────

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer | Uint8Array): Promise<void> {
    const attachment = (ws.deserializeAttachment?.() as SocketAttachment | null) ?? this.localAttachments.get(ws) ?? {
      authenticated: false,
      peerRole: null,
      userId: null,
    };
    let authenticated = attachment.authenticated;
    let peerRole = attachment.peerRole;
    let userId = attachment.userId;
      this.session.lastActivity = Date.now();

      let msg: ClientMessage;
      if (message instanceof ArrayBuffer || message instanceof Uint8Array) {
        // Binary PCM frames are relayed to the peer, so they must never be
        // accepted from a socket that has not completed the auth handshake.
        if (!authenticated) {
          this.send(ws, { type: "error", error: "Not authenticated" });
          return;
        }
        // Guide mode has no audio path: listeners are displays and the
        // speaker's device translates locally (v1 decision D4).
        if (this.session.mode === "guide") {
          this.send(ws, { type: "error", error: "Audio streaming is not available in guide mode" });
          return;
        }
        const frame = message instanceof Uint8Array ? message : new Uint8Array(message);
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
        if (peer) this.sendBinary(peer, frame);
        return;
      }
      try {
        msg = JSON.parse(message as string);
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
            const agreementPublicKey = msg.agreementPublicKey?.trim() || null;

            if (payload.role === "host") {
              if (this.session.hostSocket) {
                this.send(ws, { type: "auth_error", error: "Host already connected" });
                ws.close(4002, "Host already connected");
                return;
              }
              this.session.hostSocket = ws;
              this.session.hostId = userId;
              this.session.hostAgreementPublicKey = agreementPublicKey;
            } else if (payload.role === "guest") {
              // Guide rooms have no guest slot: the second participant is a
              // listener, not a translating peer. Reject the guest token so a
              // stale join path cannot silently occupy a duo slot.
              if (this.session.mode === "guide") {
                this.send(ws, { type: "auth_error", error: "Not a listening room" });
                ws.close(4002, "Not a listening room");
                return;
              }
              if (this.session.guestSocket) {
                this.send(ws, { type: "auth_error", error: "Guest already connected" });
                ws.close(4002, "Guest already connected");
                return;
              }
              this.session.guestSocket = ws;
              this.session.guestId = userId;
              this.session.guestAgreementPublicKey = agreementPublicKey;
            } else {
              // Listener (guide mode only). The previous `else` branch would
              // have assigned any non-host role to the guest slot, silently
              // turning a listener into a translating peer.
              if (this.session.mode !== "guide") {
                this.send(ws, { type: "auth_error", error: "Not a listening room" });
                ws.close(4002, "Not a listening room");
                return;
              }
              const existing = this.session.listenerSockets.get(userId);
              if (existing && existing !== ws) {
                // Same identity reconnecting: replace the old socket instead
                // of consuming a second slot. The old socket's close handler
                // checks identity, so it will not emit listener_left.
                try { existing.close(4002, "Replaced by new connection"); } catch {}
                this.session.listenerSockets.delete(userId);
              } else if (!existing && this.session.listenerSockets.size >= MAX_LISTENERS) {
                this.send(ws, { type: "auth_error", error: "Room is full" });
                ws.close(4002, "Room is full");
                return;
              }
              this.session.listenerSockets.set(userId, ws);
            }

            authenticated = true;
            const updatedAttachment = { authenticated, peerRole, userId } satisfies SocketAttachment;
            this.localAttachments.set(ws, updatedAttachment);
            ws.serializeAttachment?.(updatedAttachment);
            await this.scheduleInactivityAlarm();
            this.send(ws, {
              type: "auth_ok",
              peerId: payload.role,
              // A (re)connecting host needs the current audience size to
              // render its counter without waiting for the next join.
              ...(payload.role === "host" && this.session.mode === "guide"
                ? { count: this.session.listenerSockets.size }
                : {}),
            });

            if (this.session.chatHistory.length > 0) {
              this.send(ws, { type: "chat_history", history: this.session.chatHistory });
            }

            if (payload.role === "listener") {
              // The host tracks the audience; listeners get no peer state.
              if (this.session.hostSocket) {
                this.send(this.session.hostSocket, {
                  type: "listener_joined",
                  listenerId: userId,
                  count: this.session.listenerSockets.size,
                });
              }
            } else {
              // Notify peer. Guide rooms have no guest slot, so getPeer()
              // returns null there and this block is a duo-mode path.
              const peer = this.getPeer(ws);
              if (peer) {
                this.send(peer, {
                  type: "peer_joined",
                  peerId: payload.role,
                  peerAgreementPublicKey: payload.role === "host"
                    ? this.session.hostAgreementPublicKey ?? undefined
                    : this.session.guestAgreementPublicKey ?? undefined,
                });
                // The newly authenticated socket also needs the peer state.
                // Otherwise the guest remains stuck on "waiting" when the host
                // was already connected before the guest joined.
                this.send(ws, {
                  type: "peer_joined",
                  peerId: peerRole === "host" ? "guest" : "host",
                  peerAgreementPublicKey: peerRole === "host"
                    ? this.session.guestAgreementPublicKey ?? undefined
                    : this.session.hostAgreementPublicKey ?? undefined,
                });
              }
            }

            await this.saveState();
          } catch (err) {
            const reason = (err as Error).message || "unknown token error";
            relayLog("auth_failure", { route: "relay_websocket", reason: "invalid_session_token" });
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
          if (this.session.mode === "guide") {
            // Guide routing: the host's messages reach the whole audience
            // (announcements), a listener's message reaches only the host
            // (questions). No peer slot exists in this mode.
            if (peerRole === "host") {
              this.fanOutToListeners(chatMessage);
            } else if (this.session.hostSocket) {
              this.send(this.session.hostSocket, chatMessage);
            }
          } else {
            const peer = this.getPeer(ws);
            if (peer) this.send(peer, chatMessage);
          }
          this.send(ws, { type: "delivery_ack", messageId: chatMessage.messageId });
          break;
        }

        case "subtitle": {
          if (!authenticated || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Not authenticated or empty subtitle" });
            return;
          }
          // Only the guide speaks; a listener sending subtitles would let any
          // audience member impersonate the speaker.
          if (peerRole !== "host" || this.session.mode !== "guide") {
            this.send(ws, { type: "error", error: "Only the host can send subtitles" });
            return;
          }
          if (msg.text!.length > MAX_SUBTITLE_TEXT_LENGTH) {
            this.send(ws, {
              type: "error",
              error: `Subtitle too long (max ${MAX_SUBTITLE_TEXT_LENGTH} characters)`,
            });
            return;
          }

          const messageId = msg.messageId || crypto.randomUUID();

          if (this.session.deliveredMessageIds.has(messageId)) {
            this.send(ws, { type: "delivery_ack", messageId });
            break;
          }

          const subtitle: ServerMessage = {
            type: "subtitle",
            messageId,
            senderId: userId || undefined,
            text: msg.text.trim(),
            sourceLang: msg.sourceLang || this.session.sourceLang,
            targetLang: msg.targetLang || this.session.targetLang,
            timestamp: msg.timestamp || Date.now(),
          };

          // Subtitles double as the transcript: a listener that joins later
          // receives the full history through the regular chat_history replay.
          this.session.chatHistory.push(subtitle);
          this.session.chatHistory = this.session.chatHistory.slice(-500);
          this.session.deliveredMessageIds.add(messageId);
          this.trimDeliveredMessageIds();
          await this.saveState();
          this.fanOutToListeners(subtitle);
          this.send(ws, { type: "delivery_ack", messageId: subtitle.messageId });
          break;
        }

        case "fish_tts_config": {
          if (!authenticated || !peerRole || !msg.voiceId?.trim()) {
            this.send(ws, { type: "error", error: "Invalid Fish TTS configuration" });
            return;
          }
          // Fish TTS is a duo-mode provider path; listeners never own a
          // translating session.
          if (peerRole === "listener") {
            this.send(ws, { type: "error", error: "Fish TTS is not available in guide mode" });
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
          const fishConfig: FishTtsConfig = {
            voiceId: msg.voiceId,
            model: msg.model,
            temperature: msg.temperature,
            topP: msg.topP,
            speed: msg.speed,
          };
          try {
            await this.fishConnection(peerRole).configure(fishConfig);
            // Persist so a hibernated DO can rebuild the warm connection.
            this.session.fishTtsConfig ??= {};
            this.session.fishTtsConfig[peerRole] = fishConfig;
          } catch (err) {
            relayLog("provider_request_failed", { provider: "fish_tts", operation: "configure" });
            this.send(ws, { type: "error", error: "Fish TTS connect failed" });
          }
          break;
        }

        case "fish_tts_text": {
          if (!authenticated || !peerRole || !msg.text?.trim()) {
            this.send(ws, { type: "error", error: "Invalid Fish TTS text" });
            return;
          }
          if (peerRole === "listener") {
            this.send(ws, { type: "error", error: "Fish TTS is not available in guide mode" });
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
            this.send(ws, { type: "error", error: "Fish TTS send failed" });
          }
          break;
        }

        case "fish_tts_flush": {
          if (!authenticated || !peerRole) {
            this.send(ws, { type: "error", error: "Not authenticated" });
            return;
          }
          if (peerRole === "listener") {
            this.send(ws, { type: "error", error: "Fish TTS is not available in guide mode" });
            return;
          }
          try {
            await this.fishConnection(peerRole).flush();
          } catch (err) {
            relayLog("provider_request_failed", { provider: "fish_tts", operation: "flush" });
            this.send(ws, { type: "error", error: "Fish TTS flush failed" });
          }
          break;
        }

        case "listener_kick": {
          if (!authenticated || !msg.listenerId) {
            this.send(ws, { type: "error", error: "Invalid listener kick" });
            return;
          }
          // Only the guide owns the audience; a listener removing others
          // would be a moderation bypass.
          if (peerRole !== "host" || this.session.mode !== "guide") {
            this.send(ws, { type: "error", error: "Only the host can remove listeners" });
            return;
          }
          const target = this.session.listenerSockets.get(msg.listenerId);
          if (!target) {
            this.send(ws, { type: "error", error: "Listener not found" });
            return;
          }
          // Remove from the map before closing so the close handler's
          // identity check finds nothing to report and cannot double-count.
          this.session.listenerSockets.delete(msg.listenerId);
          try {
            this.send(target, { type: "listener_kicked" });
            target.close(4004, "Removed by host");
          } catch {}
          this.send(ws, {
            type: "listener_left",
            listenerId: msg.listenerId,
            count: this.session.listenerSockets.size,
          });
          await this.saveState();
          break;
        }

        case "contact_request": {
          if (!authenticated || !msg.userId?.trim()) {
            this.send(ws, { type: "error", error: "Invalid contact request" });
            return;
          }
          // Contact exchange is a peer-to-peer handshake: both sides must be
          // present, because the request carries the sender's agreement key
          // and the answer has to come back the same way. A guide room has no
          // peer slot, so the request is refused rather than silently lost.
          if (this.session.mode === "guide") {
            this.send(ws, { type: "error", error: "Contact exchange is not available in guide mode" });
            return;
          }
          const peer = this.getPeer(ws);
          if (!peer) {
            this.send(ws, { type: "error", error: "No peer connected" });
            return;
          }
          this.send(peer, {
            type: "contact_request",
            userId: msg.userId.trim(),
            username: msg.text?.trim() || undefined,
            agreementPublicKey: msg.agreementPublicKey?.trim() || undefined,
            timestamp: msg.timestamp || Date.now(),
          });
          break;
        }

        case "contact_response": {
          if (!authenticated || !msg.userId?.trim()) {
            this.send(ws, { type: "error", error: "Invalid contact response" });
            return;
          }
          if (this.session.mode === "guide") {
            this.send(ws, { type: "error", error: "Contact exchange is not available in guide mode" });
            return;
          }
          const peer = this.getPeer(ws);
          if (!peer) {
            this.send(ws, { type: "error", error: "No peer connected" });
            return;
          }
          this.send(peer, {
            type: "contact_response",
            userId: msg.userId.trim(),
            accepted: msg.accepted === true,
            timestamp: msg.timestamp || Date.now(),
          });
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
          if (this.session.mode === "guide") {
            if (peerRole === "host") {
              this.fanOutToListeners(voiceMessage);
            } else if (this.session.hostSocket) {
              this.send(this.session.hostSocket, voiceMessage);
            }
          } else {
            const peer = this.getPeer(ws);
            if (peer) this.send(peer, voiceMessage);
          }
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
          // Forward to peer (duo) or fan out to the audience (guide host).
          if (this.session.mode === "guide") {
            if (peerRole === "host") {
              this.fanOutToListeners({
                type: "edit",
                messageId: msg.messageId,
                text: msg.text.trim(),
              });
            } else if (this.session.hostSocket) {
              this.send(this.session.hostSocket, {
                type: "edit",
                messageId: msg.messageId,
                text: msg.text.trim(),
              });
            }
          } else {
            const peer = this.getPeer(ws);
            if (peer) {
              this.send(peer, {
                type: "edit",
                messageId: msg.messageId,
                text: msg.text.trim(),
              });
            }
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
          // Forward to peer (duo) or fan out to the audience (guide host).
          if (this.session.mode === "guide") {
            if (peerRole === "host") {
              this.fanOutToListeners({
                type: "delete",
                messageId: msg.messageId,
              });
            } else if (this.session.hostSocket) {
              this.send(this.session.hostSocket, {
                type: "delete",
                messageId: msg.messageId,
              });
            }
          } else {
            const peer = this.getPeer(ws);
            if (peer) {
              this.send(peer, {
                type: "delete",
                messageId: msg.messageId,
              });
            }
          }
          break;
        }

        case "signal": {
          if (!authenticated || !msg.signalType || msg.signal == null) {
            this.send(ws, { type: "error", error: "Invalid WebRTC signal" });
            return;
          }
          // No P2P in guide mode: listeners are displays, not translating
          // peers, so there is no data channel to negotiate.
          if (this.session.mode === "guide") {
            this.send(ws, { type: "error", error: "Signaling is not available in guide mode" });
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
          // Ending a session tears down both sockets and deletes the stored
          // history, so it must stay restricted to authenticated peers.
          if (!authenticated) {
            this.send(ws, { type: "error", error: "Not authenticated" });
            return;
          }
          // In guide mode only the speaker owns the room; a listener ending
          // the session would disconnect the whole audience.
          if (this.session.mode === "guide" && peerRole !== "host") {
            this.send(ws, { type: "error", error: "Only the host can end the session" });
            return;
          }
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
  }

  async webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    const attachment = (ws.deserializeAttachment?.() as SocketAttachment | null) ?? this.localAttachments.get(ws);
    const peerRole = attachment?.peerRole ?? null;
    const userId = attachment?.userId ?? null;
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
      } else if (peerRole === "listener" && userId) {
        // Guard by socket identity: a reconnect replaces the map entry with a
        // new socket, and the old socket's delayed close must not evict it.
        if (this.session.listenerSockets.get(userId) === ws) {
          this.session.listenerSockets.delete(userId);
          if (this.session.hostSocket) {
            this.send(this.session.hostSocket, {
              type: "listener_left",
              listenerId: userId,
              count: this.session.listenerSockets.size,
            });
          }
        }
      }
      if (peerRole === "host" || peerRole === "guest") {
        this.fishTts.get(peerRole)?.close();
        this.fishTts.delete(peerRole);
      }

      if (peer) {
        this.send(peer, { type: "peer_left", peerId: peerRole || "unknown" });
      } else if (peerRole === "host" && this.session.mode === "guide") {
        // The speaker dropped: tell the audience instead of leaving every
        // listener on a silently frozen transcript. The inactivity alarm
        // eventually cleans the room up if the host does not return.
        this.fanOutToListeners({ type: "peer_left", peerId: "host" });
      }

      await this.saveState();
      await this.scheduleInactivityAlarm();

      if (!this.session.hostSocket && !this.session.guestSocket && this.session.listenerSockets.size === 0) {
        void this.scheduleInactivityAlarm();
      }
  }

  webSocketError(ws: WebSocket, error: unknown): void {
    console.error("WebSocket error:", error);
  }

  // ── Helpers ────────────────────────────────────────────────────────

  private getPeer(ws: WebSocket): WebSocket | null {
    if (ws === this.session.hostSocket) return this.session.guestSocket;
    if (ws === this.session.guestSocket) return this.session.hostSocket;
    return null;
  }

  /** Guide mode: deliver one message to every connected listener. */
  private fanOutToListeners(msg: ServerMessage): void {
    for (const socket of this.session.listenerSockets.values()) {
      this.send(socket, msg);
    }
  }

  private send(ws: WebSocket, msg: ServerMessage): void {
    try { ws.send(JSON.stringify(msg)); } catch {}
  }

  private sendBinary(ws: WebSocket, frame: Uint8Array): void {
    try { ws.send(frame); } catch {}
  }

  private fishConnection(role: "host" | "guest"): FishTtsConnection {
    let connection = this.fishTts.get(role);
    if (connection) return connection;
    // After hibernation the in-memory map is empty. Rebuild the warm Fish
    // connection from the persisted per-direction voice configuration so the
    // first translated turn after wake-up does not fail with "not configured".
    const savedConfig = this.session.fishTtsConfig?.[role];
    if (savedConfig?.voiceId) {
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
      // Warm up asynchronously; sendText() awaits ensureOpen() anyway.
      connection.configure(savedConfig).catch(() => {
        relayLog("provider_request_failed", { provider: "fish_tts", operation: "restore" });
      });
      this.fishTts.set(role, connection);
      return connection;
    }
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
    this.fanOutToListeners(msg);
  }

  private restoreSockets(): void {
    for (const ws of this.state.getWebSockets()) {
      const attachment = (ws.deserializeAttachment?.() as SocketAttachment | null) ?? this.localAttachments.get(ws);
      if (!attachment?.authenticated || !attachment.peerRole) continue;
      if (attachment.peerRole === "host") this.session.hostSocket = ws;
      if (attachment.peerRole === "guest") this.session.guestSocket = ws;
      // Without this the fan-out is dead after every hibernation: the map is
      // runtime state and the sockets only exist as hibernation attachments.
      if (attachment.peerRole === "listener" && attachment.userId) {
        this.session.listenerSockets.set(attachment.userId, ws);
      }
    }
  }

  private async scheduleInactivityAlarm(): Promise<void> {
    await this.state.storage.setAlarm(Date.now() + SESSION_INACTIVITY_TIMEOUT_MS);
  }

  private async saveState(): Promise<void> {
    // WebSocket instances are live runtime objects and cannot be persisted.
    // Keep metadata and bounded message history separate so voice payloads
    // cannot make the metadata record exceed Durable Object limits.
    // `listenerSockets` is a Map of live sockets and must be excluded too —
    // serializing it would throw and take the whole DO down.
    const { chatHistory, hostSocket, guestSocket, listenerSockets, ...metadata } = this.session;
    const persisted = {
      ...metadata,
      hostSocket: null,
      guestSocket: null,
      deliveredMessageIds: [...this.session.deliveredMessageIds],
      fishTtsConfig: this.session.fishTtsConfig ?? {},
    };
    const pages = this.paginateHistory(chatHistory);
    const previousPageCount = this.session.historyPageCount ?? 0;
    this.session.historyPageCount = pages.length;
    persisted.historyPageCount = pages.length;
    await this.state.storage.put("session_meta", persisted);
    for (let index = 0; index < pages.length; index++) {
      await this.state.storage.put(`chat_history_page_${index}`, pages[index]);
    }
    for (let index = pages.length; index < previousPageCount; index++) {
      await this.state.storage.delete(`chat_history_page_${index}`);
    }
    await this.state.storage.delete("chat_history");
    await this.state.storage.delete("session");
  }

  private paginateHistory(history: ServerMessage[]): ServerMessage[][] {
    const pages: ServerMessage[][] = [];
    let page: ServerMessage[] = [];
    for (const entry of history.slice(-500)) {
      const candidate = [...page, entry];
      if (page.length > 0 &&
          new TextEncoder().encode(JSON.stringify(candidate)).length >
              MAX_HISTORY_PAGE_BYTES) {
        pages.push(page);
        page = [entry];
      } else {
        page = candidate;
      }
    }
    if (page.length > 0) pages.push(page);
    return pages;
  }

  private trimDeliveredMessageIds(): void {
    while (this.session.deliveredMessageIds.size > 500) {
      const oldest = this.session.deliveredMessageIds.values().next().value as string | undefined;
      if (oldest === undefined) break;
      this.session.deliveredMessageIds.delete(oldest);
    }
  }

  private async cleanup(): Promise<void> {
    relayLog("room_cleanup", {
      reason: "session_end",
      connectedSockets: Number(Boolean(this.session.hostSocket)) +
        Number(Boolean(this.session.guestSocket)) +
        this.session.listenerSockets.size,
    });
    for (const connection of this.fishTts.values()) connection.close();
    this.fishTts.clear();
    if (this.session.hostSocket) {
      try { this.session.hostSocket.close(4000, "Session ended"); } catch {}
    }
    if (this.session.guestSocket) {
      try { this.session.guestSocket.close(4000, "Session ended"); } catch {}
    }
    for (const socket of this.session.listenerSockets.values()) {
      try { socket.close(4000, "Session ended"); } catch {}
    }
    this.session.hostSocket = null;
    this.session.guestSocket = null;
    this.session.listenerSockets.clear();
    await this.state.storage.deleteAll();
  }
}
