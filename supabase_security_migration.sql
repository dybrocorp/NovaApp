-- Security Migration: Fix RLS policies for existing deployments
-- Run AFTER all other migrations
--
-- Problem: Old RLS policies used auth.uid()::text (UUID) against TEXT nova_id columns.
--          UUID format "550e8400-e29b-41d4-a716-446655440000" never matches Nova ID format "NOVA-XXXXXXXXX".
--          This caused either: (a) nobody can read/write, or (b) silent RLS bypass.
--
-- Fix: Create auth_nova_id() helper that maps auth.uid() UUID → nova_id TEXT,
--      then use it in all RLS policies.

-- ===== HELPER FUNCTION =====

CREATE OR REPLACE FUNCTION auth_nova_id()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT nova_id FROM public.users WHERE id = auth.uid() LIMIT 1;
$$;

-- ===== DROP ALL BROKEN POLICIES =====

-- Messages
DROP POLICY IF EXISTS "Users can read own sent messages" ON messages;
DROP POLICY IF EXISTS "Users can read own messages" ON messages;
DROP POLICY IF EXISTS "Users can insert own messages" ON messages;
DROP POLICY IF EXISTS "Users can update own message status" ON messages;

-- Contacts
DROP POLICY IF EXISTS "Users can read own contacts" ON contacts;
DROP POLICY IF EXISTS "Users can insert own contacts" ON contacts;
DROP POLICY IF EXISTS "Users can update own contacts" ON contacts;
DROP POLICY IF EXISTS "Users can delete own contacts" ON contacts;

-- Call history
DROP POLICY IF EXISTS "Users can read own call history" ON call_history;
DROP POLICY IF EXISTS "Users can insert own call history" ON call_history;
DROP POLICY IF EXISTS "Users can delete own call history" ON call_history;

-- Signed pre-keys
DROP POLICY IF EXISTS "Owner can insert signed pre-keys" ON signed_pre_keys;
DROP POLICY IF EXISTS "Owner can delete own signed pre-keys" ON signed_pre_keys;

-- One-time pre-keys
DROP POLICY IF EXISTS "Owner can insert one-time pre-keys" ON one_time_pre_keys;

-- Crypto sessions
DROP POLICY IF EXISTS "Owner can insert sessions" ON crypto_sessions;
DROP POLICY IF EXISTS "Participants can update sessions" ON crypto_sessions;
DROP POLICY IF EXISTS "Participants can read sessions" ON crypto_sessions;

-- Message reactions
DROP POLICY IF EXISTS "Owner can insert reactions" ON message_reactions;
DROP POLICY IF EXISTS "Owner can delete own reactions" ON message_reactions;

-- Typing indicators
DROP POLICY IF EXISTS "Owner can insert typing" ON typing_indicators;
DROP POLICY IF EXISTS "Owner can update own typing" ON typing_indicators;
DROP POLICY IF EXISTS "Owner can delete own typing" ON typing_indicators;

-- ===== CREATE SECURE POLICIES =====

-- Messages (sender_id TEXT = Nova ID, mapped via auth_nova_id())
CREATE POLICY "Users can read own messages" ON messages FOR SELECT USING (
  sender_id = auth_nova_id()
  OR sender_id IN (SELECT contact_id FROM contacts WHERE user_nova_id = auth_nova_id())
);
CREATE POLICY "Users can insert own messages" ON messages FOR INSERT WITH CHECK (
  sender_id = auth_nova_id()
);
CREATE POLICY "Users can update own message status" ON messages FOR UPDATE USING (
  sender_id = auth_nova_id()
);

-- Contacts (user_nova_id TEXT = Nova ID)
CREATE POLICY "Users can read own contacts" ON contacts FOR SELECT USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can insert own contacts" ON contacts FOR INSERT WITH CHECK (user_nova_id = auth_nova_id());
CREATE POLICY "Users can update own contacts" ON contacts FOR UPDATE USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can delete own contacts" ON contacts FOR DELETE USING (user_nova_id = auth_nova_id());

-- Call history (user_nova_id TEXT = Nova ID)
CREATE POLICY "Users can read own call history" ON call_history FOR SELECT USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can insert own call history" ON call_history FOR INSERT WITH CHECK (user_nova_id = auth_nova_id());
CREATE POLICY "Users can delete own call history" ON call_history FOR DELETE USING (user_nova_id = auth_nova_id());

-- Signed pre-keys (owner-only write)
CREATE POLICY "Owner can insert signed pre-keys" ON signed_pre_keys
  FOR INSERT WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own signed pre-keys" ON signed_pre_keys
  FOR DELETE USING (nova_id = auth_nova_id());

-- One-time pre-keys (owner-only insert)
CREATE POLICY "Owner can insert one-time pre-keys" ON one_time_pre_keys
  FOR INSERT WITH CHECK (nova_id = auth_nova_id());

-- Crypto sessions (participant access)
CREATE POLICY "Participants can read sessions" ON crypto_sessions
  FOR SELECT USING (
    sender_nova_id = auth_nova_id()
    OR receiver_nova_id = auth_nova_id()
  );
CREATE POLICY "Owner can insert sessions" ON crypto_sessions
  FOR INSERT WITH CHECK (sender_nova_id = auth_nova_id());
CREATE POLICY "Participants can update sessions" ON crypto_sessions
  FOR UPDATE USING (
    sender_nova_id = auth_nova_id()
    OR receiver_nova_id = auth_nova_id()
  );

-- Message reactions (owner-only write)
CREATE POLICY "Owner can insert reactions" ON message_reactions
  FOR INSERT WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own reactions" ON message_reactions
  FOR DELETE USING (nova_id = auth_nova_id());

-- Typing indicators (owner-only write)
CREATE POLICY "Owner can insert typing" ON typing_indicators
  FOR INSERT WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can update own typing" ON typing_indicators
  FOR UPDATE USING (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own typing" ON typing_indicators
  FOR DELETE USING (nova_id = auth_nova_id());

SELECT 'Security migration completed — all RLS policies fixed' AS status;
