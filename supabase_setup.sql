-- Pega esto en: Supabase → SQL Editor → Run
-- Configuración de base de datos para NovaApp usando la tabla 'users' (en lugar de 'profiles')

-- 1. Habilitar extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Eliminar tablas existentes para evitar conflictos
DROP TABLE IF EXISTS call_history CASCADE;
DROP TABLE IF EXISTS contacts CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS public.users CASCADE;

-- 3. Tabla users (identidad + clave pública E2EE)
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT, -- Email opcional
  name TEXT, -- Nombre del perfil
  nova_id TEXT UNIQUE, -- Nova ID único del usuario (visible públicamente)
  display_name TEXT, -- Apodo opcional
  avatar_url TEXT,
  public_key TEXT, -- Clave pública X25519 para E2EE
  fcm_token TEXT, -- Token de Firebase Cloud Messaging para notificaciones push
  privacy_level TEXT DEFAULT 'anyone', -- 'anyone', 'qr_only'
  is_online BOOLEAN DEFAULT false,
  last_seen TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para users
CREATE INDEX IF NOT EXISTS idx_users_nova_id ON public.users(nova_id);
CREATE INDEX IF NOT EXISTS idx_users_display_name ON public.users(display_name);

-- 4. Tabla messages (mensajes cifrados en tiempo real)
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id TEXT NOT NULL, -- ID del chat/contacto
  sender_id TEXT NOT NULL, -- ID del remitente
  text TEXT, -- Texto cifrado
  media_url TEXT,
  type TEXT DEFAULT 'text',
  timestamp TEXT NOT NULL,
  is_me INTEGER DEFAULT 0,
  status TEXT DEFAULT 'sent',
  poll_data JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para messages
CREATE INDEX IF NOT EXISTS idx_messages_chat_id ON messages(chat_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp DESC);

-- 5. Tabla contacts
CREATE TABLE IF NOT EXISTS contacts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  contact_name TEXT,
  verification_level TEXT DEFAULT 'level1',
  last_message TEXT,
  last_message_time TIMESTAMP WITH TIME ZONE,
  is_archived INTEGER DEFAULT 0,
  is_blocked INTEGER DEFAULT 0,
  is_favorite INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(user_nova_id, contact_id)
);

-- 6. Tabla call_history
CREATE TABLE IF NOT EXISTS call_history (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  contact_name TEXT,
  call_type TEXT NOT NULL,
  direction TEXT NOT NULL,
  duration INTEGER,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  status TEXT DEFAULT 'completed'
);

-- Triggers y funciones de actualización automática
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_contacts_updated_at
    BEFORE UPDATE ON contacts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Trigger para crear usuario en public.users al registrarse en auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
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
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- Activar Realtime (WebSockets)
DROP PUBLICATION IF EXISTS supabase_realtime;
CREATE PUBLICATION supabase_realtime;
ALTER PUBLICATION supabase_realtime ADD TABLE messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.users;
ALTER PUBLICATION supabase_realtime ADD TABLE contacts;

-- Habilitar Row Level Security (RLS)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_history ENABLE ROW LEVEL SECURITY;

-- Políticas de RLS
CREATE POLICY "Permitir lectura pública de usuarios" ON public.users FOR SELECT USING (true);
CREATE POLICY "Permitir inserción de propio usuario" ON public.users FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Permitir actualización de propio usuario" ON public.users FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Permitir todo en mensajes" ON messages FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en contactos" ON contacts FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en llamadas" ON call_history FOR ALL USING (true) WITH CHECK (true);

-- 7. Tabla reports (reportes de usuarios)
CREATE TABLE IF NOT EXISTS reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  reported_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  reason TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(reporter_id, reported_id)
);

-- 8. Tabla blocked_users (usuarios bloqueados)
CREATE TABLE IF NOT EXISTS blocked_users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  blocked_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(blocker_id, blocked_id)
);

-- 9. Índices para reports y blocked_users
CREATE INDEX IF NOT EXISTS idx_reports_reporter_id ON reports(reporter_id);
CREATE INDEX IF NOT EXISTS idx_reports_reported_id ON reports(reported_id);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocker_id ON blocked_users(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocked_users_blocked_id ON blocked_users(blocked_id);

-- 10. Función para incrementar reports_count y shadowban automático
CREATE OR REPLACE FUNCTION public.handle_new_report()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.users
    SET reports_count = COALESCE(reports_count, 0) + 1,
        is_shadowbanned = CASE WHEN COALESCE(reports_count, 0) + 1 >= 3 THEN TRUE ELSE COALESCE(is_shadowbanned, FALSE) END
    WHERE id = NEW.reported_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. Trigger para handle_new_report
DROP TRIGGER IF EXISTS on_new_report ON reports;
CREATE TRIGGER on_new_report
    AFTER INSERT ON reports
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_report();

-- 12. Agregar columnas faltantes a users
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS reports_count INTEGER DEFAULT 0;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS is_shadowbanned BOOLEAN DEFAULT false;

-- 13. Actualizar políticas de RLS para nuevas tablas
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocked_users ENABLE ROW LEVEL SECURITY;

-- Políticas para reports
DROP POLICY IF EXISTS "Permitir todo en reports" ON reports;
CREATE POLICY "Permitir todo en reports" ON reports FOR ALL USING (true) WITH CHECK (true);

-- Políticas para blocked_users
DROP POLICY IF EXISTS "Permitir todo en blocked_users" ON blocked_users;
CREATE POLICY "Permitir todo en blocked_users" ON blocked_users FOR ALL USING (true) WITH CHECK (true);

-- 14. Agregar tablas a publicación realtime
ALTER PUBLICATION supabase_realtime ADD TABLE reports;
ALTER PUBLICATION supabase_realtime ADD TABLE blocked_users;

SELECT 'Configuración de base de datos de NovaApp completada exitosamente' AS status;
