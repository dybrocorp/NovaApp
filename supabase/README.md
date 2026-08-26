# supabase/ — esquema de base de datos de NovaApp

## Cómo aplicarlo

1. Supabase → **SQL Editor** → **New query**
2. Pegar el contenido completo de **`novaapp_schema.sql`**
3. **Run**

Al terminar debe aparecer:

```
NovaApp — esquema unificado aplicado correctamente
```

Y un aviso con el recuento, por ejemplo:
`NOTICE: NovaApp: 34 tablas y 66 políticas RLS en el esquema public.`

## Propiedades del archivo

| | |
|---|---|
| **Idempotente** | Se puede ejecutar tantas veces como haga falta. Todo usa `IF NOT EXISTS`, `CREATE OR REPLACE` y `DROP ... IF EXISTS` antes de crear políticas y triggers. |
| **No destructivo** | No borra ninguna tabla ni dato. El bloque de reinicio total está **comentado** en la §15. |
| **Ordenado** | extensiones → tablas → funciones → triggers → RLS → publicación → permisos. |
| **Completo** | Cubre las 20 tablas y los 4 RPC que la app usa, más las 8 tablas y 2 RPC del servidor realtime. |

## Qué unifica

Este archivo reemplaza a seis archivos que había en la raíz del repo, más
el esquema del tier realtime:

| Archivo antiguo | Contenido → sección nueva |
|---|---|
| `supabase_setup.sql` | users, messages, contacts, call_history, reports, blocked_users → §2, §4 |
| `supabase_x3dh_migration.sql` | signed_pre_keys, one_time_pre_keys, crypto_sessions → §3 |
| `supabase_auth_migration.sql` | accounts, devices, sessions, auth_challenges → §2 |
| `supabase_chat_enhancement_migration.sql` | reacciones, typing, campos de mensaje → §4, §5 |
| `supabase_groups_migration.sql` | grupos y claves de grupo → §6 |
| `supabase_security_migration.sql` | corrección de RLS (`auth_nova_id()`) → §10.1, §12 |
| `server/sql/realtime_schema.sql` | tier realtime → §9 |

Los archivos antiguos siguen en el repositorio sólo como referencia
histórica. **No los ejecutes**: ejecutar `supabase_setup.sql` borraría los
mensajes y contactos existentes (empezaba con `DROP TABLE ... CASCADE`).

## Errores corregidos al unificar

Ejecutados y verificados contra **PostgreSQL 16.2 real** (13 escenarios,
ver "Validación ejecutada" más abajo).

0. **`ERROR: 42703: column "device_id" does not exist` al aplicarlo sobre
   un proyecto ya existente.** `CREATE TABLE IF NOT EXISTS` no modifica
   una tabla que ya existe: si el proyecto tenía una versión antigua de
   `devices` (sin `account_id`/`public_key`), la sentencia se saltaba en
   silencio y el `CREATE INDEX ... ON devices(device_id)` posterior
   fallaba. Afectaba igual a `sessions`, `device_approvals` y
   `registration_attempts`. → **§1.5** reconcilia las 255 columnas
   declaradas con `ADD COLUMN IF NOT EXISTS` antes de crear índices y
   políticas, y **§1.4** aborta pronto y con instrucciones si una columna
   existe con un tipo incompatible.

1. **`auth_challenge_request` no funcionaba nunca.** Declaraba
   `v_random BYTES`; el tipo `BYTES` no existe en PostgreSQL (es sintaxis
   de CockroachDB). La función fallaba en ejecución cada vez que se
   pedía un challenge de login. → `bytea`.

2. **Colisión de la tabla `messages`.** La app y el servidor realtime
   definían dos tablas `messages` con esquemas incompatibles (la de la
   app: `chat_id/text/timestamp`; la del realtime: `message_id/ciphertext/
   server_seq`). La que se aplicara segunda dejaba rota a la otra. → El
   tier realtime usa el prefijo `realtime_`.

3. **Colisión de la tabla `contacts`.** App: `user_nova_id/contact_id`.
   Realtime: `account_id/peer_id/blocked`. → `realtime_contacts`.

