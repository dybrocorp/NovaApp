-- Pega esto en: Supabase → SQL Editor → Run

-- 1. Tabla profiles (identidad + clave pública E2EE)
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY,
  display_name TEXT,
  public_key TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- 2. Tabla messages (mensajes cifrados en tiempo real)
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "chatId" TEXT NOT NULL,
  "senderId" TEXT,
  text TEXT,
  "mediaUrl" TEXT,
  type TEXT DEFAULT 'text',
  timestamp TEXT,
  "isMe" INTEGER DEFAULT 0,
  status TEXT DEFAULT 'sent',
  created_at TIMESTAMP DEFAULT NOW()
);

-- 3. Activar Realtime (WebSockets) en messages
ALTER PUBLICATION supabase_realtime ADD TABLE messages;

-- 4. Políticas de acceso (Row Level Security)
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Permitir acceso público temporal (ajustar con auth luego)
CREATE POLICY "Allow all messages" ON messages FOR ALL USING (true);
CREATE POLICY "Allow all profiles" ON profiles FOR ALL USING (true);
