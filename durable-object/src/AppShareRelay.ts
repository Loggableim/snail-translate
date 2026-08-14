/** Ephemeral binary tunnel for a host-owned APK transfer.
 *
 * The Durable Object coordinates the two WebSocket peers only. APK bytes are
 * forwarded as binary frames and are never written to Durable Object storage
 * or R2. A transfer is scoped to one random, short-lived capability token.
 */
interface ShareMeta { version: string; bytes: number; expiresAt: number }

export class AppShareRelay implements DurableObject {
  private state: DurableObjectState;
  private meta: ShareMeta | null = null;
  private host: WebSocket | null = null;
  private guest: WebSocket | null = null;
  private transferred = 0;

  constructor(state: DurableObjectState, _env: unknown) {
    this.state = state;
    this.state.blockConcurrencyWhile(async () => {
      this.meta = await this.state.storage.get<ShareMeta>('meta') || null;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/init' && request.method === 'POST') {
      const candidate = await request.json<Partial<ShareMeta>>();
      const version = candidate?.version;
      const bytes = candidate?.bytes;
      const expiresAt = candidate?.expiresAt;
      if (typeof version !== 'string' || !version.trim() || version.length > 64 ||
          typeof bytes !== 'number' || !Number.isSafeInteger(bytes) || bytes <= 0 ||
          bytes > 1024 * 1024 * 1024 || typeof expiresAt !== 'number' ||
          !Number.isSafeInteger(expiresAt) ||
          expiresAt <= Date.now()) {
        return new Response('Invalid share metadata', { status: 400 });
      }
      this.meta = {
        version,
        bytes,
        expiresAt,
      };
      await this.state.storage.put('meta', this.meta);
      await this.state.storage.setAlarm(expiresAt);
      return Response.json({ ok: true });
    }
    if (!this.meta || this.meta.expiresAt <= Date.now()) {
      return new Response('Share expired', { status: 410 });
    }
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('WebSocket required', { status: 426 });
    }
    const role = url.searchParams.get('role') === 'host' ? 'host' : 'guest';
    if ((role === 'host' && this.isOpen(this.host)) ||
        (role === 'guest' && this.isOpen(this.guest))) {
      return new Response(`${role} already connected`, { status: 409 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    if (role === 'host') this.host = server; else this.guest = server;
    this.send(server, { type: 'connected', role, bytes: this.meta.bytes, version: this.meta.version });
    if (role === 'guest' && this.isOpen(this.host)) {
      this.send(this.host, { type: 'guest_connected' });
      this.send(server, { type: 'host_ready' });
    }
    server.addEventListener('message', (event) => this.onMessage(server, role, event.data));
    server.addEventListener('close', () => {
      if (role === 'host' && this.host === server) this.host = null;
      if (role === 'guest' && this.guest === server) this.guest = null;
      const peer = role === 'host' ? this.guest : this.host;
      if (peer) this.send(peer, { type: `${role}_disconnected` });
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private onMessage(sender: WebSocket, role: 'host' | 'guest', data: string | ArrayBuffer) {
    if (data instanceof ArrayBuffer) {
      if (role !== 'host' || !this.isOpen(this.guest) || !this.meta) return;
      if (this.transferred + data.byteLength > this.meta.bytes) {
        this.send(sender, { type: 'transfer_error', error: 'Transfer exceeds announced size' });
        return;
      }
      this.sendBinary(this.guest, data);
      this.transferred += data.byteLength;
      if (this.transferred === data.byteLength || this.transferred >= this.meta.bytes || this.transferred % (512 * 1024) < data.byteLength) {
        this.broadcast({ type: 'progress', transferred: this.transferred, bytes: this.meta.bytes });
      }
      return;
    }
    let message: any;
    try { message = JSON.parse(data); } catch { return; }
    if (role === 'guest' && message.type === 'guest_ready') {
      this.send(this.host, { type: 'guest_ready' });
    } else if (role === 'host' && (message.type === 'transfer_start' || message.type === 'transfer_complete' || message.type === 'transfer_error')) {
      this.broadcast(message);
    }
  }

  private isOpen(socket: WebSocket | null): socket is WebSocket {
    return socket !== null && socket.readyState === WebSocket.OPEN;
  }

  private send(socket: WebSocket | null, data: unknown) {
    if (this.isOpen(socket)) socket.send(JSON.stringify(data));
  }

  private sendBinary(socket: WebSocket | null, data: ArrayBuffer) {
    if (!this.isOpen(socket)) return;
    try { socket.send(data); } catch {}
  }
  private broadcast(data: unknown) { this.send(this.host, data); this.send(this.guest, data); }
  async alarm() {
    this.host?.close(4000, 'Share expired');
    this.guest?.close(4000, 'Share expired');
    this.host = null;
    this.guest = null;
    this.meta = null;
    this.transferred = 0;
    await this.state.storage.deleteAll();
  }
}
