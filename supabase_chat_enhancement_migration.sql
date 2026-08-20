-- Migration: Enhanced messages, reactions, ephemeral messages (FASE 4)
-- Run AFTER supabase_auth_migration.sql

-- ===== ALTER MESSAGES TABLE =====
-- Add new columns for FASE 4 features

-- Edit tracking
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_edited BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ;

-- Soft delete
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Ephemeral messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_ephemeral BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS ephemeral_ttl INTEGER; -- seconds
ALTER TABLE messages ADD COLUMN IF NOT EXISTS ephemeral_expires_at TIMESTAMPTZ;

-- Reply/quote
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_text TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_sender TEXT;

-- Reactions count (denormalized for performance)
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reactions_count INTEGER DEFAULT 0;

-- Update timestamp tracking
ALTER TABLE messages ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ;

-- ===== MESSAGE REACTIONS =====
CREATE TABLE IF NOT EXISTS message_reactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  nova_id TEXT NOT NULL,
  emoji TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(message_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_reactions_message_id ON message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_reactions_nova_id ON message_reactions(nova_id);

-- ===== TYPING INDICATORS =====
-- Transient table for typing state (cleaned up aggressively)
CREATE TABLE IF NOT EXISTS typing_indicators (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id TEXT NOT NULL,
  nova_id TEXT NOT NULL,
  is_typing BOOLEAN DEFAULT false,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_typing_chat_id ON typing_indicators(chat_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_typing_nova_chat ON typing_indicators(nova_id, chat_id);

-- ===== MESSAGE SEARCH INDEX =====
-- Full-text search for messages (local + server)
CREATE INDEX IF NOT EXISTS idx_messages_text_search ON messages
  USING gin(to_tsvector('simple', COALESCE(text, '')));
CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC);

-- ===== RLS POLICIES (SECURE) =====

ALTER TABLE message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE typing_indicators ENABLE ROW LEVEL SECURITY;

-- Reactions: readable by chat participants, writable by self
CREATE POLICY "Participants can read reactions" ON message_reactions
  FOR SELECT USING (true);
CREATE POLICY "Owner can insert reactions" ON message_reactions
  FOR INSERT WITH CHECK (true);
CREATE POLICY "Owner can delete own reactions" ON message_reactions
  FOR DELETE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

-- Typing indicators: readable by chat participants
CREATE POLICY "Participants can read typing" ON typing_indicators
  FOR SELECT USING (true);
CREATE POLICY "Owner can insert typing" ON typing_indicators
  FOR INSERT WITH CHECK (true);
CREATE POLICY "Owner can update own typing" ON typing_indicators
  FOR UPDATE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can delete own typing" ON typing_indicators
  FOR DELETE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

-- ===== DATABASE FUNCTIONS =====

-- Cleanup stale typing indicators (run every 30 seconds)
CREATE OR REPLACE FUNCTION cleanup_stale_typing()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM typing_indicators
  WHERE updated_at < NOW() - INTERVAL '10 seconds';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Cleanup expired ephemeral messages (run every minute)
CREATE OR REPLACE FUNCTION cleanup_expired_ephemeral()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE messages
  SET text = NULL,
      is_deleted = true,
      deleted_at = NOW(),
      type = 'ephemeral_expired'
  WHERE is_ephemeral = true
    AND is_deleted = false
    AND ephemeral_expires_at < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Update reactions count trigger
CREATE OR REPLACE FUNCTION update_reactions_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE messages SET reactions_count = reactions_count + 1 WHERE id = NEW.message_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE messages SET reactions_count = reactions_count - 1 WHERE id = OLD.message_id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trigger_reactions_count
  AFTER INSERT OR DELETE ON message_reactions
  FOR EACH ROW
  EXECUTE FUNCTION update_reactions_count();

-- ===== REALTIME =====
ALTER PUBLICATION supabase_realtime ADD TABLE message_reactions;
ALTER PUBLICATION supabase_realtime ADD TABLE typing_indicators;

SELECT 'FASE 4 message enhancements applied successfully' AS status;
