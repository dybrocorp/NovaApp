#!/usr/bin/env python3
"""
Aplica supabase/novaapp_schema.sql contra un PostgreSQL REAL en varios
escenarios de despliegue previo y comprueba que no falla.

Motivo: el esquema se aplicaba sin problemas sobre una base vacía, pero
reventaba con `ERROR: 42703: column "device_id" does not exist` sobre un
proyecto que ya tenía una versión antigua de `devices`. Validar sólo la
sintaxis (libpg_query) no detecta ese fallo: hay que EJECUTARLO.

Uso:
    python3 -m venv .venv && .venv/bin/pip install pgserver
    .venv/bin/python supabase/test/run_schema_tests.py

No necesita Docker ni un Postgres instalado: `pgserver` trae sus propios
binarios y levanta una instancia efímera.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

try:
    import pgserver
except ImportError:  # pragma: no cover
    sys.exit('Falta la dependencia: pip install pgserver')

HERE = pathlib.Path(__file__).resolve().parent
SUPABASE = HERE.parent
REPO = SUPABASE.parent
LEGACY = SUPABASE / 'legacy'

# pgserver no incluye uuid-ossp ni pgcrypto. Se sustituyen por funciones
# equivalentes (shim.sql) para poder ejecutar el resto del archivo. En
# Supabase real ambas extensiones existen.
EXTENSIONS = (
    'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";',
    'CREATE EXTENSION IF NOT EXISTS "pgcrypto";',
)

# Bug conocido y ya corregido en el esquema unificado; los archivos legacy
# conservan el tipo inexistente `BYTES`, que impediría sembrarlos aquí.
LEGACY_FIXUPS = (('v_random BYTES;', 'v_random bytea;'),)

LEGACY_ORDER = (
    'supabase_setup.sql',
    'supabase_x3dh_migration.sql',
    'supabase_auth_migration.sql',
    'supabase_chat_enhancement_migration.sql',
    'supabase_groups_migration.sql',
    'supabase_security_migration.sql',
)


def prepare(tmp: pathlib.Path) -> dict[str, pathlib.Path]:
    """Materializa en `tmp` los archivos SQL que usan los escenarios."""

    def strip_extensions(text: str) -> str:
        for ext in EXTENSIONS:
            text = text.replace(ext, '-- (extensión sustituida por shim.sql)')
        return text

    files: dict[str, pathlib.Path] = {}

    prelude = (HERE / 'base.sql').read_text() + '\n' + (HERE / 'shim.sql').read_text()
    files['prelude'] = tmp / 'prelude.sql'
    files['prelude'].write_text(prelude)

    files['schema'] = tmp / 'schema.sql'
    files['schema'].write_text(strip_extensions((SUPABASE / 'novaapp_schema.sql').read_text()))

    files['mig002'] = tmp / 'mig002.sql'
    files['mig002'].write_text(
        strip_extensions((SUPABASE / 'migrations' / '002_phase1_messaging.sql').read_text()),
    )

    legacy_all = []
    for name in LEGACY_ORDER:
        text = strip_extensions((LEGACY / name).read_text())
        for old, new in LEGACY_FIXUPS:
            text = text.replace(old, new)
        legacy_all.append(f'-- ===== {name}\n{text}')
    files['legacy_all'] = tmp / 'legacy_all.sql'
    files['legacy_all'].write_text('\n'.join(legacy_all))

    auth = strip_extensions((LEGACY / 'supabase_auth_migration.sql').read_text())
    for old, new in LEGACY_FIXUPS:
        auth = auth.replace(old, new)
    files['legacy_auth'] = tmp / 'legacy_auth.sql'
    files['legacy_auth'].write_text(auth)

    for stem in ('pre_devices', 'pre_sessions', 'pre_devappr', 'pre_regattempts',
                 'pre_badtype', 'seed'):
        files[stem] = HERE / f'{stem}.sql'

    return files


def main() -> int:
    tmpdir = tempfile.mkdtemp(prefix='novaapp-sqltest-')
    tmp = pathlib.Path(tmpdir)
    files = prepare(tmp)

    db = pgserver.get_server(tmp / 'pgdata')
    psql = str(pathlib.Path(pgserver.__file__).parent / 'pginstall' / 'bin' / 'psql')
    socket = str(tmp / 'pgdata')

    def apply(dbname: str, keys: list[str]) -> tuple[bool, str]:
        db.psql(f'DROP DATABASE IF EXISTS {dbname};')
        db.psql(f'CREATE DATABASE {dbname};')
        for key in keys:
            proc = subprocess.run(
                [psql, '-h', socket, '-U', 'postgres', '-d', dbname,
                 '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', str(files[key])],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                error = next((l for l in proc.stderr.splitlines() if 'ERROR' in l), '')
                return False, f'{key}: {error}'
        return True, ''

    S, P = 'schema', 'prelude'
    scenarios: list[tuple[str, list[str]]] = [
        ('base limpia',                              [P, S]),
        ('base limpia x3 (idempotencia)',            [P, S, S, S]),
        ('devices antigua (error reportado)',        [P, 'pre_devices', S]),
        ('sessions antigua',                         [P, 'pre_sessions', S]),
        ('device_approvals antigua',                 [P, 'pre_devappr', S]),
        ('registration_attempts antigua',            [P, 'pre_regattempts', S]),
        ('sobre supabase_auth_migration legacy',     [P, 'legacy_auth', S]),
        ('sobre los 6 archivos legacy',              [P, 'legacy_all', S]),
        ('legacy + esquema x2',                      [P, 'legacy_all', S, S]),
        ('legacy + datos + esquema x2',              [P, 'legacy_all', 'seed', S, S]),
        ('limpia + migracion 002',                   [P, S, 'mig002']),
        ('limpia + 002 x2',                          [P, S, 'mig002', 'mig002']),
        ('legacy + esquema + 002',                   [P, 'legacy_all', S, 'mig002']),
    ]

    failures = 0
    for index, (name, keys) in enumerate(scenarios):
        ok, error = apply(f'novatest{index}', keys)
        print(f'{"PASS" if ok else "FAIL"}  {name}')
        if not ok:
            failures += 1
            print(f'      {error}')

    # Escenario negativo: una columna con el TIPO equivocado debe abortar
    # pronto, en §1.4, en vez de morir mucho después con un error de FK.
    ok, _ = apply('novatestbad', [P, 'pre_badtype', S])
    aborted = not ok
    print(f'{"PASS" if aborted else "FAIL"}  aborta ante un tipo incompatible')
    if not aborted:
        failures += 1

    total = len(scenarios) + 1
    print(f'\n{total - failures}/{total} comprobaciones OK')

    # Comprobación de estado final tras la ruta de upgrade legacy completa.
    apply('novatestfinal', [P, 'legacy_all', 'seed', S])
    report = subprocess.run(
        [psql, '-h', socket, '-U', 'postgres', '-d', 'novatestfinal', '-At', '-c',
         """SELECT
              (SELECT count(*) FROM information_schema.tables
                 WHERE table_schema='public' AND table_type='BASE TABLE'),
              (SELECT count(*) FROM pg_policies WHERE schemaname='public'),
              (SELECT count(*) FROM information_schema.columns
                 WHERE table_schema='public' AND table_name='devices'),
              (SELECT count(*) FROM devices),
              (SELECT count(*) FROM messages);"""],
        capture_output=True, text=True,
    )
    if report.returncode == 0:
        tables, policies, cols, devices, messages = report.stdout.strip().split('|')
        print(f'\nEstado final: {tables} tablas, {policies} políticas RLS, '
              f'devices con {cols} columnas.')
        print(f'Datos preservados: {devices} dispositivo(s), {messages} mensaje(s).')

    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
