-- =====================================================================
--  NOVAAPP — MIGRACIÓN 002: motor de mensajería (FASE 1)
-- =====================================================================
--
--  Uso:  Supabase → SQL Editor → pegar → Run
--        Ejecutar DESPUÉS de supabase/novaapp_schema.sql
--
--  §43: migración ADITIVA en archivo nuevo. NO edita destructivamente
--  novaapp_schema.sql y NO borra ninguna tabla ni dato.
--
--  §32 (no duplicar tablas): antes de crear nada se comprobó qué existe.
--  Se REUTILIZAN sin cambios:
--    realtime_messages              sobres E2EE + server_seq
--    realtime_events                log de eventos + log_seq (sync)
--    realtime_cursors               contadores atómicos
--    realtime_conversation_members  membresía (autorización)
--    blocked_users                  bloqueo (§29)
--    user_settings                  privacidad (§28)
--    devices                        identidad y estado por dispositivo
--
--  Sólo se añade lo que NO tenía equivalente:
--    realtime_conversations   metadata de conversación (sólo había membresía)
--    realtime_media_objects   objetos multimedia cifrados (§23/§24)
--
--  IDEMPOTENTE: reejecutable sin error.
--
--  Fecha: 2026-08-25
-- =====================================================================


-- =====================================================================
--  §1  CONVERSACIONES
-- =====================================================================
--  Antes sólo existía la membresía (realtime_conversation_members). El
--  motor necesita además metadata: cuándo se creó, tipo, y el TTL de
--  mensajes temporales de la conversación (§22).
--
--  `conversation_id` es un UUID OPACO generado por el cliente, nunca
--  derivado de los participantes: un id derivado (p. ej. hash(A|B))
--  permitiría a cualquiera sondear si dos cuentas concretas hablan.

CREATE TABLE IF NOT EXISTS realtime_conversations (
  conversation_id     text PRIMARY KEY,
  kind                text   NOT NULL DEFAULT 'direct',  -- direct | group
  created_at_ms       bigint NOT NULL,
  created_by          text,                              -- account_id
  -- TTL de mensajes temporales, en segundos. NULL = desactivado (§22).
  disappearing_ttl_s  integer,
  last_activity_ms    bigint
);

CREATE INDEX IF NOT EXISTS realtime_conversations_activity_idx
  ON realtime_conversations (last_activity_ms DESC);


-- =====================================================================
--  §2  OBJETOS MULTIMEDIA CIFRADOS (§23, §24)
-- =====================================================================
--  El servidor guarda BYTES OPACOS. La clave de cada objeto viaja dentro
--  del ciphertext del mensaje, así que este registro NO permite descifrar
--  nada: sólo sirve para autorizar la descarga y aplicar retención.
--
--  Deliberadamente NO se almacena:
--    * la clave del objeto        (viaja E2EE dentro del mensaje)
--    * el nombre real del archivo (es contenido; va cifrado)
--    * el tipo MIME real          (idem; filtra qué envía el usuario)
--
--  `object_id` es aleatorio de 256 bits y sin relación con la
--  conversación: la ruta de almacenamiento no filtra el grafo social.

