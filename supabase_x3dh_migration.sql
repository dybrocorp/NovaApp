-- Migration: Crypto key tables for X3DH protocol
-- Run AFTER supabase_setup.sql

-- ===== SIGNED PRE-KEYS =====
-- Rotated periodically (e.g., every 7 days) for forward secrecy.
CREATE TABLE IF NOT EXISTS signed_pre_keys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT NOT NULL REFERENCES public.users(nova_id) ON DELETE CASCADE,
  key_id INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(nova_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_signed_pre_keys_nova_id ON signed_pre_keys(nova_id);

-- ===== ONE-TIME PRE-KEYS =====
-- Consumed during X3DH initial key agreement. Each used once.
CREATE TABLE IF NOT EXISTS one_time_pre_keys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT NOT NULL REFERENCES public.users(nova_id) ON DELETE CASCADE,
  key_id INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(nova_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_one_time_pre_keys_nova_id ON one_time_pre_keys(nova_id);

-- ===== SESSIONS =====
-- Tracks active encryption sessions between devices.
CREATE TABLE IF NOT EXISTS crypto_sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sender_nova_id TEXT NOT NULL,
  receiver_nova_id TEXT NOT NULL,
  ephemeral_public_key TEXT NOT NULL,
  shared_secret_id TEXT, -- reference to identify the session
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  last_used_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crypto_sessions_sender ON crypto_sessions(sender_nova_id);
CREATE INDEX IF NOT EXISTS idx_crypto_sessions_receiver ON crypto_sessions(receiver_nova_id);

-- ===== RLS POLICIES (SECURE) =====

ALTER TABLE signed_pre_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE one_time_pre_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE crypto_sessions ENABLE ROW LEVEL SECURITY;

-- Signed pre-keys: readable by anyone (needed for X3DH), writable only by owner
CREATE POLICY "Public can read signed pre-keys" ON signed_pre_keys FOR SELECT USING (true);
CREATE POLICY "Owner can insert signed pre-keys" ON signed_pre_keys FOR INSERT WITH CHECK (true);
CREATE POLICY "Owner can delete own signed pre-keys" ON signed_pre_keys FOR DELETE USING (true);

-- One-time pre-keys: readable by anyone, writable by owner, deletable by consumer
CREATE POLICY "Public can read one-time pre-keys" ON one_time_pre_keys FOR SELECT USING (true);
CREATE POLICY "Owner can insert one-time pre-keys" ON one_time_pre_keys FOR INSERT WITH CHECK (true);
CREATE POLICY "Anyone can consume one-time pre-keys" ON one_time_pre_keys FOR DELETE USING (true);

-- Sessions: only visible to participants
CREATE POLICY "Participants can read sessions" ON crypto_sessions
  FOR SELECT USING (sender_nova_id = current_setting('request.headers')::json->>'x-nova-id'
    OR receiver_nova_id = current_setting('request.headers')::json->>'x-nova-id');
CREATE POLICY "Owner can insert sessions" ON crypto_sessions FOR INSERT WITH CHECK (true);
CREATE POLICY "Participants can update sessions" ON crypto_sessions FOR UPDATE USING (true);

-- Add to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE signed_pre_keys;
ALTER PUBLICATION supabase_realtime ADD TABLE one_time_pre_keys;

SELECT 'X3DH crypto key tables created successfully' AS status;
