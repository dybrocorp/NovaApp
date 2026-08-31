#!/usr/bin/env python3
"""
Pruebas REALES de RLS de NovaApp contra PostgreSQL (complemento de
run_schema_tests.py).

run_schema_tests.py comprueba que el esquema SE APLICA (tablas, 66
políticas creadas, idempotencia, upgrade legacy). Este archivo comprueba
lo que las políticas HACEN: quién pasa y quién no, ejecutando las
tentativas del cliente desde el rol `authenticated` con la reclamación
JWT de otra cuenta — exactamente el ataque que la FASE 1.1 exige:

  - leer conversación ajena            (realtime_messages/realtime_events)
  - insertar mensaje como otro usuario (messages, realtime_messages)
  - leer claves de otro dispositivo    (devices, crypto_sessions)
  - modificar datos de otra cuenta     (accounts, users, sessions, messages)
  - acceder a sesiones ajenas          (sessions)
  - el canal de tabla NO es la API del cliente: realtime_* está cerrado
    incluso para el dueño; sólo service_role (el servidor) lee/escribe
  - positivos: cada dueño sí puede con lo suyo (evita falsos verdes por
    permisos de GRANT ausentes)

Emulación de Supabase: base.sql simula auth.users/auth.uid()/roles; aquí
además se concede `GRANT ALL ... TO authenticated` para que el cortocircuito
que bloquea al atacante sea la RLS y NO la ausencia de permisos (en un
proyecto Supabase real esos GRANT los pone el bootstrap del proyecto).

Uso:
    python3 -m venv /tmp/pgvenv && /tmp/pgvenv/bin/pip install pgserver
    /tmp/pgvenv/bin/python supabase/test/run_rls_tests.py
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import uuid

try:
    import pgserver
except ImportError:  # pragma: no cover
    sys.exit('Falta la dependencia: pip install pgserver')

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run_schema_tests import prepare  # noqa: E402

PSQL = str(pathlib.Path(pgserver.__file__).parent / 'pginstall' / 'bin' / 'psql')

A_ID, B_ID, C_ID = (str(uuid.uuid4()) for _ in range(3))
NOW_MS = 1_700_000_000_000

SEED = f"""
INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('{A_ID}', 'a@nova.test', '{{"nova_id": "novaA"}}'),
  ('{B_ID}', 'b@nova.test', '{{"nova_id": "novaB"}}'),
  ('{C_ID}', 'c@nova.test', '{{"nova_id": "novaC"}}');
INSERT INTO accounts (nova_id, pin_hash, pin_salt) VALUES
  ('novaA', 'h', 's'), ('novaB', 'h', 's'), ('novaC', 'h', 's');
INSERT INTO devices (nova_id, device_id, device_name, platform) VALUES
  ('novaA', 'devA1', 'Pixel', 'android'),
  ('novaB', 'devB1', 'iPhone', 'ios');
INSERT INTO sessions (nova_id, device_id, jwt_token_hash, expires_at) VALUES
  ('novaA', 'devA1', 'hashA', NOW() + INTERVAL '1 day');
INSERT INTO contacts (user_nova_id, contact_id) VALUES
  ('novaB', 'novaA'), ('novaA', 'novaC');
INSERT INTO messages (chat_id, sender_id, text, timestamp, type) VALUES
  ('chatAB', 'novaA', 'hola B', '2026-01-01T00:00:00Z', 'text'),
  ('chatA',  'novaC', 'mensaje a chat de A', '2026-01-02T00:00:00Z', 'text');
INSERT INTO crypto_sessions (sender_nova_id, receiver_nova_id, ephemeral_public_key) VALUES
  ('novaA', 'novaB', 'ephAB'),
  ('novaA', 'novaC', 'ephAC');
INSERT INTO realtime_conversations (conversation_id, created_at_ms, created_by)
  VALUES ('conv-1', {NOW_MS}, 'novaA');
INSERT INTO realtime_messages
  (message_id, conversation_id, sender_account_id, sender_device_id,
   ciphertext, header_type, server_seq, received_at_ms) VALUES
  ('m-1', 'conv-1', 'novaA', 'devA1', 'Q1VCTEVSSVRPLUNJTFA=', 'dr.v1', 1, {NOW_MS}),
  ('m-2', 'conv-1', 'novaB', 'devB1', 'Q1VCTEVSSVRPLVRKT0==', 'dr.v1', 2, {NOW_MS + 1});
INSERT INTO realtime_events (conversation_id, type, server_seq, log_seq, at_ms, payload)
  VALUES ('conv-1', 'message.new', 1, 1, {NOW_MS}, '{{"message_id": "m-1"}}'::jsonb);
