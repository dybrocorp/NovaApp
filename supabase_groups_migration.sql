-- Migration: Groups system for FASE 8
-- Run AFTER supabase_chat_enhancement_migration.sql

-- ===== GROUPS =====
CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  avatar_url TEXT,
  creator_nova_id TEXT NOT NULL,
  is_active BOOLEAN DEFAULT true,
  member_count INTEGER DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===== GROUP MEMBERS =====
CREATE TABLE IF NOT EXISTS group_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  nova_id TEXT NOT NULL,
  role TEXT DEFAULT 'member', -- owner, admin, member
  display_name TEXT,
  is_muted BOOLEAN DEFAULT false,
  joined_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_group_members_nova_id ON group_members(nova_id);

-- ===== GROUP MESSAGES =====
CREATE TABLE IF NOT EXISTS group_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  sender_id TEXT NOT NULL,
  text TEXT,
  type TEXT DEFAULT 'text',
  is_edited BOOLEAN DEFAULT false,
  edited_at TIMESTAMPTZ,
  is_deleted BOOLEAN DEFAULT false,
  deleted_at TIMESTAMPTZ,
  reply_to_id UUID,
  reactions_count INTEGER DEFAULT 0,
  mentions TEXT[], -- Array of mentioned Nova IDs
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_messages_group_id ON group_messages(group_id);
CREATE INDEX IF NOT EXISTS idx_group_messages_timestamp ON group_messages(timestamp DESC);

-- ===== GROUP INVITE LINKS =====
CREATE TABLE IF NOT EXISTS group_invites (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  token TEXT UNIQUE NOT NULL,
  created_by TEXT NOT NULL,
  max_uses INTEGER DEFAULT 50,
  uses INTEGER DEFAULT 0,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_group_invites_token ON group_invites(token);

-- ===== GROUP SENDER KEYS =====
-- Encrypted sender keys for group members
CREATE TABLE IF NOT EXISTS group_sender_keys (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  nova_id TEXT NOT NULL,
  encrypted_key TEXT NOT NULL, -- Encrypted with member's identity key
  key_version INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, nova_id)
);

CREATE INDEX IF NOT EXISTS idx_group_sender_keys_group ON group_sender_keys(group_id);

-- ===== PINNED MESSAGES =====
CREATE TABLE IF NOT EXISTS pinned_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  message_id UUID NOT NULL,
  pinned_by TEXT NOT NULL,
  pinned_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(group_id, message_id)
);

-- ===== RLS POLICIES (SECURE) =====

ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_sender_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE pinned_messages ENABLE ROW LEVEL SECURITY;

-- Groups: readable by members only
CREATE POLICY "Members can read groups" ON groups
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = groups.id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Group members: readable by group members
CREATE POLICY "Members can read group members" ON group_members
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members gm
      WHERE gm.group_id = group_members.group_id
        AND gm.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Group messages: readable by group members
CREATE POLICY "Members can read group messages" ON group_messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = group_messages.group_id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Group messages: insertable by group members
CREATE POLICY "Members can send group messages" ON group_messages
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = group_messages.group_id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Group invites: readable by group members
CREATE POLICY "Members can read invites" ON group_invites
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = group_invites.group_id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Group sender keys: readable by group members
CREATE POLICY "Members can read sender keys" ON group_sender_keys
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = group_sender_keys.group_id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- Pinned messages: readable by group members
CREATE POLICY "Members can read pinned messages" ON pinned_messages
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM group_members
      WHERE group_members.group_id = pinned_messages.group_id
        AND group_members.nova_id = current_setting('request.jwt.claims', true)::json->>'nova_id'
    )
  );

-- ===== REALTIME =====
ALTER PUBLICATION supabase_realtime ADD TABLE group_messages;
ALTER PUBLICATION supabase_realtime ADD TABLE group_members;

-- ===== DATABASE FUNCTIONS =====

-- Update group member count
CREATE OR REPLACE FUNCTION update_group_member_count()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE groups SET member_count = member_count + 1 WHERE id = NEW.group_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE groups SET member_count = member_count - 1 WHERE id = OLD.group_id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trigger_group_member_count
  AFTER INSERT OR DELETE ON group_members
  FOR EACH ROW
  EXECUTE FUNCTION update_group_member_count();

SELECT 'FASE 8 groups system created successfully' AS status;