4. **`devices` no servía para el handshake.** Le faltaban `account_id` y
   `public_key`, que el servidor realtime necesita para verificar la
   firma Ed25519 contra la clave registrada. → Columnas añadidas.

5. **No se podía reejecutar.** Triggers y políticas sin `DROP` previo
   abortaban con "already exists" en la segunda pasada.

6. **`ALTER PUBLICATION ... ADD TABLE` fallaba** si la tabla ya estaba
   publicada. → Bucle idempotente que comprueba `pg_publication_tables`.

7. **Seis tablas que la app usaba no existían en ningún archivo:**
   `calls`, `call_participants`, `device_approvals`, `rate_limits`,
   `registration_attempts`, `user_settings`. Todas las consultas contra
   ellas fallaban en silencio (van dentro de `try/catch`).

8. **El RPC `check_rate_limit` no existía**, pero `anti_spam_service.dart`
   lo llamaba: el rate limiting de la app no hacía nada.

9. **`profiles` no existía.** `moderation_service.dart` la consulta para
   leer `reports_count` e `is_shadowbanned`; al fallar en silencio, el
   shadowban nunca se detectaba. → Vista de compatibilidad con
   `security_invoker = on` (no abre ningún acceso nuevo).

## Correcciones de seguridad aplicadas

- **`accounts` exponía los hashes de PIN.** Tenía una política
  `FOR SELECT USING (true)` ("Public can check nova_id existence") que
  hacía legibles `pin_hash` y `pin_salt` para cualquiera. Eliminada: la
  comprobación de disponibilidad de un Nova ID se hace contra
  `public.users`, que sólo expone campos de perfil.
- **`auth_challenges` era manipulable por cualquiera.** Tenía
  `FOR ALL USING (true)`: un cliente podía leer y alterar challenges
  ajenos. Ahora no tiene ninguna política: sólo el `service_role`.
- **`group_sender_keys` filtraba las claves de todos los miembros.** La
  política dejaba a cualquier miembro leer las claves cifradas del resto.
  Ahora cada miembro sólo lee la suya.
- **`group_messages` no comprobaba el emisor al insertar.** Un miembro
  podía escribir mensajes en nombre de otro. Ahora se exige
  `sender_id = auth_nova_id()`.
- **Reacciones y typing eran legibles sin autenticar** (`USING (true)`).
  Ahora exigen al menos una sesión (`auth.uid() IS NOT NULL`).
- **`rate_limits` y `registration_attempts` son sólo de backend.** Si un
  cliente pudiera borrar filas, el anti-abuso sería inútil.
- **Las OPK sólo las puede consumir alguien autenticado.** Antes el
  `DELETE` era `USING (true)`, así que un anónimo podía agotar las
  pre-claves de cualquier usuario. Riesgo residual documentado abajo.

## Modelo de seguridad

- **`auth_nova_id()`** traduce `auth.uid()` (UUID) → `nova_id` (TEXT). Es
  la base de casi todas las políticas. Comparar directamente un UUID con
  una columna `nova_id` TEXT nunca coincide, y ése era el origen de las
  políticas rotas que corrigió `supabase_security_migration.sql`.
- **Las tablas `realtime_*` son deny-by-default**: tienen RLS activo y
  ninguna política. Sólo el `service_role` (que omite RLS por diseño) las
  alcanza, y ese rol vive exclusivamente en el backend. Nunca debe ir en
  la app ni en un bundle de cliente.
- **Las tablas `realtime_*` no se publican en Realtime de Supabase.** El
  fan-out en vivo lo hace el servidor Socket.IO. Publicarlas expondría
  ciphertext y metadata a cualquier suscriptor.
- El servidor realtime sólo almacena **ciphertext opaco + metadata**. No
  tiene material de claves y no puede descifrar mensajes.

## Riesgos conocidos (no resueltos por este archivo)

- **`auth_challenge_verify` no emite un JWT real.** Devuelve un marcador
  (`jwt_placeholder_...`). La emisión debe hacerla una Edge Function con
  la service role key. Se mantiene tal cual porque cambiarlo requiere
  tocar el flujo de login de la app.
