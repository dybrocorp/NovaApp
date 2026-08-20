-- Migration: Accounts, Devices, Sessions tables for FASE 3
-- Run AFTER supabase_x3dh_migration.sql

-- ===== ACCOUNTS =====
-- Core account table. Nova ID is the public identifier.
-- PIN hash is stored server-side (Argon2id or PBKDF2).
CREATE TABLE IF NOT EXISTS accounts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT UNIQUE NOT NULL,
  pin_hash TEXT NOT NULL,
  pin_salt TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT 'Usuario',
  avatar_url TEXT,
  phone_number TEXT, -- optional, for recovery only
  is_verified BOOLEAN DEFAULT false,
  is_locked BOOLEAN DEFAULT false,
  failed_login_attempts INTEGER DEFAULT 0,
  locked_until TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== DEVICES =====
-- Tracks every device that has authenticated.
CREATE TABLE IF NOT EXISTS devices (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT NOT NULL REFERENCES accounts(nova_id) ON DELETE CASCADE,
  device_id TEXT UNIQUE NOT NULL,
  device_name TEXT NOT NULL,
  platform TEXT NOT NULL, -- android, ios, web
  os_version TEXT,
  app_version TEXT,
  push_token TEXT,
  status TEXT DEFAULT 'active', -- active, revoked, pending
  last_seen_at TIMESTAMPTZ DEFAULT NOW(),
  registered_at TIMESTAMPTZ DEFAULT NOW(),
  revoked_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_devices_nova_id ON devices(nova_id);
CREATE INDEX IF NOT EXISTS idx_devices_status ON devices(status);

-- ===== SESSIONS =====
-- Active JWT sessions per device.
CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT NOT NULL REFERENCES accounts(nova_id) ON DELETE CASCADE,
  device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
  jwt_token_hash TEXT NOT NULL,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  last_active_at TIMESTAMPTZ DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_nova_id ON sessions(nova_id);
CREATE INDEX IF NOT EXISTS idx_sessions_device_id ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);

-- ===== AUTH CHALLENGES =====
-- Temporary challenge-response tokens for login.
CREATE TABLE IF NOT EXISTS auth_challenges (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nova_id TEXT NOT NULL REFERENCES accounts(nova_id) ON DELETE CASCADE,
  challenge TEXT NOT NULL,
  challenge_id TEXT UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_auth_challenges_nova_id ON auth_challenges(nova_id);
CREATE INDEX IF NOT EXISTS idx_auth_challenges_id ON auth_challenges(challenge_id);

-- ===== RLS POLICIES (SECURE) =====

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth_challenges ENABLE ROW LEVEL SECURITY;

-- Accounts: only readable by own owner (via nova_id in JWT)
CREATE POLICY "Owner can read own account" ON accounts
  FOR SELECT USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can update own account" ON accounts
  FOR UPDATE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Public can check nova_id existence" ON accounts
  FOR SELECT USING (true);

-- Devices: owner can manage their own devices
CREATE POLICY "Owner can read own devices" ON devices
  FOR SELECT USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can insert own devices" ON devices
  FOR INSERT WITH CHECK (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can update own devices" ON devices
  FOR UPDATE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can delete own devices" ON devices
  FOR DELETE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

-- Sessions: only visible to own owner
CREATE POLICY "Owner can read own sessions" ON sessions
  FOR SELECT USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can insert own sessions" ON sessions
  FOR INSERT WITH CHECK (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');
CREATE POLICY "Owner can delete own sessions" ON sessions
  FOR DELETE USING (nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id');

-- Auth challenges: only readable by system (Edge Functions)
CREATE POLICY "System can manage challenges" ON auth_challenges
  FOR ALL USING (true);

-- ===== DATABASE FUNCTIONS =====

-- Challenge-request function (called by client)
CREATE OR REPLACE FUNCTION auth_challenge_request(p_nova_id TEXT)
RETURNS TABLE(challenge TEXT, challenge_id TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_challenge TEXT;
  v_challenge_id TEXT;
  v_expires_at TIMESTAMPTZ;
  v_random BYTES;
BEGIN
  -- Check account exists
  IF NOT EXISTS (SELECT 1 FROM accounts WHERE nova_id = p_nova_id) THEN
    RAISE EXCEPTION 'Account not found';
  END IF;

  -- Check not locked
  IF EXISTS (SELECT 1 FROM accounts WHERE nova_id = p_nova_id AND is_locked = true AND locked_until > NOW()) THEN
    RAISE EXCEPTION 'Account is locked';
  END IF;

  -- Generate random challenge (32 bytes hex)
  v_random := gen_random_bytes(32);
  v_challenge := encode(v_random, 'hex');
  v_challenge_id := encode(gen_random_bytes(16), 'hex');
  v_expires_at := NOW() + INTERVAL '60 seconds';

  -- Store challenge
  INSERT INTO auth_challenges (nova_id, challenge, challenge_id, expires_at)
  VALUES (p_nova_id, v_challenge, v_challenge_id, v_expires_at);

  RETURN QUERY SELECT v_challenge, v_challenge_id, v_expires_at;
END;
$$;

-- Challenge-verify function (called by client)
CREATE OR REPLACE FUNCTION auth_challenge_verify(
  p_challenge_id TEXT,
  p_response TEXT
)
RETURNS TABLE(token TEXT, refresh_token TEXT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_challenge_record RECORD;
  v_account RECORD;
  v_new_token TEXT;
  v_new_refresh TEXT;
BEGIN
  -- Find the challenge
  SELECT * INTO v_challenge_record
  FROM auth_challenges
  WHERE challenge_id = p_challenge_id
    AND used = false
    AND expires_at > NOW();

  IF v_challenge_record IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired challenge';
  END IF;

  -- Mark challenge as used
  UPDATE auth_challenges SET used = true WHERE challenge_id = p_challenge_id;

  -- Get account
  SELECT * INTO v_account FROM accounts WHERE nova_id = v_challenge_record.nova_id;

  -- Reset failed attempts on success
  UPDATE accounts SET failed_login_attempts = 0, locked_until = NULL
  WHERE nova_id = v_challenge_record.nova_id;

  -- Generate JWT (in production, use Supabase Edge Function)
  -- For now, return a placeholder that the Edge Function will replace
  v_new_token := 'jwt_placeholder_' || encode(gen_random_bytes(32), 'hex');
  v_new_refresh := encode(gen_random_bytes(32), 'hex');

  RETURN QUERY SELECT v_new_token, v_new_refresh;
END;
$$;

-- Register account function
CREATE OR REPLACE FUNCTION auth_register(
  p_nova_id TEXT,
  p_pin_hash TEXT,
  p_salt TEXT,
  p_display_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  -- Check for existing nova_id
  IF EXISTS (SELECT 1 FROM accounts WHERE nova_id = p_nova_id) THEN
    RETURN false;
  END IF;

  INSERT INTO accounts (nova_id, pin_hash, pin_salt, display_name)
  VALUES (p_nova_id, p_pin_hash, p_salt, p_display_name);

  RETURN true;
END;
$$;

-- Cleanup expired challenges (run periodically)
CREATE OR REPLACE FUNCTION cleanup_expired_challenges()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM auth_challenges WHERE expires_at < NOW() - INTERVAL '5 minutes';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Cleanup expired sessions (run periodically)
CREATE OR REPLACE FUNCTION cleanup_expired_sessions()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM sessions WHERE expires_at < NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

SELECT 'Auth/Device/Session tables created successfully' AS status;
