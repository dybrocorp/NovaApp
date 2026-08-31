# supabase/test — pruebas de aplicación del esquema

Ejecutan `supabase/novaapp_schema.sql` contra un **PostgreSQL real** en
varios escenarios de despliegue previo.

## Por qué existen

El esquema se aplicaba sin problemas en una base vacía, pero fallaba en un
proyecto que ya tenía tablas antiguas:

```
ERROR: 42703: column "device_id" does not exist
```

Validar la sintaxis con libpg_query **no** detecta ese fallo: el SQL es
sintácticamente correcto y sólo revienta al ejecutarse contra un esquema
preexistente. Estas pruebas lo ejecutan de verdad.

## Cómo ejecutarlas

No hacen falta Docker ni un Postgres instalado: `pgserver` trae sus
binarios y levanta una instancia efímera y desechable.

```bash
python3 -m venv /tmp/pgvenv
/tmp/pgvenv/bin/pip install pgserver
/tmp/pgvenv/bin/python supabase/test/run_schema_tests.py
```

Salida esperada:

```
14/14 comprobaciones OK

Estado final: 34 tablas, 66 políticas RLS, devices con 14 columnas.
Datos preservados: 1 dispositivo(s), 1 mensaje(s).
```

## Qué cubren

- Base limpia, y tres pasadas seguidas (idempotencia).
- Proyectos con `devices`, `sessions`, `device_approvals` o
  `registration_attempts` en una versión antigua.
- La ruta de upgrade real: los 6 archivos de `supabase/legacy/` aplicados
  y luego el esquema unificado encima.
- No destrucción: se siembran filas y se comprueba que sobreviven a dos
  pasadas más del esquema.
- `migrations/002_phase1_messaging.sql` encima, una y dos veces.
- Escenario negativo: una columna con el **tipo** equivocado debe abortar
  en §1.4 con un mensaje accionable, no morir después con un error de
  clave foránea.

## Limitaciones

- `pgserver` no incluye `uuid-ossp` ni `pgcrypto`; `shim.sql` aporta
  `uuid_generate_v4()` y `gen_random_bytes()` equivalentes. En Supabase
  real ambas extensiones existen y el `CREATE EXTENSION` se ejecuta.
- `base.sql` simula el entorno Supabase (`auth.users`, `auth.uid()`, los
  roles `anon`/`authenticated`/`service_role`). **No** se ejercita el
  comportamiento de las políticas RLS con JWT reales: se comprueba que se
  crean, no a quién dejan pasar. Eso lo cubre `run_rls_tests.py`: 23 comprobaciones
  ejecutadas de permiter/denegar con `SET ROLE authenticated` y claims JWT
  idénticos a los que inyecta Supabase.
- La versión probada es PostgreSQL 16.2.
