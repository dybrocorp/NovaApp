-- =====================================================================
--  NOVAAPP — ESQUEMA COMPLETO DE SUPABASE (archivo único)
-- =====================================================================
--
--  Uso:  Supabase → SQL Editor → pegar todo → Run
--
--  Unifica y REEMPLAZA a los seis archivos anteriores:
--    supabase_setup.sql
--    supabase_x3dh_migration.sql
--    supabase_auth_migration.sql
--    supabase_chat_enhancement_migration.sql
--    supabase_groups_migration.sql
--    supabase_security_migration.sql
--  más el esquema del tier realtime (server/sql/realtime_schema.sql).
--
--  PROPIEDADES
--  -----------
--  * IDEMPOTENTE: se puede ejecutar varias veces sin error. Todo usa
--    IF NOT EXISTS / CREATE OR REPLACE / DROP ... IF EXISTS antes de
--    crear políticas y triggers.
--  * NO DESTRUCTIVO: no borra ninguna tabla ni dato. (El bloque de
--    reinicio total está comentado al final, §15.)
--  * ORDENADO POR DEPENDENCIAS: extensiones → tablas → funciones →
--    triggers → RLS → publicación realtime → permisos.
--
--  CORRECCIONES APLICADAS AL UNIFICAR (detalle en §0.2)
--  ----------------------------------------------------
--  1. `auth_challenge_request` usaba el tipo `BYTES`, que NO EXISTE en
--     PostgreSQL: la función fallaba siempre en ejecución. → `bytea`.
--  2. Colisión de la tabla `messages` entre el chat de la app y el tier
--     realtime (esquemas incompatibles). → El realtime usa `realtime_*`.
--  3. Colisión de la tabla `contacts` (app: user_nova_id/contact_id;
--     realtime: account_id/peer_id/blocked). → Separadas.
--  4. `devices` carecía de `account_id` y `public_key`, necesarias para
--     el handshake Ed25519 del realtime. → Columnas añadidas.
--  5. Triggers y políticas sin DROP previo: fallaban al reejecutar.
--  6. `ALTER PUBLICATION ... ADD TABLE` fallaba si la tabla ya estaba
--     publicada. → Bucle idempotente (§13).
--  7. Tablas usadas por la app pero que ningún archivo creaba:
--     calls, call_participants, device_approvals, rate_limits,
--     registration_attempts, user_settings. → Creadas (§7, §8).
--  8. La app llama al RPC `check_rate_limit`, que no existía. → §10.
--
--  Última actualización: 2026-08-25
-- =====================================================================


-- =====================================================================
--  §0.1  NOTA DE SEGURIDAD
-- =====================================================================
--  * Las tablas del tier realtime (§9) son DENY-BY-DEFAULT: tienen RLS
--    activo y NINGUNA política para anon/authenticated. Sólo el
--    service_role (que omite RLS por diseño) las alcanza. Ese rol vive
--    exclusivamente en el backend: nunca en la app, nunca en un bundle.
--  * El servidor realtime sólo guarda ciphertext opaco + metadata. No
--    posee material de claves y no puede descifrar mensajes.
--  * `auth_nova_id()` traduce auth.uid() (UUID) → nova_id (TEXT). Es la
--    base de casi todas las políticas: comparar un UUID contra un
--    nova_id TEXT nunca coincide y era el origen de las políticas rotas.
-- =====================================================================


-- =====================================================================
--  §1  EXTENSIONES
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_bytes()


-- =====================================================================
--  §1.4  COMPROBACIÓN PREVIA DE TIPOS INCOMPATIBLES
-- =====================================================================
--  §1.5 puede AÑADIR columnas que falten, pero no puede convertir el
--  tipo de una que ya existe. Si un despliegue antiguo dejó, por
--  ejemplo, `devices.device_id` como UUID en vez de TEXT, el script
--  moriría 300 líneas más abajo con un error críptico:
--
--      ERROR: foreign key constraint "sessions_device_id_fkey"
--             cannot be implemented
--
--  Mejor abortar aquí, con un mensaje que diga qué arreglar y cómo.
--  Convertir el tipo exige decidir qué hacer con los datos existentes,
--  así que NO se hace automáticamente.
-- =====================================================================

DO $precheck$
DECLARE
  r        RECORD;
  v_bad    TEXT := '';
BEGIN
  FOR r IN
    SELECT c.table_name, c.column_name, c.data_type, e.expected
    FROM (VALUES
      ('devices',          'device_id',        'text'),
      ('devices',          'nova_id',          'text'),
      ('devices',          'account_id',       'text'),
      ('devices',          'public_key',       'text'),
      ('sessions',         'device_id',        'text'),
      ('device_approvals', 'device_id',        'text'),
      ('accounts',         'nova_id',          'text'),
      ('realtime_messages','message_id',       'text'),
      ('realtime_messages','sender_device_id', 'text')
    ) AS e(tbl, col, expected)
    JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name   = e.tbl
     AND c.column_name  = e.col
    WHERE c.data_type <> e.expected
  LOOP
    v_bad := v_bad || format(
      E'\n  - public.%s.%s es %s y debe ser %s.',
      r.table_name, r.column_name, r.data_type, upper(r.expected)
    );
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION
      E'NovaApp: hay columnas con un tipo incompatible:%\n\nEste script no las convierte automáticamente porque habría que decidir qué hacer con los datos existentes. Corrígelas a mano (por ejemplo: ALTER TABLE public.devices ALTER COLUMN device_id TYPE TEXT USING device_id::text;) y vuelve a ejecutar.',
      v_bad;
  END IF;
END
$precheck$;