-- Emular el bootstrap de permisos de Supabase para que sea la RLS
-- (y no un GRANT ausente) la que bloquee al atacante:
GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
"""

# (nombre, rol, sub, sql, modo) — modo: ('count', esperado) | ('error',) | ('rows', esperado)


# (nombre, rol, sub-uuid o None, nova_id en claims o None, sql, modo)
# Los modos: ('count', esperado) | ('error',). Los UPDATE/DELETE se envuelven
# en CTEs para poder CONTAR filas afectadas (0 = la RLS las filtró).
def _probe(name, role, sub, nova, sql, mode):
    return (name, role, sub, nova, sql, mode)

PROBES = [
    # --- el atacante NO es nadie ------------------------------------
    _probe('anon no lee mensajes (auth.uid() NULL)',
           'anon', None, None, 'SELECT count(*) FROM messages;', ('count', '0')),
    # --- tabla realtime_*: la API del cliente NO es la tabla --------
    _probe('B no ve realtime_messages ajenos',
           'authenticated', B_ID, 'novaB',
           "SELECT count(*) FROM realtime_messages WHERE sender_account_id='novaA';",
           ('count', '0')),
    _probe('B no ve NINGUN realtime_message (sin políticas para clientes)',
           'authenticated', B_ID, 'novaB',
           'SELECT count(*) FROM realtime_messages;', ('count', '0')),
    _probe('A no puede INSERTar en realtime_messages (sólo el servidor escribe)',
           'authenticated', A_ID, 'novaA',
           "INSERT INTO realtime_messages (message_id, conversation_id,"
           " sender_account_id, sender_device_id, ciphertext, header_type,"
           " server_seq, received_at_ms) VALUES ('x-1','conv-1','novaA',"
           "'devA1','Yw==','dr.v1',9,9);", ('error',)),
    _probe('B no ve realtime_events',
           'authenticated', B_ID, 'novaB',
           'SELECT count(*) FROM realtime_events;', ('count', '0')),
    # --- mensajes legados: política de remitente/contacto -----------
    _probe('B sólo ve el mensaje que A le envió (contacto)',
           'authenticated', B_ID, 'novaB',
           'SELECT count(*) FROM messages;', ('count', '1')),
    _probe('C no ve el mensaje de A a B',
           'authenticated', C_ID, 'novaC',
           "SELECT count(*) FROM messages WHERE chat_id='chatAB';", ('count', '0')),
    _probe('B NO puede insertar un mensaje suplantando a novaA',
           'authenticated', B_ID, 'novaB',
           "INSERT INTO messages (chat_id, sender_id, text, timestamp, type)"
           " VALUES ('chatAB','novaA','falsificado','2026-01-03','text');",
           ('error',)),
    _probe('B no puede marcar-leído un mensaje ajeno (UPDATE filtrado)',
           'authenticated', B_ID, 'novaB',
           "WITH t AS (UPDATE messages SET status='read' WHERE sender_id='novaA'"
           " RETURNING 1) SELECT count(*) FROM t;", ('count', '0')),
    _probe('A sí puede actualizar el status de SUS mensajes (positivo)',
           'authenticated', A_ID, 'novaA',
           "WITH t AS (UPDATE messages SET status='read' WHERE sender_id='novaA'"
           " RETURNING 1) SELECT count(*) FROM t;", ('count', '1')),
    # --- identidad/cuentas -------------------------------------------
    _probe('B no puede renombrar la cuenta de A',
           'authenticated', B_ID, 'novaB',
           "WITH t AS (UPDATE accounts SET display_name='pwned'"
           " WHERE nova_id='novaA' RETURNING 1) SELECT count(*) FROM t;",
           ('count', '0')),
    _probe('B no puede mutar la fila users de A',
           'authenticated', B_ID, 'novaB',
           "WITH t AS (UPDATE public.users SET display_name='pwned'"
           " WHERE nova_id='novaA' RETURNING 1) SELECT count(*) FROM t;",
           ('count', '0')),
    _probe('B no puede crear una fila users para otra uuid',
           'authenticated', B_ID, 'novaB',
           "INSERT INTO public.users (id, nova_id) VALUES"
           " ('d0000000-0000-4000-8000-0000000000d1', 'novaFraude');",
           ('error',)),
    # --- dispositivos y claves ---------------------------------------
    _probe('B no ve los dispositivos de A (claves públicas de identidad)',
           'authenticated', B_ID, 'novaB',
           "SELECT count(*) FROM devices WHERE nova_id='novaA';", ('count', '0')),
    _probe('B no puede revocar (DELETE) el dispositivo de A',
           'authenticated', B_ID, 'novaB',
           "WITH t AS (DELETE FROM devices WHERE nova_id='novaA' RETURNING 1)"
           " SELECT count(*) FROM t;", ('count', '0')),
    _probe('A sí ve su dispositivo (positivo)',
           'authenticated', A_ID, 'novaA',
           "SELECT count(*) FROM devices WHERE nova_id='novaA';", ('count', '1')),
    _probe('A sí ve su propia cuenta (positivo)',
           'authenticated', A_ID, 'novaA',
           "SELECT count(*) FROM accounts WHERE nova_id='novaA';", ('count', '1')),
    # --- sesiones de autenticación ------------------------------------
    _probe('B no lee sesiones ajenas',
           'authenticated', B_ID, 'novaB',
           "SELECT count(*) FROM sessions WHERE nova_id='novaA';", ('count', '0')),
    _probe('A lee SUS sesiones (positivo)',
           'authenticated', A_ID, 'novaA',
           "SELECT count(*) FROM sessions WHERE nova_id='novaA';", ('count', '1')),
    _probe('B no puede DELETEar sesiones de A',
           'authenticated', B_ID, 'novaB',
           "WITH t AS (DELETE FROM sessions WHERE nova_id='novaA' RETURNING 1)"
           " SELECT count(*) FROM t;", ('count', '0')),
    # --- crypto_sessions (materiales X3DH compartidos) ----------------
    _probe('B no lee la sesión cifrada A<->C',
           'authenticated', B_ID, 'novaB',
           "SELECT count(*) FROM crypto_sessions WHERE sender_nova_id='novaA'"
           " AND receiver_nova_id='novaC';", ('count', '0')),
    _probe('B lee la sesión donde ES participante (positivo)',
           'authenticated', B_ID, 'novaB',
           "SELECT count(*) FROM crypto_sessions WHERE receiver_nova_id='novaB';",
           ('count', '1')),
    # --- verificación del diseño --------------------------------------
    _probe('service_role (el servidor Realtime) SÍ ve realtime_messages',
           'service_role', None, None,
           'SELECT count(*) FROM realtime_messages;', ('count', '2')),
]


def psql(socket: str, dbname: str, sql: str, extra: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [PSQL, '-h', socket, '-U', 'postgres', '-d', dbname,
         '-q', '-A', '-t', *extra, '-c', sql],
        capture_output=True, text=True,
    )


def main() -> int:
    tmp = pathlib.Path(tempfile.mkdtemp(prefix='novaapp-rlstest-'))
    files = prepare(tmp)
    db = pgserver.get_server(tmp / 'pgdata')
    sock = str(tmp / 'pgdata')

    db.psql('DROP DATABASE IF EXISTS rlstest;')
    db.psql('CREATE DATABASE rlstest;')
    for key in ('prelude', 'schema', 'mig002'):
        proc = subprocess.run(
            [PSQL, '-h', sock, '-U', 'postgres', '-d', 'rlstest',
             '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', str(files[key])],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(f'FAIL  aplicación de {key}:', proc.stderr.strip()[:400])
            return 1
    seed = psql(sock, 'rlstest', SEED, ['-v', 'ON_ERROR_STOP=1'])
    if seed.returncode != 0:
        print('FAIL  seed:', seed.stderr.strip()[:600])
        return 1

    failures = 0
    for name, role, sub, nova, sql, mode in PROBES:
        body = f'SET ROLE {role};'
        if sub:
            # Las dos convenciones de claims que la RLS de NovaApp lee:
            # auth.uid() <- request.jwt.claim.sub  y
            # nova_id      <- request.jwt.claims (JSON), como un JWT real.
            body += ' SET request.jwt.claim.sub = ' + "'" + sub + "';"
            claims = '{"sub":"' + sub + '","nova_id":"' + str(nova) + '"}'
            body += " SET request.jwt.claims = " + "'" + claims + "';"
        body += ' ' + sql
        proc = psql(sock, 'rlstest', body, ['-v', 'ON_ERROR_STOP=1'])
        out = proc.stdout.strip()
        if mode[0] == 'count':
            ok = proc.returncode == 0 and out == mode[1]
        else:  # 'error': la operación DEBE estar vetada por RLS
            denied = ('row-level security' in proc.stderr
                      or 'permission denied' in proc.stderr)
            ok = proc.returncode != 0 and denied
        if not ok:
            failures += 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            detail = (proc.stderr or proc.stdout).strip().splitlines()
            print('      ', detail[-1] if detail else f'salida={out!r}')

    total = len(PROBES)
    print(f'\n{total - failures}/{total} comprobaciones RLS OK')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
