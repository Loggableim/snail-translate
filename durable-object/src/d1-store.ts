/**
 * Snail D1 Message Store — SQL-backed message persistence.
 *
 * Replaces the in-memory `chatHistory` array in SnailRelay with a
 * Cloudflare D1 database for durable, queryable message storage.
 */

export interface StoredMessage {
  id: string;
  room_id: string;
  sender_id: string | null;
  type: "chat" | "sticker";
  text: string | null;
  source_lang: string;
  target_lang: string;
  asset_url: string | null;
  emoji: string | null;
  pack_short_name: string | null;
  mime_type: string | null;
  sticker_id: string | null;
  file_unique_id: string | null;
  is_animated: number;
  is_video: number;
  status: "queued" | "sent" | "delivered" | "read";
  created_at: number;
  updated_at: number;
}

export interface ServerMessage {
  type: string;
  messageId?: string;
  senderId?: string;
  text?: string;
  sourceLang?: string;
  targetLang?: string;
  timestamp?: number;
  assetUrl?: string;
  emoji?: string;
  packShortName?: string;
  mimeType?: string;
  stickerId?: string;
  fileUniqueId?: string;
  isAnimated?: boolean;
  isVideo?: boolean;
  status?: string;
  [key: string]: unknown;
}

export class D1MessageStore {
  private db: D1Database;

  constructor(db: D1Database) {
    this.db = db;
  }

  /** Insert a new message. Returns true if inserted, false if duplicate. */
  async insert(msg: ServerMessage, roomId: string): Promise<boolean> {
    const now = Date.now();
    const id = msg.messageId || crypto.randomUUID();
    const type = msg.type === "sticker" ? "sticker" : "chat";

    try {
      await this.db
        .prepare(
          `INSERT INTO messages (
            id, room_id, sender_id, type, text,
            source_lang, target_lang,
            asset_url, emoji, pack_short_name, mime_type,
            sticker_id, file_unique_id, is_animated, is_video,
            status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .bind(
          id,
          roomId,
          msg.senderId || null,
          type,
          msg.text || null,
          msg.sourceLang || "de",
          msg.targetLang || "en",
          msg.assetUrl || null,
          msg.emoji || null,
          msg.packShortName || null,
          msg.mimeType || null,
          msg.stickerId || null,
          msg.fileUniqueId || null,
          msg.isAnimated ? 1 : 0,
          msg.isVideo ? 1 : 0,
          "delivered",
          msg.timestamp || now,
          now
        )
        .run();
      return true;
    } catch (err: unknown) {
      // SQLITE_CONSTRAINT_PRIMARYKEY — duplicate message
      if (
        err instanceof Error &&
        err.message.includes("UNIQUE constraint failed")
      ) {
        return false;
      }
      console.error("D1 insert error:", err);
      return false;
    }
  }

  /** Check if a message ID has already been stored. */
  async exists(messageId: string): Promise<boolean> {
    const result = await this.db
      .prepare("SELECT 1 FROM messages WHERE id = ? LIMIT 1")
      .bind(messageId)
      .first<{ 1: number }>();
    return result !== null;
  }

  /** Get chat history for a room, newest first, limited. */
  async getHistory(
    roomId: string,
    limit: number = 500
  ): Promise<ServerMessage[]> {
    const result = await this.db
      .prepare(
        `SELECT * FROM messages
         WHERE room_id = ?
         ORDER BY created_at DESC
         LIMIT ?`
      )
      .bind(roomId, limit)
      .all<StoredMessage>();

    if (!result.results) return [];

    // Return in chronological order (oldest first)
    return result.results.reverse().map((row) => this._toServerMessage(row));
  }

  /** Update message status (e.g. to 'read'). */
  async updateStatus(
    messageId: string,
    status: "queued" | "sent" | "delivered" | "read"
  ): Promise<void> {
    await this.db
      .prepare("UPDATE messages SET status = ?, updated_at = ? WHERE id = ?")
      .bind(status, Date.now(), messageId)
      .run();
  }

  /** Delete messages older than the given timestamp. */
  async pruneOlderThan(timestamp: number): Promise<number> {
    const result = await this.db
      .prepare("DELETE FROM messages WHERE created_at < ?")
      .bind(timestamp)
      .run();
    return result.meta?.changes || 0;
  }

  /** Count messages in a room. */
  async count(roomId: string): Promise<number> {
    const result = await this.db
      .prepare("SELECT COUNT(*) as cnt FROM messages WHERE room_id = ?")
      .bind(roomId)
      .first<{ cnt: number }>();
    return result?.cnt || 0;
  }

  // ── Private helpers ────────────────────────────────────────────────

  private _toServerMessage(row: StoredMessage): ServerMessage {
    const base: ServerMessage = {
      type: row.type,
      messageId: row.id,
      senderId: row.sender_id || undefined,
      sourceLang: row.source_lang,
      targetLang: row.target_lang,
      timestamp: row.created_at,
      status: row.status,
    };

    if (row.type === "chat") {
      base.text = row.text || "";
    } else {
      base.assetUrl = row.asset_url || "";
      base.emoji = row.emoji || "🙂";
      base.packShortName = row.pack_short_name || "snail-local";
      base.mimeType = row.mime_type || "image/webp";
      base.stickerId = row.sticker_id || undefined;
      base.fileUniqueId = row.file_unique_id || undefined;
      base.isAnimated = row.is_animated === 1;
      base.isVideo = row.is_video === 1;
    }

    return base;
  }
}
