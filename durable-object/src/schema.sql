-- Snail D1 Message Store Schema
-- Run: wrangler d1 execute snail-messages --file=./durable-object/src/schema.sql

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,                -- UUID v4
  room_id TEXT NOT NULL,              -- Session room ID
  sender_id TEXT,                     -- User ID of sender
  type TEXT NOT NULL DEFAULT 'chat',  -- 'chat' | 'sticker'
  text TEXT,                          -- Message text (chat only)
  source_lang TEXT DEFAULT 'de',
  target_lang TEXT DEFAULT 'en',
  asset_url TEXT,                     -- Sticker asset URL
  emoji TEXT,                         -- Sticker emoji
  pack_short_name TEXT,               -- Sticker pack name
  mime_type TEXT,                     -- Sticker MIME type
  sticker_id TEXT,                    -- Telegram sticker ID
  file_unique_id TEXT,                -- Telegram file unique ID
  is_animated INTEGER DEFAULT 0,
  is_video INTEGER DEFAULT 0,
  status TEXT DEFAULT 'delivered',    -- 'queued' | 'sent' | 'delivered' | 'read'
  created_at INTEGER NOT NULL,        -- Unix timestamp (ms)
  updated_at INTEGER NOT NULL         -- Unix timestamp (ms)
);

CREATE INDEX IF NOT EXISTS idx_messages_room_id ON messages(room_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_type ON messages(type);
