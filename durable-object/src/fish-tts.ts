import { decode, encode } from "@msgpack/msgpack";

export interface FishTtsConfig {
  voiceId: string;
  model?: string;
  temperature?: number;
  topP?: number;
  speed?: number;
}

type AudioHandler = (audio: Uint8Array) => void;
type FinishHandler = () => void;

/** A warm Fish realtime TTS connection owned by one room/speaker direction. */
export class FishTtsConnection {
  private socket: WebSocket | null = null;
  private opening: Promise<void> | null = null;
  private config: FishTtsConfig | null = null;

  constructor(
    private readonly apiKey: string,
    private readonly onAudio: AudioHandler,
    private readonly onFinish: FinishHandler,
  ) {}

  async configure(config: FishTtsConfig): Promise<void> {
    const normalized: FishTtsConfig = {
      voiceId: config.voiceId.trim(),
      model: config.model?.trim() || "s2-pro",
      temperature: clamp(config.temperature ?? 0.7, 0, 1),
      topP: clamp(config.topP ?? 0.7, 0, 1),
      speed: clamp(config.speed ?? 1, 0.5, 2),
    };
    if (!normalized.voiceId) throw new Error("Fish voice ID is required");
    const changed = JSON.stringify(normalized) !== JSON.stringify(this.config);
    this.config = normalized;
    if (changed) this.close();
    await this.ensureOpen();
  }

  async sendText(text: string): Promise<void> {
    const normalized = text.trim();
    if (!normalized) return;
    await this.ensureOpen();
    this.send({ event: "text", text: `${normalized} ` });
  }

  async flush(): Promise<void> {
    await this.ensureOpen();
    this.send({ event: "flush" });
  }

  close(): void {
    try { this.socket?.close(1000, "Snail session closed"); } catch {}
    this.socket = null;
    this.opening = null;
  }

  private async ensureOpen(): Promise<void> {
    if (this.socket?.readyState === WebSocket.OPEN) return;
    if (!this.config) throw new Error("Fish TTS is not configured");
    this.opening ??= this.open();
    try {
      await this.opening;
    } finally {
      this.opening = null;
    }
  }

  private async open(): Promise<void> {
    const config = this.config!;
    const response = await fetch("https://api.fish.audio/v1/tts/live", {
      headers: {
        Upgrade: "websocket",
        Authorization: `Bearer ${this.apiKey}`,
        model: config.model!,
      },
    });
    const socket = response.webSocket;
    if (!socket) throw new Error(`Fish WebSocket upgrade failed (${response.status})`);
    socket.accept();
    socket.addEventListener("message", (event) => this.handleMessage(event.data));
    socket.addEventListener("close", () => {
      if (this.socket === socket) this.socket = null;
    });
    socket.addEventListener("error", () => {
      if (this.socket === socket) this.socket = null;
    });
    this.socket = socket;
    this.send({
      event: "start",
      request: {
        text: "",
        format: "pcm",
        sample_rate: 24000,
        chunk_length: 300,
        reference_id: config.voiceId,
        latency: "low",
        temperature: config.temperature,
        top_p: config.topP,
        prosody: { speed: config.speed },
      },
    });
  }

  private handleMessage(raw: string | ArrayBuffer): void {
    if (!(raw instanceof ArrayBuffer)) return;
    const message = decode(new Uint8Array(raw)) as Record<string, unknown>;
    const event = String(message.event ?? "");
    const audio = message.audio;
    if (audio instanceof Uint8Array && audio.length > 0) this.onAudio(audio);
    if (event === "finish" || event === "close") this.onFinish();
    if (event === "error") {
      console.error("Fish TTS error", message.message ?? "unknown error");
    }
  }

  private send(message: Record<string, unknown>): void {
    if (this.socket?.readyState !== WebSocket.OPEN) {
      throw new Error("Fish TTS socket is not open");
    }
    this.socket.send(encode(message));
  }
}

export type PcmFrameKind = "fish_tts" | "peer_pcm" | "fallback_pcm";
const PCM_FRAME_KIND: Record<PcmFrameKind, number> = { fish_tts: 1, peer_pcm: 2, fallback_pcm: 3 };

export function framePcm(audio: Uint8Array, sampleRate = 24000, kind: PcmFrameKind = "fish_tts"): Uint8Array {
  const framed = new Uint8Array(5 + audio.length);
  framed[0] = PCM_FRAME_KIND[kind];
  new DataView(framed.buffer).setUint32(1, sampleRate, true);
  framed.set(audio, 5);
  return framed;
}

export function framePcmEnd(kind: PcmFrameKind = "fish_tts"): Uint8Array {
  return framePcm(new Uint8Array(), 0, kind);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}
