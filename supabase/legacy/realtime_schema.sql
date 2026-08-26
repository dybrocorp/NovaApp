-- =====================================================================
--  ARCHIVO HISTÓRICO — NO EJECUTAR
-- =====================================================================
--  Este archivo fue reemplazado por:  supabase/novaapp_schema.sql
--
--  Se conserva sólo como referencia. Ejecutarlo puede:
--    * romper el esquema vigente (colisiones de tablas),
--    * reintroducir políticas RLS inseguras ya corregidas,
--    * en el caso de supabase_setup.sql, BORRAR mensajes y contactos
--      (empezaba con DROP TABLE ... CASCADE).
--
--  Para instalar o actualizar la base de datos:
--    Supabase → SQL Editor → pegar supabase/novaapp_schema.sql → Run
--
--  Detalle de la unificación y de los errores corregidos:
--    supabase/README.md
-- =====================================================================

-- realtime_schema.sql — FASE 0.5
--
-- Schema the realtime server needs when STORE_BACKEND=supabase.
-- Accessed over PostgREST with the SERVICE ROLE key, which lives ONLY in
-- the backend process (never in the app, never in a client bundle).
--
-- The app's existing migrations already create most product tables
-- (supabase_setup.sql, supabase_auth_migration.sql, supabase_groups_migration.sql).
-- This file documents ONLY what the realtime tier reads/writes.
--
-- SECURITY MODEL
--   * Every table below has RLS ENABLED and NO permissive client policy:
--     the anon/authenticated roles get nothing here. The service role
--     bypasses RLS by design, so the realtime server (and only it) can
--     read/write this data.
--   * The server stores OPAQUE E2EE ciphertext plus its own metadata.
--     It holds no key material and cannot decrypt any message.

-- =====================================================================
-- Directory (source of truth consulted for authorization)
-- =====================================================================

-- devices: identity keys + lifecycle status (written by identity_service.dart
-- / device_service.dart; read by the handshake; PATCHed on revocation).
-- Required columns:
--   device_id   text primary key
--   account_id  references accounts(account_id)
--   nova_id     text
--   public_key  text   -- base64 of the RAW 32-byte Ed25519 public key
--   status      text   -- 'pending' | 'active' | 'revoked'
CREATE UNIQUE INDEX IF NOT EXISTS devices_device_id_idx ON devices (device_id);

-- conversation_members: server-side membership truth (rooms + authz).
CREATE TABLE IF NOT EXISTS conversation_members (
  conversation_id text NOT NULL,
  account_id      text NOT NULL,
  PRIMARY KEY (conversation_id, account_id)
);
CREATE INDEX IF NOT EXISTS conversation_members_account_idx
  ON conversation_members (account_id);

-- contacts: relationship graph gating call.* signaling.
CREATE TABLE IF NOT EXISTS contacts (
  account_id text    NOT NULL,
  peer_id    text    NOT NULL,
  blocked    boolean NOT NULL DEFAULT false,
  PRIMARY KEY (account_id, peer_id)
);

-- presence_audience: privacy opt-in — who may see an account's presence.
CREATE TABLE IF NOT EXISTS presence_audience (
  subject_id text NOT NULL,
  viewer_id  text NOT NULL,
  PRIMARY KEY (subject_id, viewer_id)
);

-- =====================================================================
-- Realtime hot state
-- =====================================================================

-- messages: opaque E2EE envelopes + server metadata.
CREATE TABLE IF NOT EXISTS messages (
  message_id        text PRIMARY KEY,         -- client UUID v4 (idempotency key)
  conversation_id   text   NOT NULL,
  sender_account_id text   NOT NULL,
  sender_device_id  text   NOT NULL,
  ciphertext        text   NOT NULL,          -- opaque E2EE base64; NEVER plaintext
  header_type       text   NOT NULL,          -- e.g. 'dr.v1'
  server_seq        bigint NOT NULL,          -- ordering authority (per conversation)
  received_at_ms    bigint NOT NULL,
  client_ts_ms      bigint                    -- UI hint only; never trusted
);
CREATE INDEX IF NOT EXISTS messages_conversation_seq_idx
  ON messages (conversation_id, server_seq);