- **Las OPK se pueden agotar.** Consumir una pre-clave es borrarla, así
  que un usuario autenticado puede vaciar las de otro. Mitigación:
  reposición periódica desde el cliente y caída elegante a X3DH sin OPK.
- **`users` es de lectura pública.** Es un requisito para descubrir
  contactos e iniciar X3DH. Los campos internos (`email`, `fcm_token`) se
  protegen limitando las columnas que la app selecciona, no por RLS: si
  necesitas garantía a nivel de base de datos, muévelos a una tabla
  aparte.
- **Las políticas RLS no se han probado con usuarios reales.** El archivo
  se aplica sin errores contra PostgreSQL 16.2 y las 66 políticas se
  crean, pero no se ha ejercitado el comportamiento de cada política con
  JWT reales de Supabase (`auth.uid()` se simuló). Verifica tras
  aplicarlo (§siguiente).
- **No aplicado a un proyecto Supabase en vivo desde este entorno.** Las
  pruebas usan PostgreSQL 16.2 local con `auth.users`, `auth.uid()` y los
  roles `anon`/`authenticated`/`service_role` simulados.

## Validación ejecutada

`novaapp_schema.sql` se ejecutó contra PostgreSQL 16.2 real en estos 13
escenarios, todos con `ON_ERROR_STOP=1` y en una única transacción:

| Escenario | Resultado |
|---|---|
| Base de datos limpia | PASA |
| Base limpia, 3 pasadas seguidas (idempotencia) | PASA |
| Proyecto con `devices` antigua (**el error reportado**) | PASA |
| Proyecto con `sessions` antigua | PASA |
| Proyecto con `device_approvals` antigua | PASA |
| Proyecto con `registration_attempts` antigua | PASA |
| Sobre `supabase_auth_migration.sql` legacy | PASA |
| Sobre los 6 archivos legacy aplicados | PASA |
| Los 6 legacy + 2 pasadas del esquema | PASA |
| Legacy + datos sembrados + 2 pasadas (no destrucción) | PASA, 0 filas perdidas |
| Limpia + `migrations/002_phase1_messaging.sql` | PASA |
| Limpia + 002 aplicada dos veces | PASA |
| Legacy + esquema + 002 | PASA |

Además se comprueba que una columna con **tipo** incompatible (p. ej.
`devices.device_id` como UUID) aborta en §1.4 con un mensaje accionable
en vez de morir 300 líneas después con un error de clave foránea.

Estado final verificado tras la ruta legacy completa: 34 tablas, 66
políticas, `devices` con sus 14 columnas, los 4 índices críticos creados
y las 7 tablas `realtime_*` con RLS activo y 0 políticas.

## Verificación tras aplicar

```sql
-- 1. Tablas creadas (deben ser 34 + la vista profiles)
SELECT COUNT(*) FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

-- 2. Ninguna tabla sin RLS
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
  AND tablename NOT IN (SELECT tablename FROM pg_tables t
                        JOIN pg_class c ON c.relname = t.tablename
                        WHERE c.relrowsecurity);

-- 3. El tier realtime debe ser invisible para los clientes
SELECT tablename, COUNT(policyname) AS policies
FROM pg_tables LEFT JOIN pg_policies USING (schemaname, tablename)
WHERE schemaname = 'public' AND tablename LIKE 'realtime_%'
GROUP BY tablename;   -- todas deben dar 0

-- 4. El RPC de secuencia funciona y es monótono
SELECT nova_next_seq('conv-test'), nova_next_seq('conv-test');  -- 1, 2
```

Prueba manual recomendada con la anon key (debe devolver 0 filas):

```bash
curl "$SUPABASE_URL/rest/v1/realtime_messages?select=*" \
  -H "apikey: $SUPABASE_ANON_KEY"
```

## Configuración del servidor realtime

```env
STORE_BACKEND=supabase
SUPABASE_URL=https://<proyecto>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<service role key — SÓLO en el backend>
```

Sin `STORE_BACKEND=supabase` el servidor usa el almacén en memoria y un
reinicio pierde el historial caliente.