-- =====================================================================
--  §1.5  RECONCILIACIÓN DE COLUMNAS (reparación de despliegues previos)
-- =====================================================================
--  POR QUÉ EXISTE ESTE BLOQUE
--  --------------------------
--  `CREATE TABLE IF NOT EXISTS` NO modifica una tabla que ya existe:
--  si el proyecto tiene una versión ANTIGUA de `devices`, `sessions`,
--  `device_approvals`, etc., la sentencia se salta en silencio y la
--  tabla conserva sus columnas viejas. Los `CREATE INDEX` y las
--  `CREATE POLICY` posteriores sí se ejecutan y fallan con:
--
--      ERROR: 42703: column "device_id" does not exist
--
--  Este bloque añade, de forma IDEMPOTENTE y NO DESTRUCTIVA, cualquier
--  columna declarada en §2–§9 que falte en una tabla que YA EXISTE. No
--  borra columnas, no cambia tipos y no toca datos: sólo hace
--  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`.
--
--  Va AQUÍ, antes de §2, y no al final, porque los `CREATE INDEX` que
--  fallan están intercalados con los `CREATE TABLE` (p. ej.
--  `devices_device_id_idx` justo después de crear `devices`). Un bloque
--  de reparación colocado al final nunca llegaría a ejecutarse.
--  Las tablas que todavía no existen no se tocan: las crea §2–§9 ya
--  completas.
--
--  Las cláusulas NOT NULL se omiten a propósito: añadir NOT NULL a una
--  tabla con filas existentes fallaría. Los DEFAULT sí se conservan.
--
--  Si una columna existe pero con OTRO tipo (p. ej. `device_id UUID`
--  en vez de `TEXT`), este bloque no la toca: eso requiere una
--  migración de datos manual y deliberada. El §16 la detecta y avisa.
-- =====================================================================

DO $reconcile$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
    ('users',                         'id',                    'UUID'),
    ('users',                         'email',                 'TEXT'),
    ('users',                         'name',                  'TEXT'),
    ('users',                         'nova_id',               'TEXT'),
    ('users',                         'display_name',          'TEXT'),
    ('users',                         'avatar_url',            'TEXT'),
    ('users',                         'public_key',            'TEXT'),
    ('users',                         'x25519_identity_key',   'TEXT'),
    ('users',                         'fcm_token',             'TEXT'),
    ('users',                         'privacy_level',         'TEXT DEFAULT ''anyone'''),
    ('users',                         'is_online',             'BOOLEAN DEFAULT false'),
    ('users',                         'last_seen',             'TIMESTAMPTZ'),
    ('users',                         'reports_count',         'INTEGER DEFAULT 0'),
    ('users',                         'is_shadowbanned',       'BOOLEAN DEFAULT false'),
    ('users',                         'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('users',                         'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('accounts',                      'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('accounts',                      'nova_id',               'TEXT'),
    ('accounts',                      'pin_hash',              'TEXT'),
    ('accounts',                      'pin_salt',              'TEXT'),
    ('accounts',                      'display_name',          'TEXT DEFAULT ''Usuario'''),
    ('accounts',                      'avatar_url',            'TEXT'),
    ('accounts',                      'phone_number',          'TEXT'),
    ('accounts',                      'is_verified',           'BOOLEAN DEFAULT false'),
    ('accounts',                      'is_locked',             'BOOLEAN DEFAULT false'),
    ('accounts',                      'failed_login_attempts', 'INTEGER DEFAULT 0'),
    ('accounts',                      'locked_until',          'TIMESTAMPTZ'),
    ('accounts',                      'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('accounts',                      'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('devices',                       'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('devices',                       'nova_id',               'TEXT'),
    ('devices',                       'account_id',            'TEXT'),
    ('devices',                       'device_id',             'TEXT'),
    ('devices',                       'device_name',           'TEXT'),
    ('devices',                       'platform',              'TEXT'),
    ('devices',                       'os_version',            'TEXT'),
    ('devices',                       'app_version',           'TEXT'),
    ('devices',                       'push_token',            'TEXT'),
    ('devices',                       'public_key',            'TEXT'),
    ('devices',                       'status',                'TEXT DEFAULT ''active'''),
    ('devices',                       'last_seen_at',          'TIMESTAMPTZ DEFAULT NOW()'),
    ('devices',                       'registered_at',         'TIMESTAMPTZ DEFAULT NOW()'),
    ('devices',                       'revoked_at',            'TIMESTAMPTZ'),
    ('sessions',                      'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('sessions',                      'nova_id',               'TEXT'),
    ('sessions',                      'device_id',             'TEXT'),
    ('sessions',                      'jwt_token_hash',        'TEXT'),
    ('sessions',                      'ip_address',            'TEXT'),
    ('sessions',                      'user_agent',            'TEXT'),
    ('sessions',                      'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('sessions',                      'last_active_at',        'TIMESTAMPTZ DEFAULT NOW()'),
    ('sessions',                      'expires_at',            'TIMESTAMPTZ'),
    ('auth_challenges',               'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('auth_challenges',               'nova_id',               'TEXT'),
    ('auth_challenges',               'challenge',             'TEXT'),
    ('auth_challenges',               'challenge_id',          'TEXT'),
    ('auth_challenges',               'expires_at',            'TIMESTAMPTZ'),
    ('auth_challenges',               'used',                  'BOOLEAN DEFAULT false'),
    ('auth_challenges',               'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('signed_pre_keys',               'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('signed_pre_keys',               'nova_id',               'TEXT'),
    ('signed_pre_keys',               'key_id',                'INTEGER'),
    ('signed_pre_keys',               'public_key',            'TEXT'),
    ('signed_pre_keys',               'signature',             'TEXT'),
    ('signed_pre_keys',               'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('one_time_pre_keys',             'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('one_time_pre_keys',             'nova_id',               'TEXT'),
    ('one_time_pre_keys',             'key_id',                'INTEGER'),
    ('one_time_pre_keys',             'public_key',            'TEXT'),
    ('one_time_pre_keys',             'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('crypto_sessions',               'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('crypto_sessions',               'sender_nova_id',        'TEXT'),
    ('crypto_sessions',               'receiver_nova_id',      'TEXT'),
    ('crypto_sessions',               'ephemeral_public_key',  'TEXT'),
    ('crypto_sessions',               'shared_secret_id',      'TEXT'),
    ('crypto_sessions',               'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('crypto_sessions',               'last_used_at',          'TIMESTAMPTZ DEFAULT NOW()'),
    ('messages',                      'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('messages',                      'chat_id',               'TEXT'),
    ('messages',                      'sender_id',             'TEXT'),
    ('messages',                      'text',                  'TEXT'),
    ('messages',                      'media_url',             'TEXT'),
    ('messages',                      'type',                  'TEXT DEFAULT ''text'''),
    ('messages',                      'timestamp',             'TEXT'),
    ('messages',                      'is_me',                 'INTEGER DEFAULT 0'),
    ('messages',                      'status',                'TEXT DEFAULT ''sent'''),
    ('messages',                      'poll_data',             'JSONB'),
    ('messages',                      'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('contacts',                      'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('contacts',                      'user_nova_id',          'TEXT'),
    ('contacts',                      'contact_id',            'TEXT'),
    ('contacts',                      'contact_name',          'TEXT'),
    ('contacts',                      'verification_level',    'TEXT DEFAULT ''level1'''),
    ('contacts',                      'last_message',          'TEXT'),
    ('contacts',                      'last_message_time',     'TIMESTAMPTZ'),
    ('contacts',                      'is_archived',           'INTEGER DEFAULT 0'),
    ('contacts',                      'is_blocked',            'INTEGER DEFAULT 0'),
    ('contacts',                      'is_favorite',           'INTEGER DEFAULT 0'),
    ('contacts',                      'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('contacts',                      'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('call_history',                  'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('call_history',                  'user_nova_id',          'TEXT'),
    ('call_history',                  'contact_id',            'TEXT'),
    ('call_history',                  'contact_name',          'TEXT'),
    ('call_history',                  'call_type',             'TEXT'),
    ('call_history',                  'direction',             'TEXT'),
    ('call_history',                  'duration',              'INTEGER'),
    ('call_history',                  'timestamp',             'TIMESTAMPTZ DEFAULT NOW()'),
    ('call_history',                  'status',                'TEXT DEFAULT ''completed'''),
    ('reports',                       'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('reports',                       'reporter_id',           'UUID'),
    ('reports',                       'reported_id',           'UUID'),
    ('reports',                       'reason',                'TEXT'),
    ('reports',                       'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('blocked_users',                 'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('blocked_users',                 'blocker_id',            'UUID'),
    ('blocked_users',                 'blocked_id',            'UUID'),
    ('blocked_users',                 'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('message_reactions',             'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('message_reactions',             'message_id',            'UUID'),
    ('message_reactions',             'nova_id',               'TEXT'),
    ('message_reactions',             'emoji',                 'TEXT'),
    ('message_reactions',             'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('typing_indicators',             'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('typing_indicators',             'chat_id',               'TEXT'),
    ('typing_indicators',             'nova_id',               'TEXT'),
    ('typing_indicators',             'is_typing',             'BOOLEAN DEFAULT false'),
    ('typing_indicators',             'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('groups',                        'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('groups',                        'name',                  'TEXT'),
    ('groups',                        'description',           'TEXT'),
    ('groups',                        'avatar_url',            'TEXT'),
    ('groups',                        'creator_nova_id',       'TEXT'),
    ('groups',                        'is_active',             'BOOLEAN DEFAULT true'),
    ('groups',                        'member_count',          'INTEGER DEFAULT 1'),
    ('groups',                        'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('groups',                        'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('group_members',                 'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('group_members',                 'group_id',              'UUID'),
    ('group_members',                 'nova_id',               'TEXT'),
    ('group_members',                 'role',                  'TEXT DEFAULT ''member'''),
    ('group_members',                 'display_name',          'TEXT'),
    ('group_members',                 'is_muted',              'BOOLEAN DEFAULT false'),
    ('group_members',                 'joined_at',             'TIMESTAMPTZ DEFAULT NOW()'),
    ('group_messages',                'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('group_messages',                'group_id',              'UUID'),
    ('group_messages',                'sender_id',             'TEXT'),
    ('group_messages',                'text',                  'TEXT'),
    ('group_messages',                'type',                  'TEXT DEFAULT ''text'''),
    ('group_messages',                'is_edited',             'BOOLEAN DEFAULT false'),
    ('group_messages',                'edited_at',             'TIMESTAMPTZ'),
    ('group_messages',                'is_deleted',            'BOOLEAN DEFAULT false'),
    ('group_messages',                'deleted_at',            'TIMESTAMPTZ'),
    ('group_messages',                'reply_to_id',           'UUID'),
    ('group_messages',                'reactions_count',       'INTEGER DEFAULT 0'),
    ('group_messages',                'mentions',              'TEXT[]'),
    ('group_messages',                'timestamp',             'TIMESTAMPTZ DEFAULT NOW()'),
    ('group_messages',                'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('group_invites',                 'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('group_invites',                 'group_id',              'UUID'),
    ('group_invites',                 'token',                 'TEXT'),
    ('group_invites',                 'created_by',            'TEXT'),
    ('group_invites',                 'max_uses',              'INTEGER DEFAULT 50'),
    ('group_invites',                 'uses',                  'INTEGER DEFAULT 0'),
    ('group_invites',                 'expires_at',            'TIMESTAMPTZ'),
    ('group_invites',                 'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('group_sender_keys',             'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('group_sender_keys',             'group_id',              'UUID'),
    ('group_sender_keys',             'nova_id',               'TEXT'),
    ('group_sender_keys',             'encrypted_key',         'TEXT'),
    ('group_sender_keys',             'key_version',           'INTEGER DEFAULT 0'),
    ('group_sender_keys',             'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('pinned_messages',               'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('pinned_messages',               'group_id',              'UUID'),
    ('pinned_messages',               'message_id',            'UUID'),
    ('pinned_messages',               'pinned_by',             'TEXT'),
    ('pinned_messages',               'pinned_at',             'TIMESTAMPTZ DEFAULT NOW()'),
    ('calls',                         'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('calls',                         'caller_nova_id',        'TEXT'),
    ('calls',                         'callee_nova_id',        'TEXT'),
    ('calls',                         'group_id',              'UUID'),
    ('calls',                         'call_type',             'TEXT DEFAULT ''audio'''),
    ('calls',                         'status',                'TEXT DEFAULT ''ringing'''),
    ('calls',                         'started_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('calls',                         'answered_at',           'TIMESTAMPTZ'),
    ('calls',                         'ended_at',              'TIMESTAMPTZ'),
    ('calls',                         'duration',              'INTEGER'),
    ('calls',                         'end_reason',            'TEXT'),
    ('calls',                         'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('call_participants',             'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('call_participants',             'call_id',               'UUID'),
    ('call_participants',             'nova_id',               'TEXT'),
    ('call_participants',             'joined_at',             'TIMESTAMPTZ DEFAULT NOW()'),
    ('call_participants',             'left_at',               'TIMESTAMPTZ'),
    ('call_participants',             'is_muted',              'BOOLEAN DEFAULT false'),
    ('call_participants',             'has_video',             'BOOLEAN DEFAULT false'),
    ('user_settings',                 'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('user_settings',                 'nova_id',               'TEXT'),
    ('user_settings',                 'last_seen_visibility',  'TEXT DEFAULT ''contacts'''),
    ('user_settings',                 'profile_photo_privacy', 'TEXT DEFAULT ''contacts'''),
    ('user_settings',                 'read_receipts_enabled', 'BOOLEAN DEFAULT true'),
    ('user_settings',                 'typing_indicators',     'BOOLEAN DEFAULT true'),
    ('user_settings',                 'notifications_enabled', 'BOOLEAN DEFAULT true'),
    ('user_settings',                 'settings_json',         'JSONB DEFAULT ''{}''::jsonb'),
    ('user_settings',                 'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('user_settings',                 'updated_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('device_approvals',              'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('device_approvals',              'nova_id',               'TEXT'),
    ('device_approvals',              'device_id',             'TEXT'),
    ('device_approvals',              'requesting_device',     'TEXT'),
    ('device_approvals',              'approving_device',      'TEXT'),
    ('device_approvals',              'status',                'TEXT DEFAULT ''pending'''),
    ('device_approvals',              'approval_code',         'TEXT'),
    ('device_approvals',              'expires_at',            'TIMESTAMPTZ'),
    ('device_approvals',              'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('device_approvals',              'resolved_at',           'TIMESTAMPTZ'),
    ('rate_limits',                   'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('rate_limits',                   'identifier',            'TEXT'),
    ('rate_limits',                   'action',                'TEXT'),
    ('rate_limits',                   'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('registration_attempts',         'id',                    'UUID DEFAULT uuid_generate_v4()'),
    ('registration_attempts',         'ip_address',            'TEXT'),
    ('registration_attempts',         'device_id',             'TEXT'),
    ('registration_attempts',         'nova_id',               'TEXT'),
    ('registration_attempts',         'successful',            'BOOLEAN DEFAULT false'),
    ('registration_attempts',         'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('realtime_conversation_members', 'conversation_id',       'TEXT'),
    ('realtime_conversation_members', 'account_id',            'TEXT'),
    ('realtime_conversation_members', 'created_at',            'TIMESTAMPTZ DEFAULT NOW()'),
    ('realtime_contacts',             'account_id',            'TEXT'),
    ('realtime_contacts',             'peer_id',               'TEXT'),
    ('realtime_contacts',             'blocked',               'BOOLEAN DEFAULT false'),
    ('realtime_presence_audience',    'subject_id',            'TEXT'),
    ('realtime_presence_audience',    'viewer_id',             'TEXT'),
    ('realtime_messages',             'message_id',            'TEXT'),
    ('realtime_messages',             'conversation_id',       'TEXT'),
    ('realtime_messages',             'sender_account_id',     'TEXT'),
    ('realtime_messages',             'sender_device_id',      'TEXT'),
    ('realtime_messages',             'ciphertext',            'TEXT'),
    ('realtime_messages',             'header_type',           'TEXT'),
    ('realtime_messages',             'server_seq',            'BIGINT'),
    ('realtime_messages',             'received_at_ms',        'BIGINT'),
    ('realtime_messages',             'client_ts_ms',          'BIGINT'),
    ('realtime_events',               'conversation_id',       'TEXT'),
    ('realtime_events',               'type',                  'TEXT'),
    ('realtime_events',               'server_seq',            'BIGINT'),
    ('realtime_events',               'log_seq',               'BIGINT'),
    ('realtime_events',               'at_ms',                 'BIGINT'),
    ('realtime_events',               'payload',               'JSONB'),
    ('realtime_cursors',              'conversation_id',       'TEXT'),
    ('realtime_cursors',              'last_seq',              'BIGINT DEFAULT 0'),
    ('realtime_cursors',              'last_log_seq',          'BIGINT DEFAULT 0'),
    ('realtime_presence',             'account_id',            'TEXT'),
    ('realtime_presence',             'status',                'TEXT'),
    ('realtime_presence',             'last_seen_ms',          'BIGINT')
    ) AS t(tbl, col, coldef)
  LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = r.tbl AND table_type = 'BASE TABLE'
    ) THEN
      EXECUTE format(
        'ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS %I %s',
        r.tbl, r.col, r.coldef
      );
    END IF;
  END LOOP;
END
$reconcile$;


-- =====================================================================
--  §2  IDENTIDAD: users, accounts, devices, sessions, auth_challenges
-- =====================================================================

-- ---------------------------------------------------------------------
-- users — perfil público + claves de identidad (Ed25519 y X25519).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.users (
  id                  UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email               TEXT,
  name                TEXT,
  nova_id             TEXT UNIQUE,           -- identificador público
  display_name        TEXT,
  avatar_url          TEXT,
  public_key          TEXT,                  -- Ed25519 (verificación de firmas)
  x25519_identity_key TEXT,                  -- X25519 (DH / X3DH)
  fcm_token           TEXT,
  privacy_level       TEXT    DEFAULT 'anyone',   -- 'anyone' | 'qr_only'
  is_online           BOOLEAN DEFAULT false,
  last_seen           TIMESTAMPTZ,
  reports_count       INTEGER DEFAULT 0,
  is_shadowbanned     BOOLEAN DEFAULT false,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW()
);

-- Columnas añadidas por migraciones posteriores (despliegues antiguos).
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS reports_count       INTEGER DEFAULT 0;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_shadowbanned     BOOLEAN DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS x25519_identity_key TEXT;

CREATE INDEX IF NOT EXISTS idx_users_nova_id      ON public.users(nova_id);
CREATE INDEX IF NOT EXISTS idx_users_display_name ON public.users(display_name);

-- ---------------------------------------------------------------------
-- accounts — cuenta Nova ID con PIN (hash + salt server-side).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accounts (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id               TEXT UNIQUE NOT NULL,
  pin_hash              TEXT NOT NULL,
  pin_salt              TEXT NOT NULL,
  display_name          TEXT NOT NULL DEFAULT 'Usuario',
  avatar_url            TEXT,
  phone_number          TEXT,                -- opcional, sólo recuperación
  is_verified           BOOLEAN DEFAULT false,
  is_locked             BOOLEAN DEFAULT false,
  failed_login_attempts INTEGER DEFAULT 0,
  locked_until          TIMESTAMPTZ,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- devices — un registro por dispositivo instalado.
--
-- `account_id` y `public_key` son OBLIGATORIAS para el handshake del
-- realtime: el servidor verifica la firma Ed25519 contra la clave
-- REGISTRADA aquí, nunca contra una clave enviada por el cliente.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id        TEXT NOT NULL REFERENCES accounts(nova_id) ON DELETE CASCADE,
  account_id     TEXT,                       -- identificador de cuenta del realtime
  device_id      TEXT UNIQUE NOT NULL,
  device_name    TEXT NOT NULL,
  platform       TEXT NOT NULL,              -- android | ios | web
  os_version     TEXT,
  app_version    TEXT,
  push_token     TEXT,
  public_key     TEXT,                       -- Ed25519 RAW de 32 B en base64
  status         TEXT DEFAULT 'active',      -- active | revoked | pending
  last_seen_at   TIMESTAMPTZ DEFAULT NOW(),
  registered_at  TIMESTAMPTZ DEFAULT NOW(),
  revoked_at     TIMESTAMPTZ
);

ALTER TABLE devices ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS public_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS devices_device_id_idx ON devices(device_id);
CREATE INDEX IF NOT EXISTS idx_devices_nova_id     ON devices(nova_id);
CREATE INDEX IF NOT EXISTS idx_devices_account_id  ON devices(account_id);
CREATE INDEX IF NOT EXISTS idx_devices_status      ON devices(status);

-- ---------------------------------------------------------------------
-- sessions — sesiones JWT por dispositivo (visibles para el usuario).
-- El realtime mantiene además su propia sesión efímera en memoria.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id        TEXT NOT NULL REFERENCES accounts(nova_id)  ON DELETE CASCADE,
  device_id      TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
  jwt_token_hash TEXT NOT NULL,
  ip_address     TEXT,
  user_agent     TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  last_active_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at     TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_nova_id   ON sessions(nova_id);
CREATE INDEX IF NOT EXISTS idx_sessions_device_id ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires   ON sessions(expires_at);

-- ---------------------------------------------------------------------
-- auth_challenges — challenge/response de login (uso único, TTL corto).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auth_challenges (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id      TEXT NOT NULL REFERENCES accounts(nova_id) ON DELETE CASCADE,
  challenge    TEXT NOT NULL,
  challenge_id TEXT UNIQUE NOT NULL,
  expires_at   TIMESTAMPTZ NOT NULL,
  used         BOOLEAN DEFAULT false,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_auth_challenges_nova_id ON auth_challenges(nova_id);
CREATE INDEX IF NOT EXISTS idx_auth_challenges_id      ON auth_challenges(challenge_id);


-- =====================================================================
--  §3  CRIPTOGRAFÍA X3DH: pre-claves y sesiones
-- =====================================================================

-- Signed Pre-Key (SPK), rotada periódicamente.
CREATE TABLE IF NOT EXISTS signed_pre_keys (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id    TEXT NOT NULL REFERENCES public.users(nova_id) ON DELETE CASCADE,
  key_id     INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  signature  TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(nova_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_signed_pre_keys_nova_id ON signed_pre_keys(nova_id);

-- One-Time Pre-Keys (OPK): se consumen una sola vez.
CREATE TABLE IF NOT EXISTS one_time_pre_keys (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id    TEXT NOT NULL REFERENCES public.users(nova_id) ON DELETE CASCADE,
  key_id     INTEGER NOT NULL,
  public_key TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(nova_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_one_time_pre_keys_nova_id ON one_time_pre_keys(nova_id);

-- Sesiones de cifrado entre dispositivos (metadata, nunca secretos).
CREATE TABLE IF NOT EXISTS crypto_sessions (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sender_nova_id       TEXT NOT NULL,
  receiver_nova_id     TEXT NOT NULL,
  ephemeral_public_key TEXT NOT NULL,
  shared_secret_id     TEXT,
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  last_used_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crypto_sessions_sender   ON crypto_sessions(sender_nova_id);
CREATE INDEX IF NOT EXISTS idx_crypto_sessions_receiver ON crypto_sessions(receiver_nova_id);


-- =====================================================================
--  §4  CHAT: messages, contacts, call_history, reports, blocked_users
-- =====================================================================

-- ---------------------------------------------------------------------
-- messages — mensajes del chat de la app.
--
-- OJO: es una tabla DISTINTA de `realtime_messages` (§9). Aquélla es el
-- almacén de sobres E2EE del servidor realtime; ésta es el modelo de
-- chat de la app. Tienen claves y columnas incompatibles y por eso NO
-- se pueden fusionar.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id    TEXT NOT NULL,
  sender_id  TEXT NOT NULL,
  text       TEXT,                    -- contenido cifrado en cliente
  media_url  TEXT,
  type       TEXT    DEFAULT 'text',
  timestamp  TEXT    NOT NULL,
  is_me      INTEGER DEFAULT 0,
  status     TEXT    DEFAULT 'sent',
  poll_data  JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Extensiones de FASE 4.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_edited            BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at            TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_deleted           BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_at           TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_ephemeral         BOOLEAN DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS ephemeral_ttl        INTEGER;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS ephemeral_expires_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id          UUID;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_text        TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_sender      TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reactions_count      INTEGER DEFAULT 0;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS updated_at           TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_messages_chat_id     ON messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id   ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp   ON messages(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_messages_text_search ON messages
  USING gin(to_tsvector('simple', COALESCE(text, '')));

-- ---------------------------------------------------------------------
-- contacts — libreta de la app (distinta de `realtime_contacts`, §9).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contacts (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id       TEXT NOT NULL,
  contact_id         TEXT NOT NULL,
  contact_name       TEXT,
  verification_level TEXT    DEFAULT 'level1',
  last_message       TEXT,
  last_message_time  TIMESTAMPTZ,
  is_archived        INTEGER DEFAULT 0,
  is_blocked         INTEGER DEFAULT 0,
  is_favorite        INTEGER DEFAULT 0,
  created_at         TIMESTAMPTZ DEFAULT NOW(),
  updated_at         TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_nova_id, contact_id)
);

CREATE INDEX IF NOT EXISTS idx_contacts_user_nova_id ON contacts(user_nova_id);

-- ---------------------------------------------------------------------
-- call_history — historial local de llamadas (modelo antiguo).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS call_history (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id TEXT NOT NULL,
  contact_id   TEXT NOT NULL,
  contact_name TEXT,
  call_type    TEXT NOT NULL,
  direction    TEXT NOT NULL,
  duration     INTEGER,
  timestamp    TIMESTAMPTZ DEFAULT NOW(),
  status       TEXT DEFAULT 'completed'
);

CREATE INDEX IF NOT EXISTS idx_call_history_user ON call_history(user_nova_id);

-- ---------------------------------------------------------------------
-- reports / blocked_users — moderación.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reports (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  reported_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  reason      TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(reporter_id, reported_id)
);

CREATE TABLE IF NOT EXISTS blocked_users (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_reports_reporter_id       ON reports(reporter_id);
CREATE INDEX IF NOT EXISTS idx_reports_reported_id       ON reports(reported_id);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocker_id  ON blocked_users(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked_id  ON blocked_users(blocked_id);


-- ---------------------------------------------------------------------
-- profiles — VISTA de compatibilidad sobre public.users.
--
-- `moderation_service.dart` consulta `profiles` (nombre anterior de la
-- tabla `users`) para leer reports_count e is_shadowbanned. Esas
-- consultas están envueltas en try/catch, así que hoy FALLAN EN SILENCIO
-- y devuelven 0/false: el shadowban nunca se detecta.
--
-- `security_invoker = on` hace que la vista aplique la RLS de
-- public.users con los permisos de QUIEN CONSULTA, no del propietario:
-- la vista no abre ningún acceso nuevo.
--
-- TODO (app): migrar moderation_service.dart a `users` y borrar la vista.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW profiles
WITH (security_invoker = on) AS
  SELECT id, nova_id, display_name, name, avatar_url, public_key,
         x25519_identity_key, privacy_level, is_online, last_seen,
         reports_count, is_shadowbanned, created_at, updated_at
  FROM public.users;

GRANT SELECT ON profiles TO anon, authenticated;


-- =====================================================================
--  §5  MEJORAS DE CHAT: reacciones e indicadores de escritura
-- =====================================================================

CREATE TABLE IF NOT EXISTS message_reactions (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  nova_id    TEXT NOT NULL,
  emoji      TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(message_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_reactions_message_id ON message_reactions(message_id);
CREATE INDEX IF NOT EXISTS idx_reactions_nova_id    ON message_reactions(nova_id);

CREATE TABLE IF NOT EXISTS typing_indicators (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id    TEXT NOT NULL,
  nova_id    TEXT NOT NULL,
  is_typing  BOOLEAN DEFAULT false,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_typing_chat_id          ON typing_indicators(chat_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_typing_nova_chat ON typing_indicators(nova_id, chat_id);


-- =====================================================================
--  §6  GRUPOS
-- =====================================================================

CREATE TABLE IF NOT EXISTS groups (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name            TEXT NOT NULL,
  description     TEXT,
  avatar_url      TEXT,
  creator_nova_id TEXT NOT NULL,
  is_active       BOOLEAN DEFAULT true,
  member_count    INTEGER DEFAULT 1,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS group_members (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id     UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  nova_id      TEXT NOT NULL,
  role         TEXT DEFAULT 'member',        -- owner | admin | member
  display_name TEXT,
  is_muted     BOOLEAN DEFAULT false,
  joined_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_group_members_nova_id  ON group_members(nova_id);

CREATE TABLE IF NOT EXISTS group_messages (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id        UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  sender_id       TEXT NOT NULL,
  text            TEXT,
  type            TEXT DEFAULT 'text',
  is_edited       BOOLEAN DEFAULT false,
  edited_at       TIMESTAMPTZ,
  is_deleted      BOOLEAN DEFAULT false,
  deleted_at      TIMESTAMPTZ,
  reply_to_id     UUID,
  reactions_count INTEGER DEFAULT 0,
  mentions        TEXT[],
  timestamp       TIMESTAMPTZ DEFAULT NOW(),
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_messages_group_id  ON group_messages(group_id);
CREATE INDEX IF NOT EXISTS idx_group_messages_timestamp ON group_messages(timestamp DESC);

CREATE TABLE IF NOT EXISTS group_invites (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id   UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  token      TEXT UNIQUE NOT NULL,
  created_by TEXT NOT NULL,
  max_uses   INTEGER DEFAULT 50,
  uses       INTEGER DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_invites_token ON group_invites(token);

-- Claves de emisor cifradas por miembro (cifrado de grupo).
CREATE TABLE IF NOT EXISTS group_sender_keys (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id      UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  nova_id       TEXT NOT NULL,
  encrypted_key TEXT NOT NULL,
  key_version   INTEGER DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_group_sender_keys_group ON group_sender_keys(group_id);

CREATE TABLE IF NOT EXISTS pinned_messages (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id   UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  message_id UUID NOT NULL,
  pinned_by  TEXT NOT NULL,
  pinned_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, message_id)
);


-- =====================================================================
--  §7  LLAMADAS (modelo usado por la app: calls + call_participants)
-- =====================================================================

CREATE TABLE IF NOT EXISTS calls (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  caller_nova_id TEXT NOT NULL,
  callee_nova_id TEXT,
  group_id       UUID REFERENCES groups(id) ON DELETE SET NULL,
  call_type      TEXT NOT NULL DEFAULT 'audio',   -- audio | video
  status         TEXT NOT NULL DEFAULT 'ringing', -- ringing|active|ended|missed|rejected
  started_at     TIMESTAMPTZ DEFAULT NOW(),
  answered_at    TIMESTAMPTZ,
  ended_at       TIMESTAMPTZ,
  duration       INTEGER,
  end_reason     TEXT,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_calls_caller ON calls(caller_nova_id);
CREATE INDEX IF NOT EXISTS idx_calls_callee ON calls(callee_nova_id);
CREATE INDEX IF NOT EXISTS idx_calls_status ON calls(status);

CREATE TABLE IF NOT EXISTS call_participants (
  id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  call_id   UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  nova_id   TEXT NOT NULL,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  left_at   TIMESTAMPTZ,
  is_muted  BOOLEAN DEFAULT false,
  has_video BOOLEAN DEFAULT false,
  UNIQUE(call_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_call_participants_call ON call_participants(call_id);


-- =====================================================================
--  §8  OPERACIÓN: ajustes, multidispositivo, anti-abuso
-- =====================================================================

CREATE TABLE IF NOT EXISTS user_settings (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id               TEXT UNIQUE NOT NULL,
  last_seen_visibility  TEXT    DEFAULT 'contacts',  -- everyone|contacts|nobody
  profile_photo_privacy TEXT    DEFAULT 'contacts',
  read_receipts_enabled BOOLEAN DEFAULT true,
  typing_indicators     BOOLEAN DEFAULT true,
  notifications_enabled BOOLEAN DEFAULT true,
  settings_json         JSONB   DEFAULT '{}'::jsonb,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

-- Aprobación de un dispositivo nuevo desde otro ya confiable.
CREATE TABLE IF NOT EXISTS device_approvals (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id           TEXT NOT NULL,
  device_id         TEXT NOT NULL,
  requesting_device TEXT,
  approving_device  TEXT,
  status            TEXT DEFAULT 'pending',   -- pending | approved | rejected
  approval_code     TEXT,
  expires_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  resolved_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_device_approvals_nova   ON device_approvals(nova_id);
CREATE INDEX IF NOT EXISTS idx_device_approvals_device ON device_approvals(device_id);

-- Contadores de rate limiting a nivel de aplicación.
CREATE TABLE IF NOT EXISTS rate_limits (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  identifier TEXT NOT NULL,          -- nova_id, ip o device_id
  action     TEXT NOT NULL,          -- 'send_message', 'call', ...
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_lookup ON rate_limits(identifier, action, created_at DESC);

CREATE TABLE IF NOT EXISTS registration_attempts (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ip_address TEXT,
  device_id  TEXT,
  nova_id    TEXT,
  successful BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_registration_attempts_ip     ON registration_attempts(ip_address, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_registration_attempts_device ON registration_attempts(device_id, created_at DESC);


-- =====================================================================
--  §9  TIER REALTIME (servidor Socket.IO)  —  prefijo `realtime_`
-- =====================================================================
--  Estas tablas pertenecen EXCLUSIVAMENTE al servidor realtime, que las
--  usa con la service role key desde el backend.
--
--  Llevan prefijo propio porque `messages` y `contacts` ya existen en la
--  app con un esquema incompatible (§4). Fusionarlas rompería uno de los
--  dos lados.
--
--  DOS contadores por conversación, deliberadamente distintos:
--    server_seq → orden de MENSAJES.
--    log_seq    → orden del LOG de eventos, es decir el cursor de sync.
--  Un acuse de recibo sobre un mensaje antiguo recibe un log_seq NUEVO,
--  de modo que un cliente ya adelantado lo sigue recibiendo al
--  sincronizar. Con un solo contador esos recibos se perdían.
-- =====================================================================

-- Membresías: verdad del servidor para rooms y autorización.
CREATE TABLE IF NOT EXISTS realtime_conversation_members (
  conversation_id TEXT NOT NULL,
  account_id      TEXT NOT NULL,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (conversation_id, account_id)
);

CREATE INDEX IF NOT EXISTS realtime_conversation_members_account_idx
  ON realtime_conversation_members(account_id);

-- Grafo de relaciones que autoriza la señalización de llamadas.
CREATE TABLE IF NOT EXISTS realtime_contacts (
  account_id TEXT    NOT NULL,
  peer_id    TEXT    NOT NULL,
  blocked    BOOLEAN NOT NULL DEFAULT false,
  PRIMARY KEY (account_id, peer_id)
);

-- Audiencia de presencia (opt-in de privacidad).
CREATE TABLE IF NOT EXISTS realtime_presence_audience (
  subject_id TEXT NOT NULL,
  viewer_id  TEXT NOT NULL,
  PRIMARY KEY (subject_id, viewer_id)
);

-- Sobres E2EE opacos + metadata del servidor.
CREATE TABLE IF NOT EXISTS realtime_messages (
  message_id        TEXT PRIMARY KEY,      -- UUID v4 del cliente (idempotencia)
  conversation_id   TEXT   NOT NULL,
  sender_account_id TEXT   NOT NULL,
  sender_device_id  TEXT   NOT NULL,
  ciphertext        TEXT   NOT NULL,       -- base64 opaco; NUNCA texto claro
  header_type       TEXT   NOT NULL,       -- p. ej. 'dr.v1'
  server_seq        BIGINT NOT NULL,
  received_at_ms    BIGINT NOT NULL,
  client_ts_ms      BIGINT                 -- pista de UI; nunca se confía
);

CREATE INDEX IF NOT EXISTS realtime_messages_conversation_seq_idx
  ON realtime_messages(conversation_id, server_seq);

-- Log append-only que respalda sync.response.
CREATE TABLE IF NOT EXISTS realtime_events (
  conversation_id TEXT   NOT NULL,
  type            TEXT   NOT NULL,   -- message.new | message.delivered | message.read
  server_seq      BIGINT NOT NULL,
  log_seq         BIGINT NOT NULL,
  at_ms           BIGINT NOT NULL,
  payload         JSONB  NOT NULL,
  PRIMARY KEY (conversation_id, log_seq)
);

CREATE INDEX IF NOT EXISTS realtime_events_sync_idx
  ON realtime_events(conversation_id, log_seq);

-- Contadores atómicos (PostgREST no puede expresar un INCR seguro).
CREATE TABLE IF NOT EXISTS realtime_cursors (
  conversation_id TEXT PRIMARY KEY,
  last_seq        BIGINT NOT NULL DEFAULT 0,
  last_log_seq    BIGINT NOT NULL DEFAULT 0
);

-- Última presencia conocida (el fan-out se filtra por audiencia).
CREATE TABLE IF NOT EXISTS realtime_presence (
  account_id   TEXT PRIMARY KEY,
  status       TEXT   NOT NULL,      -- online | offline
  last_seen_ms BIGINT NOT NULL
);


-- =====================================================================
--  §10  FUNCIONES
-- =====================================================================

-- ---------------------------------------------------------------------
-- 10.1  Utilidades
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- Traduce auth.uid() (UUID) → nova_id (TEXT). Base de casi toda la RLS.
CREATE OR REPLACE FUNCTION auth_nova_id()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nova_id FROM public.users WHERE id = auth.uid() LIMIT 1;
$$;

-- Alta en public.users al registrarse en auth.users.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.users (id, name, nova_id)
  VALUES (
    NEW.id,
    COALESCE(
      NEW.raw_user_meta_data->>'name',
      NEW.raw_user_meta_data->>'full_name',
      'Usuario'
    ),
    NEW.raw_user_meta_data->>'nova_id'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Contador de reportes + shadowban automático a los 3.
CREATE OR REPLACE FUNCTION public.handle_new_report()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET reports_count   = COALESCE(reports_count, 0) + 1,
      is_shadowbanned = CASE
                          WHEN COALESCE(reports_count, 0) + 1 >= 3 THEN TRUE
                          ELSE COALESCE(is_shadowbanned, FALSE)
                        END
  WHERE id = NEW.reported_id;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION update_reactions_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE messages SET reactions_count = COALESCE(reactions_count, 0) + 1
    WHERE id = NEW.message_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE messages SET reactions_count = GREATEST(COALESCE(reactions_count, 1) - 1, 0)
    WHERE id = OLD.message_id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION update_group_member_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE groups SET member_count = COALESCE(member_count, 0) + 1
    WHERE id = NEW.group_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE groups SET member_count = GREATEST(COALESCE(member_count, 1) - 1, 0)
    WHERE id = OLD.group_id;
  END IF;
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------
-- 10.2  Autenticación (RPC llamadas por la app)
-- ---------------------------------------------------------------------

-- CORRECCIÓN: la versión anterior declaraba `v_random BYTES`. El tipo
-- `BYTES` NO EXISTE en PostgreSQL (es sintaxis de CockroachDB), así que
-- esta función fallaba SIEMPRE en ejecución. Ahora usa `bytea`.
CREATE OR REPLACE FUNCTION auth_challenge_request(p_nova_id TEXT)
RETURNS TABLE(challenge TEXT, challenge_id TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_challenge    TEXT;
  v_challenge_id TEXT;
  v_expires_at   TIMESTAMPTZ;
  v_random       bytea;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM accounts a WHERE a.nova_id = p_nova_id) THEN
    RAISE EXCEPTION 'Account not found';
  END IF;

  IF EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.nova_id = p_nova_id AND a.is_locked = true AND a.locked_until > NOW()
  ) THEN
    RAISE EXCEPTION 'Account is locked';
  END IF;

  v_random       := gen_random_bytes(32);
  v_challenge    := encode(v_random, 'hex');
  v_challenge_id := encode(gen_random_bytes(16), 'hex');
  v_expires_at   := NOW() + INTERVAL '60 seconds';

  INSERT INTO auth_challenges (nova_id, challenge, challenge_id, expires_at)
  VALUES (p_nova_id, v_challenge, v_challenge_id, v_expires_at);

  RETURN QUERY SELECT v_challenge, v_challenge_id, v_expires_at;
END;
$$;

-- NOTA: la emisión real del JWT debe hacerla una Edge Function con la
-- service role key. Esta función marca el challenge como usado y
-- devuelve un marcador; NO es un token válido por sí mismo.
CREATE OR REPLACE FUNCTION auth_challenge_verify(
  p_challenge_id TEXT,
  p_response     TEXT
)
RETURNS TABLE(token TEXT, refresh_token TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_challenge_record RECORD;
  v_new_token        TEXT;
  v_new_refresh      TEXT;
BEGIN
  SELECT * INTO v_challenge_record
  FROM auth_challenges
  WHERE challenge_id = p_challenge_id
    AND used = false
    AND expires_at > NOW();

  IF v_challenge_record IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired challenge';
  END IF;

  UPDATE auth_challenges SET used = true WHERE challenge_id = p_challenge_id;

  UPDATE accounts
  SET failed_login_attempts = 0, locked_until = NULL
  WHERE nova_id = v_challenge_record.nova_id;

  v_new_token   := 'jwt_placeholder_' || encode(gen_random_bytes(32), 'hex');
  v_new_refresh := encode(gen_random_bytes(32), 'hex');

  RETURN QUERY SELECT v_new_token, v_new_refresh;
END;
$$;

CREATE OR REPLACE FUNCTION auth_register(
  p_nova_id      TEXT,
  p_pin_hash     TEXT,
  p_salt         TEXT,
  p_display_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM accounts WHERE nova_id = p_nova_id) THEN
    RETURN false;
  END IF;

  INSERT INTO accounts (nova_id, pin_hash, pin_salt, display_name)
  VALUES (p_nova_id, p_pin_hash, p_salt, p_display_name);

  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------
-- 10.3  Anti-abuso — RPC `check_rate_limit`
--       La app lo llamaba (anti_spam_service.dart) pero no existía.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_rate_limit(
  p_identifier   TEXT,
  p_action       TEXT,
  p_max_requests INTEGER DEFAULT 30,
  p_window_secs  INTEGER DEFAULT 60
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM rate_limits
  WHERE identifier = p_identifier
    AND action     = p_action
    AND created_at > NOW() - make_interval(secs => p_window_secs);

  IF v_count >= p_max_requests THEN
    RETURN false;   -- límite superado
  END IF;

  INSERT INTO rate_limits (identifier, action) VALUES (p_identifier, p_action);
  RETURN true;      -- permitido
END;
$$;

-- ---------------------------------------------------------------------
-- 10.4  Contadores atómicos del tier realtime
--       INSERT ... ON CONFLICT DO UPDATE toma un lock de fila, así que
--       dos nodos NUNCA pueden acuñar el mismo valor.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION nova_next_seq(p_conversation_id TEXT)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO realtime_cursors (conversation_id, last_seq)
  VALUES (p_conversation_id, 1)
  ON CONFLICT (conversation_id)
  DO UPDATE SET last_seq = realtime_cursors.last_seq + 1
  RETURNING last_seq;
$$;

CREATE OR REPLACE FUNCTION nova_next_log_seq(p_conversation_id TEXT)
RETURNS BIGINT
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO realtime_cursors (conversation_id, last_log_seq)
  VALUES (p_conversation_id, 1)
  ON CONFLICT (conversation_id)
  DO UPDATE SET last_log_seq = realtime_cursors.last_log_seq + 1
  RETURNING last_log_seq;
$$;

-- ---------------------------------------------------------------------
-- 10.5  Limpieza periódica (pg_cron o un worker externo)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cleanup_expired_challenges()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  DELETE FROM auth_challenges WHERE expires_at < NOW() - INTERVAL '5 minutes';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  DELETE FROM sessions WHERE expires_at < NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION cleanup_stale_typing()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  DELETE FROM typing_indicators WHERE updated_at < NOW() - INTERVAL '10 seconds';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION cleanup_expired_ephemeral()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  UPDATE messages
  SET text       = NULL,
      is_deleted = true,
      deleted_at = NOW(),
      type       = 'ephemeral_expired'
  WHERE is_ephemeral = true
    AND is_deleted   = false
    AND ephemeral_expires_at < NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION cleanup_old_rate_limits()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count INTEGER;
BEGIN
  DELETE FROM rate_limits WHERE created_at < NOW() - INTERVAL '1 hour';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- =====================================================================
--  §11  TRIGGERS  (siempre DROP antes de CREATE → reejecutable)
-- =====================================================================

DROP TRIGGER IF EXISTS update_users_updated_at ON public.users;
CREATE TRIGGER update_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_contacts_updated_at ON contacts;
CREATE TRIGGER update_contacts_updated_at
  BEFORE UPDATE ON contacts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_accounts_updated_at ON accounts;
CREATE TRIGGER update_accounts_updated_at
  BEFORE UPDATE ON accounts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_groups_updated_at ON groups;
CREATE TRIGGER update_groups_updated_at
  BEFORE UPDATE ON groups
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_user_settings_updated_at ON user_settings;
CREATE TRIGGER update_user_settings_updated_at
  BEFORE UPDATE ON user_settings
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

DROP TRIGGER IF EXISTS on_new_report ON reports;
CREATE TRIGGER on_new_report
  AFTER INSERT ON reports
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_report();

DROP TRIGGER IF EXISTS trigger_reactions_count ON message_reactions;
CREATE TRIGGER trigger_reactions_count
  AFTER INSERT OR DELETE ON message_reactions
  FOR EACH ROW EXECUTE FUNCTION update_reactions_count();

DROP TRIGGER IF EXISTS trigger_group_member_count ON group_members;
CREATE TRIGGER trigger_group_member_count
  AFTER INSERT OR DELETE ON group_members
  FOR EACH ROW EXECUTE FUNCTION update_group_member_count();


-- =====================================================================
--  §12  ROW LEVEL SECURITY
-- =====================================================================

-- 12.1  Activar RLS en todo -------------------------------------------

ALTER TABLE public.users                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_challenges               ENABLE ROW LEVEL SECURITY;
ALTER TABLE signed_pre_keys               ENABLE ROW LEVEL SECURITY;
ALTER TABLE one_time_pre_keys             ENABLE ROW LEVEL SECURITY;
ALTER TABLE crypto_sessions               ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts                      ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_history                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports                       ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_users                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_reactions             ENABLE ROW LEVEL SECURITY;
ALTER TABLE typing_indicators             ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups                        ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_messages                ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_invites                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_sender_keys             ENABLE ROW LEVEL SECURITY;
ALTER TABLE pinned_messages               ENABLE ROW LEVEL SECURITY;
ALTER TABLE calls                         ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_participants             ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_settings                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_approvals              ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limits                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE registration_attempts         ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_contacts             ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_presence_audience    ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_messages             ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_events               ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_cursors              ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_presence             ENABLE ROW LEVEL SECURITY;

-- Endurecimiento extra: aplicar RLS incluso al propietario de la tabla.
ALTER TABLE realtime_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE realtime_events   FORCE ROW LEVEL SECURITY;

-- 12.2  users ----------------------------------------------------------

DROP POLICY IF EXISTS "users_select_public"  ON public.users;
DROP POLICY IF EXISTS "users_insert_self"    ON public.users;
DROP POLICY IF EXISTS "users_update_self"    ON public.users;
DROP POLICY IF EXISTS "users_delete_self"    ON public.users;
-- Nombres antiguos (despliegues previos).
DROP POLICY IF EXISTS "Permitir lectura pública de usuarios"    ON public.users;
DROP POLICY IF EXISTS "Permitir inserción de propio usuario"    ON public.users;
DROP POLICY IF EXISTS "Permitir actualización de propio usuario" ON public.users;
DROP POLICY IF EXISTS "Permitir eliminación de propio usuario"  ON public.users;

-- El perfil es públicamente legible (nova_id, display_name, avatar,
-- clave pública): necesario para descubrir contactos e iniciar X3DH.
-- Los campos internos (email, fcm_token) se protegen limitando las
-- columnas seleccionadas desde la app.
CREATE POLICY "users_select_public" ON public.users FOR SELECT USING (true);
CREATE POLICY "users_insert_self"   ON public.users FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "users_update_self"   ON public.users FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "users_delete_self"   ON public.users FOR DELETE USING (auth.uid() = id);

-- 12.3  accounts / devices / sessions / auth_challenges ----------------

DROP POLICY IF EXISTS "Owner can read own account"        ON accounts;
DROP POLICY IF EXISTS "Owner can update own account"      ON accounts;
DROP POLICY IF EXISTS "Public can check nova_id existence" ON accounts;
DROP POLICY IF EXISTS "accounts_select_owner"             ON accounts;
DROP POLICY IF EXISTS "accounts_update_owner"             ON accounts;

-- Sólo el propio dueño lee su cuenta. La política pública anterior
-- ("Public can check nova_id existence" USING true) exponía pin_hash y
-- pin_salt a cualquiera: se elimina. La comprobación de disponibilidad
-- de un Nova ID debe hacerse contra public.users, no contra accounts.
CREATE POLICY "accounts_select_owner" ON accounts FOR SELECT
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "accounts_update_owner" ON accounts FOR UPDATE
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

DROP POLICY IF EXISTS "Owner can read own devices"   ON devices;
DROP POLICY IF EXISTS "Owner can insert own devices" ON devices;
DROP POLICY IF EXISTS "Owner can update own devices" ON devices;
DROP POLICY IF EXISTS "Owner can delete own devices" ON devices;
CREATE POLICY "Owner can read own devices" ON devices FOR SELECT
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can insert own devices" ON devices FOR INSERT
  WITH CHECK (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can update own devices" ON devices FOR UPDATE
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can delete own devices" ON devices FOR DELETE
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

DROP POLICY IF EXISTS "Owner can read own sessions"   ON sessions;
DROP POLICY IF EXISTS "Owner can insert own sessions" ON sessions;
DROP POLICY IF EXISTS "Owner can delete own sessions" ON sessions;
CREATE POLICY "Owner can read own sessions" ON sessions FOR SELECT
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can insert own sessions" ON sessions FOR INSERT
  WITH CHECK (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can delete own sessions" ON sessions FOR DELETE
  USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

-- auth_challenges: SIN políticas. Sólo el service_role (Edge Functions)
-- las maneja. La política anterior (FOR ALL USING true) permitía a
-- cualquier cliente leer y modificar challenges ajenos.
DROP POLICY IF EXISTS "System can manage challenges" ON auth_challenges;

-- 12.4  Claves X3DH ----------------------------------------------------

DROP POLICY IF EXISTS "Public can read signed pre-keys"     ON signed_pre_keys;
DROP POLICY IF EXISTS "Owner can insert signed pre-keys"    ON signed_pre_keys;
DROP POLICY IF EXISTS "Owner can delete own signed pre-keys" ON signed_pre_keys;
-- Lectura pública: es un requisito del protocolo X3DH (cualquiera que
-- quiera escribirte necesita tu bundle). Escritura sólo del dueño.
CREATE POLICY "Public can read signed pre-keys" ON signed_pre_keys FOR SELECT USING (true);
CREATE POLICY "Owner can insert signed pre-keys" ON signed_pre_keys FOR INSERT
  WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own signed pre-keys" ON signed_pre_keys FOR DELETE
  USING (nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Public can read one-time pre-keys"   ON one_time_pre_keys;
DROP POLICY IF EXISTS "Owner can insert one-time pre-keys"  ON one_time_pre_keys;
DROP POLICY IF EXISTS "Anyone can consume one-time pre-keys" ON one_time_pre_keys;
CREATE POLICY "Public can read one-time pre-keys" ON one_time_pre_keys FOR SELECT USING (true);
CREATE POLICY "Owner can insert one-time pre-keys" ON one_time_pre_keys FOR INSERT
  WITH CHECK (nova_id = auth_nova_id());
-- Una OPK se consume borrándola: por diseño la borra quien la usa.
-- Riesgo conocido: un atacante autenticado puede agotar las OPK de un
-- usuario. Mitigación: reposición periódica desde el cliente + caída
-- elegante a X3DH sin OPK.
CREATE POLICY "Anyone can consume one-time pre-keys" ON one_time_pre_keys FOR DELETE
  USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "Participants can read sessions"   ON crypto_sessions;
DROP POLICY IF EXISTS "Owner can insert sessions"        ON crypto_sessions;
DROP POLICY IF EXISTS "Participants can update sessions" ON crypto_sessions;
CREATE POLICY "Participants can read sessions" ON crypto_sessions FOR SELECT
  USING (sender_nova_id = auth_nova_id() OR receiver_nova_id = auth_nova_id());
CREATE POLICY "Owner can insert sessions" ON crypto_sessions FOR INSERT
  WITH CHECK (sender_nova_id = auth_nova_id());
CREATE POLICY "Participants can update sessions" ON crypto_sessions FOR UPDATE
  USING (sender_nova_id = auth_nova_id() OR receiver_nova_id = auth_nova_id());

-- 12.5  Chat -----------------------------------------------------------

DROP POLICY IF EXISTS "Users can read own sent messages"    ON messages;
DROP POLICY IF EXISTS "Users can read own messages"         ON messages;
DROP POLICY IF EXISTS "Users can insert own messages"       ON messages;
DROP POLICY IF EXISTS "Users can update own message status" ON messages;
CREATE POLICY "Users can read own messages" ON messages FOR SELECT USING (
  sender_id = auth_nova_id()
  OR sender_id IN (SELECT contact_id FROM contacts WHERE user_nova_id = auth_nova_id())
);
CREATE POLICY "Users can insert own messages" ON messages FOR INSERT
  WITH CHECK (sender_id = auth_nova_id());
CREATE POLICY "Users can update own message status" ON messages FOR UPDATE
  USING (sender_id = auth_nova_id());

DROP POLICY IF EXISTS "Users can read own contacts"   ON contacts;
DROP POLICY IF EXISTS "Users can insert own contacts" ON contacts;
DROP POLICY IF EXISTS "Users can update own contacts" ON contacts;
DROP POLICY IF EXISTS "Users can delete own contacts" ON contacts;
CREATE POLICY "Users can read own contacts"   ON contacts FOR SELECT USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can insert own contacts" ON contacts FOR INSERT WITH CHECK (user_nova_id = auth_nova_id());
CREATE POLICY "Users can update own contacts" ON contacts FOR UPDATE USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can delete own contacts" ON contacts FOR DELETE USING (user_nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Users can read own call history"   ON call_history;
DROP POLICY IF EXISTS "Users can insert own call history" ON call_history;
DROP POLICY IF EXISTS "Users can delete own call history" ON call_history;
CREATE POLICY "Users can read own call history"   ON call_history FOR SELECT USING (user_nova_id = auth_nova_id());
CREATE POLICY "Users can insert own call history" ON call_history FOR INSERT WITH CHECK (user_nova_id = auth_nova_id());
CREATE POLICY "Users can delete own call history" ON call_history FOR DELETE USING (user_nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Permitir todo en reports"     ON reports;
DROP POLICY IF EXISTS "Users can read own reports"   ON reports;
DROP POLICY IF EXISTS "Users can insert own reports" ON reports;
DROP POLICY IF EXISTS "Users cannot modify reports"  ON reports;
DROP POLICY IF EXISTS "Users cannot delete reports"  ON reports;
CREATE POLICY "Users can read own reports"   ON reports FOR SELECT USING (reporter_id = auth.uid());
CREATE POLICY "Users can insert own reports" ON reports FOR INSERT WITH CHECK (reporter_id = auth.uid());
CREATE POLICY "Users cannot modify reports"  ON reports FOR UPDATE USING (false);
CREATE POLICY "Users cannot delete reports"  ON reports FOR DELETE USING (false);

DROP POLICY IF EXISTS "Permitir todo en blocked_users" ON blocked_users;
DROP POLICY IF EXISTS "Users can read own blocks"      ON blocked_users;
DROP POLICY IF EXISTS "Users can insert own blocks"    ON blocked_users;
DROP POLICY IF EXISTS "Users can delete own blocks"    ON blocked_users;
DROP POLICY IF EXISTS "Users cannot modify blocks"     ON blocked_users;
CREATE POLICY "Users can read own blocks"   ON blocked_users FOR SELECT USING (blocker_id = auth.uid());
CREATE POLICY "Users can insert own blocks" ON blocked_users FOR INSERT WITH CHECK (blocker_id = auth.uid());
CREATE POLICY "Users can delete own blocks" ON blocked_users FOR DELETE USING (blocker_id = auth.uid());
CREATE POLICY "Users cannot modify blocks"  ON blocked_users FOR UPDATE USING (false);

DROP POLICY IF EXISTS "Participants can read reactions"  ON message_reactions;
DROP POLICY IF EXISTS "Owner can insert reactions"       ON message_reactions;
DROP POLICY IF EXISTS "Owner can delete own reactions"   ON message_reactions;
CREATE POLICY "Participants can read reactions" ON message_reactions FOR SELECT
  USING (auth.uid() IS NOT NULL);
CREATE POLICY "Owner can insert reactions" ON message_reactions FOR INSERT
  WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own reactions" ON message_reactions FOR DELETE
  USING (nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Participants can read typing"  ON typing_indicators;
DROP POLICY IF EXISTS "Owner can insert typing"       ON typing_indicators;
DROP POLICY IF EXISTS "Owner can update own typing"   ON typing_indicators;
DROP POLICY IF EXISTS "Owner can delete own typing"   ON typing_indicators;
CREATE POLICY "Participants can read typing" ON typing_indicators FOR SELECT
  USING (auth.uid() IS NOT NULL);
CREATE POLICY "Owner can insert typing" ON typing_indicators FOR INSERT
  WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can update own typing" ON typing_indicators FOR UPDATE
  USING (nova_id = auth_nova_id());
CREATE POLICY "Owner can delete own typing" ON typing_indicators FOR DELETE
  USING (nova_id = auth_nova_id());

-- 12.6  Grupos ---------------------------------------------------------

DROP POLICY IF EXISTS "Members can read groups" ON groups;
CREATE POLICY "Members can read groups" ON groups FOR SELECT USING (
  EXISTS (SELECT 1 FROM group_members gm
          WHERE gm.group_id = groups.id AND gm.nova_id = auth_nova_id())
);

DROP POLICY IF EXISTS "Members can read group members" ON group_members;
CREATE POLICY "Members can read group members" ON group_members FOR SELECT USING (
  EXISTS (SELECT 1 FROM group_members gm
          WHERE gm.group_id = group_members.group_id AND gm.nova_id = auth_nova_id())
);

DROP POLICY IF EXISTS "Members can read group messages" ON group_messages;
DROP POLICY IF EXISTS "Members can send group messages" ON group_messages;
CREATE POLICY "Members can read group messages" ON group_messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM group_members gm
          WHERE gm.group_id = group_messages.group_id AND gm.nova_id = auth_nova_id())
);
CREATE POLICY "Members can send group messages" ON group_messages FOR INSERT WITH CHECK (
  sender_id = auth_nova_id()
  AND EXISTS (SELECT 1 FROM group_members gm
              WHERE gm.group_id = group_messages.group_id AND gm.nova_id = auth_nova_id())
);

DROP POLICY IF EXISTS "Members can read invites" ON group_invites;
CREATE POLICY "Members can read invites" ON group_invites FOR SELECT USING (
  EXISTS (SELECT 1 FROM group_members gm
          WHERE gm.group_id = group_invites.group_id AND gm.nova_id = auth_nova_id())
);

DROP POLICY IF EXISTS "Members can read sender keys" ON group_sender_keys;
-- Cada miembro sólo puede leer SU propia clave cifrada, no la del resto.
CREATE POLICY "Members can read sender keys" ON group_sender_keys FOR SELECT USING (
  nova_id = auth_nova_id()
  AND EXISTS (SELECT 1 FROM group_members gm
              WHERE gm.group_id = group_sender_keys.group_id AND gm.nova_id = auth_nova_id())
);

DROP POLICY IF EXISTS "Members can read pinned messages" ON pinned_messages;
CREATE POLICY "Members can read pinned messages" ON pinned_messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM group_members gm
          WHERE gm.group_id = pinned_messages.group_id AND gm.nova_id = auth_nova_id())
);

-- 12.7  Llamadas -------------------------------------------------------

DROP POLICY IF EXISTS "Participants can read calls"   ON calls;
DROP POLICY IF EXISTS "Caller can insert calls"       ON calls;
DROP POLICY IF EXISTS "Participants can update calls" ON calls;
CREATE POLICY "Participants can read calls" ON calls FOR SELECT
  USING (caller_nova_id = auth_nova_id() OR callee_nova_id = auth_nova_id());
CREATE POLICY "Caller can insert calls" ON calls FOR INSERT
  WITH CHECK (caller_nova_id = auth_nova_id());
CREATE POLICY "Participants can update calls" ON calls FOR UPDATE
  USING (caller_nova_id = auth_nova_id() OR callee_nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Participants can read call participants" ON call_participants;
DROP POLICY IF EXISTS "Self can join calls"                     ON call_participants;
DROP POLICY IF EXISTS "Self can update own participation"       ON call_participants;
CREATE POLICY "Participants can read call participants" ON call_participants FOR SELECT USING (
  EXISTS (SELECT 1 FROM calls c
          WHERE c.id = call_participants.call_id
            AND (c.caller_nova_id = auth_nova_id() OR c.callee_nova_id = auth_nova_id()))
);
CREATE POLICY "Self can join calls" ON call_participants FOR INSERT
  WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Self can update own participation" ON call_participants FOR UPDATE
  USING (nova_id = auth_nova_id());

-- 12.8  Ajustes y multidispositivo -------------------------------------

DROP POLICY IF EXISTS "Owner can read own settings"   ON user_settings;
DROP POLICY IF EXISTS "Owner can insert own settings" ON user_settings;
DROP POLICY IF EXISTS "Owner can update own settings" ON user_settings;
CREATE POLICY "Owner can read own settings"   ON user_settings FOR SELECT USING (nova_id = auth_nova_id());
CREATE POLICY "Owner can insert own settings" ON user_settings FOR INSERT WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can update own settings" ON user_settings FOR UPDATE USING (nova_id = auth_nova_id());

DROP POLICY IF EXISTS "Owner can read own approvals"   ON device_approvals;
DROP POLICY IF EXISTS "Owner can insert own approvals" ON device_approvals;
DROP POLICY IF EXISTS "Owner can update own approvals" ON device_approvals;
CREATE POLICY "Owner can read own approvals"   ON device_approvals FOR SELECT USING (nova_id = auth_nova_id());
CREATE POLICY "Owner can insert own approvals" ON device_approvals FOR INSERT WITH CHECK (nova_id = auth_nova_id());
CREATE POLICY "Owner can update own approvals" ON device_approvals FOR UPDATE USING (nova_id = auth_nova_id());

-- rate_limits y registration_attempts: SIN políticas de cliente.
-- Se manipulan sólo vía los RPC SECURITY DEFINER (§10.3) o el backend.
-- Si el cliente pudiera borrar filas, el rate limiting sería inútil.

-- 12.9  Tier realtime: deny-by-default ---------------------------------
-- Sin ninguna política, con RLS activo, estas tablas son INVISIBLES para
-- anon y authenticated. Sólo el service_role del backend las alcanza.
-- (No se crea ninguna política a propósito: es el comportamiento
-- deseado, no un olvido.)


-- =====================================================================
--  §13  PUBLICACIÓN REALTIME (idempotente)
-- =====================================================================
--  Las tablas `realtime_*` NO se publican: el fan-out en vivo lo hace el
--  servidor Socket.IO, no el Realtime de Supabase. Publicarlas filtraría
--  ciphertext y metadata a cualquier suscriptor.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END
$$;

DO $$
DECLARE
  t TEXT;
  wanted TEXT[] := ARRAY[
    'users', 'messages', 'contacts', 'reports', 'blocked_users',
    'signed_pre_keys', 'one_time_pre_keys',
    'message_reactions', 'typing_indicators',
    'group_messages', 'group_members',
    'calls', 'call_participants', 'device_approvals'
  ];
BEGIN
  FOREACH t IN ARRAY wanted LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END
$$;


-- =====================================================================
--  §14  PERMISOS EXPLÍCITOS
-- =====================================================================

-- 14.1  El tier realtime pertenece SÓLO al backend.
REVOKE ALL ON realtime_conversation_members, realtime_contacts,
              realtime_presence_audience,    realtime_messages,
              realtime_events,               realtime_cursors,
              realtime_presence
  FROM anon, authenticated;

-- 14.2  Los contadores atómicos no son invocables desde la app.
REVOKE ALL ON FUNCTION nova_next_seq(TEXT)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION nova_next_log_seq(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION nova_next_seq(TEXT)     TO service_role;
GRANT EXECUTE ON FUNCTION nova_next_log_seq(TEXT) TO service_role;

-- 14.3  Tablas anti-abuso: sólo backend / RPC SECURITY DEFINER.
REVOKE ALL ON rate_limits, registration_attempts, auth_challenges
  FROM anon, authenticated;

-- 14.4  RPC que la app sí debe poder llamar.
GRANT EXECUTE ON FUNCTION check_rate_limit(TEXT, TEXT, INTEGER, INTEGER) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_challenge_request(TEXT)                   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_challenge_verify(TEXT, TEXT)              TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_register(TEXT, TEXT, TEXT, TEXT)          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth_nova_id()                                 TO anon, authenticated;

-- 14.5  Limpiezas: sólo backend / cron.
REVOKE ALL ON FUNCTION cleanup_expired_challenges() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cleanup_expired_sessions()   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cleanup_stale_typing()       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cleanup_expired_ephemeral()  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION cleanup_old_rate_limits()    FROM PUBLIC, anon, authenticated;


-- =====================================================================
--  §15  REINICIO TOTAL  (DESTRUCTIVO — descomentar sólo a conciencia)
-- =====================================================================
--  El antiguo supabase_setup.sql empezaba con DROP TABLE ... CASCADE,
--  así que BORRABA todos los mensajes y contactos en cada ejecución.
--  Aquí queda comentado y aislado para que nunca ocurra por accidente.
--
--  DROP TABLE IF EXISTS realtime_events, realtime_messages,
--    realtime_cursors, realtime_presence, realtime_presence_audience,
--    realtime_contacts, realtime_conversation_members CASCADE;
--  DROP TABLE IF EXISTS pinned_messages, group_sender_keys, group_invites,
--    group_messages, group_members, groups CASCADE;
--  DROP TABLE IF EXISTS call_participants, calls, call_history CASCADE;
--  DROP TABLE IF EXISTS message_reactions, typing_indicators CASCADE;
--  DROP TABLE IF EXISTS registration_attempts, rate_limits,
--    device_approvals, user_settings CASCADE;
--  DROP TABLE IF EXISTS blocked_users, reports, contacts, messages CASCADE;
--  DROP TABLE IF EXISTS crypto_sessions, one_time_pre_keys,
--    signed_pre_keys CASCADE;
--  DROP TABLE IF EXISTS auth_challenges, sessions, devices, accounts CASCADE;
--  DROP TABLE IF EXISTS public.users CASCADE;


-- =====================================================================
--  §16  VERIFICACIÓN
-- =====================================================================

DO $$
DECLARE
  v_tables   INTEGER;
  v_policies INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_tables
  FROM information_schema.tables
  WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

  SELECT COUNT(*) INTO v_policies
  FROM pg_policies WHERE schemaname = 'public';

  RAISE NOTICE 'NovaApp: % tablas y % políticas RLS en el esquema public.', v_tables, v_policies;
END
$$;

-- ---------------------------------------------------------------------
-- 16.1  Columnas críticas con un TIPO incompatible.
--
-- §1.5 añade columnas que faltan, pero NUNCA cambia el tipo de una que
-- ya existe: convertir datos es una decisión manual. Este bloque avisa
-- si un despliegue antiguo dejó una columna con un tipo que romperá al
-- servidor realtime o a las claves foráneas.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  r        RECORD;
  v_issues INTEGER := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('devices',          'device_id',         'text'),
      ('devices',          'account_id',        'text'),
      ('devices',          'nova_id',           'text'),
      ('devices',          'public_key',        'text'),
      ('sessions',         'device_id',         'text'),
      ('device_approvals', 'device_id',         'text'),
      ('accounts',         'nova_id',           'text'),
      ('realtime_messages','message_id',        'text'),
      ('realtime_messages','sender_device_id',  'text')
    ) AS t(tbl, col, expected)
  LOOP
    PERFORM 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name   = r.tbl
      AND c.column_name  = r.col
      AND c.data_type   <> r.expected;

    IF FOUND THEN
      v_issues := v_issues + 1;
      RAISE WARNING
        'NovaApp: %.% tiene un tipo distinto del esperado (%). Requiere migración manual de datos.',
        r.tbl, r.col, r.expected;
    END IF;
  END LOOP;

  IF v_issues = 0 THEN
    RAISE NOTICE 'NovaApp: tipos de columnas críticas correctos.';
  END IF;
END
$$;

SELECT 'NovaApp — esquema unificado aplicado correctamente' AS status;