CREATE TABLE IF NOT EXISTS realtime_media_objects (
  object_id        text PRIMARY KEY,
  owner_account_id text   NOT NULL,
  conversation_id  text   NOT NULL,
  -- Tamaño del BLOB CIFRADO (para cuotas y retención), no del original.
  size_bytes       bigint NOT NULL,
  created_at_ms    bigint NOT NULL,
  -- Caducidad de retención: pasada esta fecha el blob puede borrarse.
  expires_at_ms    bigint,
  -- Marca de borrado lógico; el barrido físico lo hace un worker.
  deleted          boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS realtime_media_objects_owner_idx
  ON realtime_media_objects (owner_account_id);
CREATE INDEX IF NOT EXISTS realtime_media_objects_expiry_idx
  ON realtime_media_objects (expires_at_ms)
  WHERE deleted = false;


-- =====================================================================
--  §3  RECIBOS POR DISPOSITIVO (§17)
-- =====================================================================
--  §17: "El estado debe ser específico por destinatario/dispositivo".
--  Un mensaje enviado a 3 dispositivos tiene 3 estados independientes;
--  un único booleano mentiría.
--
--  No hay tabla equivalente: realtime_events registra que el recibo
--  ocurrió (para el sync), pero no el estado ACTUAL consultable por
--  (mensaje, dispositivo).

CREATE TABLE IF NOT EXISTS realtime_delivery_receipts (
  message_id    text   NOT NULL,
  device_id     text   NOT NULL,
  account_id    text   NOT NULL,
  -- 'delivered' | 'read'. 'sent' no se almacena: es el ack del servidor.
  state         text   NOT NULL,
  updated_at_ms bigint NOT NULL,
  PRIMARY KEY (message_id, device_id)
);

CREATE INDEX IF NOT EXISTS realtime_delivery_receipts_message_idx
  ON realtime_delivery_receipts (message_id);


-- =====================================================================
--  §4  ROW LEVEL SECURITY — DENY BY DEFAULT (§33)
-- =====================================================================
--  Igual que el resto del tier realtime: RLS activo y NINGUNA política
--  para anon/authenticated. Sólo el service_role del backend (que omite
--  RLS por diseño) accede. La ausencia de políticas es intencionada.
--
--  El cliente nunca lee estas tablas directamente: pasa por el protocolo
--  realtime, que autoriza por membresía en cada evento.

ALTER TABLE realtime_conversations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_media_objects       ENABLE ROW LEVEL SECURITY;
ALTER TABLE realtime_delivery_receipts   ENABLE ROW LEVEL SECURITY;

-- FORCE: aplica RLS incluso al propietario de la tabla.
ALTER TABLE realtime_conversations     FORCE ROW LEVEL SECURITY;
ALTER TABLE realtime_media_objects     FORCE ROW LEVEL SECURITY;
ALTER TABLE realtime_delivery_receipts FORCE ROW LEVEL SECURITY;

REVOKE ALL ON realtime_conversations, realtime_media_objects,
              realtime_delivery_receipts
  FROM anon, authenticated;


-- =====================================================================
--  §5  RETENCIÓN DE MULTIMEDIA (§22, §24)
-- =====================================================================
--  Marca como borrables los objetos caducados. El borrado físico en
--  Storage lo hace un worker del backend: PostgREST no puede borrar
--  blobs, y hacerlo aquí daría una falsa sensación de completitud.
--
--  §22 obliga a ser explícito: esto elimina la copia del SERVIDOR. NO
--  puede eliminar lo que un usuario ya descargó, exportó o capturó.

CREATE OR REPLACE FUNCTION nova_expire_media_objects()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE realtime_media_objects
     SET deleted = true
   WHERE deleted = false
     AND expires_at_ms IS NOT NULL
     AND expires_at_ms < (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION nova_expire_media_objects() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION nova_expire_media_objects() TO service_role;


-- =====================================================================
--  §6  VERIFICACIÓN
-- =====================================================================

DO $$
DECLARE
  v_tables integer;
BEGIN
  SELECT COUNT(*) INTO v_tables
    FROM information_schema.tables
   WHERE table_schema = 'public'
     AND table_name IN ('realtime_conversations',
                        'realtime_media_objects',
                        'realtime_delivery_receipts');
  IF v_tables <> 3 THEN
    RAISE EXCEPTION 'Migración 002 incompleta: % de 3 tablas', v_tables;
  END IF;
  RAISE NOTICE 'NovaApp FASE 1: 3 tablas del motor de mensajería listas.';
END
$$;

SELECT 'NovaApp — migración 002 (motor de mensajería) aplicada' AS status;