-- realtime_events: the append-only log that backs sync.response.
--
-- TWO counters, deliberately distinct (see src/store/realtime_store.ts):
--   server_seq — the MESSAGE sequence an event refers to;
--   log_seq    — the LOG sequence, i.e. the sync cursor.
-- A receipt for an old message gets a NEW log_seq, so a client that is
-- already past that message still receives the receipt on the next sync.
CREATE TABLE IF NOT EXISTS realtime_events (
  conversation_id text   NOT NULL,
  type            text   NOT NULL,            -- 'message.new'|'message.delivered'|'message.read'
  server_seq      bigint NOT NULL,
  log_seq         bigint NOT NULL,
  at_ms           bigint NOT NULL,
  payload         jsonb  NOT NULL,
  PRIMARY KEY (conversation_id, log_seq)
);
CREATE INDEX IF NOT EXISTS realtime_events_sync_idx
  ON realtime_events (conversation_id, log_seq);

-- conversation_cursors: atomic counters. PostgREST cannot express a safe
-- INCR, so both counters are minted by the RPCs below.
CREATE TABLE IF NOT EXISTS conversation_cursors (
  conversation_id text PRIMARY KEY,
  last_seq        bigint NOT NULL DEFAULT 0,
  last_log_seq    bigint NOT NULL DEFAULT 0
);

-- presence: last known status + last_seen (fan-out is audience-filtered).
CREATE TABLE IF NOT EXISTS presence (
  account_id   text PRIMARY KEY,
  status       text   NOT NULL,               -- 'online' | 'offline'
  last_seen_ms bigint NOT NULL
);

-- =====================================================================
-- Atomic sequence RPCs (called by SupabaseRealtimeStore)
-- =====================================================================
-- Both are atomic under concurrency: the INSERT ... ON CONFLICT DO UPDATE
-- takes a row lock, so two nodes can never mint the same value.

CREATE OR REPLACE FUNCTION nova_next_seq(p_conversation_id text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
AS $$
  INSERT INTO conversation_cursors (conversation_id, last_seq)
  VALUES (p_conversation_id, 1)
  ON CONFLICT (conversation_id)
  DO UPDATE SET last_seq = conversation_cursors.last_seq + 1
  RETURNING last_seq;
$$;

CREATE OR REPLACE FUNCTION nova_next_log_seq(p_conversation_id text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
AS $$
  INSERT INTO conversation_cursors (conversation_id, last_log_seq)
  VALUES (p_conversation_id, 1)
  ON CONFLICT (conversation_id)
  DO UPDATE SET last_log_seq = conversation_cursors.last_log_seq + 1
  RETURNING last_log_seq;
$$;

-- The RPCs must NOT be callable by app clients: only the backend.
REVOKE ALL ON FUNCTION nova_next_seq(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION nova_next_log_seq(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION nova_next_seq(text) TO service_role;
GRANT EXECUTE ON FUNCTION nova_next_log_seq(text) TO service_role;

-- =====================================================================
-- RLS: deny-by-default for every client role
-- =====================================================================
-- No policy is created for anon/authenticated => with RLS enabled these
-- tables are invisible to clients. The service role bypasses RLS, so the
-- realtime server keeps full access. Read paths for the app itself must
-- go through the realtime protocol, not through direct PostgREST reads.

ALTER TABLE conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts             ENABLE ROW LEVEL SECURITY;
ALTER TABLE presence_audience    ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages             ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_events      ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_cursors ENABLE ROW LEVEL SECURITY;
ALTER TABLE presence             ENABLE ROW LEVEL SECURITY;

-- Extra hardening: FORCE applies RLS even to the table owner.
ALTER TABLE messages        FORCE ROW LEVEL SECURITY;
ALTER TABLE realtime_events FORCE ROW LEVEL SECURITY;

REVOKE ALL ON conversation_members, contacts, presence_audience,
              messages, realtime_events, conversation_cursors, presence
  FROM anon, authenticated;
