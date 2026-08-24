-- realtime_schema.sql — FASE 0.5 PASO 5
-- Columns the realtime server needs when STORE_BACKEND=supabase
-- (PostgREST access with the SERVICE ROLE key; never shipped to clients).
--
-- The app's existing migrations already create most tables
-- (supabase_setup.sql, supabase_auth_migration.sql, supabase_groups_migration.sql).
-- This file documents ONLY the deltas the realtime tier reads/writes.
-- Review with RLS enabled for client roles; the service role bypasses RLS.

-- devices: identity keys + lifecycle status (written by identity_service.dart;
-- read by the handshake; PATCHed on revocation).
-- Required columns:
--   device_id   uuid/text primary key
--   account_id  references users(account_id)
--   nova_id     text
--   public_key  text          -- base64 of the RAW 32-byte Ed25519 public key
--   status      text          -- 'pending' | 'active' | 'revoked'
CREATE UNIQUE INDEX IF NOT EXISTS devices_device_id_idx ON devices (device_id);

-- conversation_members: server-side membership truth (rooms + authz).
-- Required columns: conversation_id, account_id (+ unique pair)

-- contacts: relationship graph for call.* signaling authorization.
-- Required columns: account_id, peer_id, blocked boolean

-- presence_audience: privacy opt-in — who may see an account's presence.
-- Required columns: subject_id, viewer_id (+ unique pair)

-- messages: the realtime server persists opaque E2EE envelopes + metadata.
-- Required columns (server-side):
CREATE TABLE IF NOT EXISTS messages (
  message_id       text PRIMARY KEY,          -- client UUID v4 (idempotency key)
  conversation_id  text NOT NULL,
  sender_account_id text NOT NULL,
  sender_device_id text NOT NULL,
  ciphertext       text NOT NULL,             -- opaque E2EE base64; NEVER plaintext
  header_type      text NOT NULL,             -- e.g. 'dr.v1'
  server_seq       bigint NOT NULL,           -- ordering authority (per conversation)
  received_at_ms   bigint NOT NULL,
  client_ts_ms     bigint                     -- UI hint only; never trusted
);
CREATE INDEX IF NOT EXISTS messages_conversation_seq_idx
  ON messages (conversation_id, server_seq);
