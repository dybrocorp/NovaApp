# SOCKET_SERVER_ARCHITECTURE.md — FASE 0.5 — PASO 5

Arquitectura del **Realtime Server** de NovaApp.

Fecha: 2026-08-24 (PASO 4) · 2026-08-24 (PASO 5)

---

## 0. Estado del servidor (PASO 5)

**El servidor EXISTE y está implementado** en `server/` (Node.js 20+ /
TypeScript / Socket.IO 4). Es el puerto fiel de las especificaciones
ejecutables de `lib/core/socket/` (PASO 4) y valida contra ellas:

- Handshake criptográfico completo (`server/src/protocol/handshake_engine.ts`
  ↔ `handshake_engine.dart`), con `AUTH_FAILED` genérico en el cable.
- Sesiones (una viva por dispositivo, TTL deslizante, revocación por
  sesión y por dispositivo con fan-out `device.revoked`).
- `message.*` idempotentes (dedup por `message_id`, ack original en el
  reintento), `server_seq` por conversación, fan-out por membresía,
  receipts `delivered`/`read`.
- `sync.request/response` (replay del log de eventos por cursor).
- Presencia con audiencia privada; signaling de llamadas (relay +
  anti-spoof de identidad).
- Rate limits de servidor (token bucket por dominio + lockout de auth por
  dispositivo e IP) y límite de conexiones nuevas por IP.
- `/healthz` + API admin protegible por `ADMIN_TOKEN` (equivalente local
  del webhook de revocación); `Dockerfile` + `docker-compose.yml`.
- **E2E: 40/40** (`server/test/e2e_*.test.ts`, WebSockets reales en
  loopback con firmas Ed25519 reales). Ejecutar: `cd server && npm test`.

Pendiente para PASO 6 (multi-nodo): adapter Redis (challenges/sesiones/
dedup/cursors compartidos), caché de autorización 30 s, redis-emitter,
prueba de conmutación wifi↔móvil contra el app real. El backend de
directorio Supabase (PostgREST, service role) está cableado
(`server/src/directory/supabase_directory.ts`); el almacén caliente por
defecto es en memoria (un nodo).

## 0.bis. Resultado de la auditoría original (PASO 4)

**El repositorio NO contenía ningún servidor Socket.IO** al cerrarse el
PASO 4. Se buscó en todo el árbol (`server/`, `realtime/`, `node/`,
scripts, package.json): solo existía el cliente Flutter
(`lib/core/services/websocket_service.dart`, entonces endurecido, y
`lib/core/socket/`). NO se inventó infraestructura: no había código de
servidor ejecutable en ese momento, y la especificación ejecutable del
protocolo en `lib/core/socket/protocol/` (challenge store, registro de
dispositivos, registro de sesiones, dedup, autorización, motor de
handshake) quedó como blueprint con el que el servidor real debía
construirse. PASO 5 lo construyó contra ese blueprint.

## 1. Tecnología recomendada

| Capa | Elección | Por qué |
|---|---|---|
| Runtime | **Node.js 20 LTS + TypeScript** | Socket.IO es nativo ahí; el protocolo de referencia (Dart) se traslada 1:1 |
| Servidor | **Socket.IO 4.7+** (`socket.io` npm) | Mismo protocolo que `socket_io_client` 2.x del app; rooms, middleware, acks |
| Estado caliente | **Redis 7** (challenges, sesiones, dedup, rate limits) | TTL nativo = expiración de challenges/sesiones; compartido entre nodos |
| Escalado | `@socket.io/redis-adapter` (+ `@socket.io/redis-emitter` para servicios externos) | Fan-out entre nodos sin sticky sessions (websocket-only) |
| Fuente de verdad | **Supabase (Postgres + RLS)** | cuentas, devices, claves públicas, membresías, mensajes cifrados |
| Proceso | PM2 / contenedores Docker + orquestador (k8s o ECS) | despliegue horizontal |
| Edge | LB L7 con soporte WebSocket (ALB/NLB/Cloudflare) + TLS 1.2/1.3 | WSS obligatorio |

## 2. Autenticación (handshake)

Implementa EXACTAMENTE `lib/core/socket/protocol/handshake_engine.dart`:

1. **`connection`** (middleware de Socket.IO): registrar intento, aplicar
   rate limit por IP; NO autenticar todavía. Enviar `auth.challenge`
   `{challenge_id, challenge(base64 de 32 B CSPRNG), expires_at_ms}`.
   Guardar en Redis: `SETEX chal:<id> 60 <socketKey|account|device|bytes>`
   — el challenge se emita tras conocer `account_id`/`device_id` de un
   primer mensaje `auth.hello` MÍNIMO (solo ids, sin secretos), o bien se
   emite un challenge genérico ligado solo al socket y se re-liga al
   recibir `auth.response` (elección de implementación; la referencia
   usa la variante ligada).
2. **`auth.response`**: ejecutar las 5 verificaciones (payload → device
   activo → identidad → challenge single-use → firma Ed25519 con la clave
   REGISTRADA). Cualquier fallo: `auth.failure {code:'AUTH_FAILED'}` y
   cierre del socket (además del challenge quemado). Éxito: `auth.success
   {session_id,...}` y asociar `socket.data.session`.
   - Claves públicas: tabla `devices`/`users` en Supabase (columna
     `public_key` Ed25519 — ya escrita por `identity_service.dart`).
   - Firma: `crypto.verify(null, canonical, registeredKey, signature)` con
     el mensaje canónico `NOVA_AUTH_v1|...` (idéntico al cliente).
3. **Límites**: máx 3 `auth.response` por socket; 5/min por device e IP;
   lockout 2 min tras 5 fallos (Redis INCR+EXPIRE). Ver `HandshakeEngine`.

## 3. Sesiones

Implementa `SessionRegistry` sobre Redis hash `sess:<id>` (TTL 24 h,
renewed on activity) + réplica ligera en Postgres `sessions` (visible por
el usuario; `session_service.dart` ya escribe ahí):

- id aleatorio 256 bits; campos `account_id, device_id, nova_id, socket_id`.
- Una sesión viva por dispositivo: al crear, `DEL` de las previas del device.
- `revoke(session_id)` / `revokeByDevice(device_id)`: borrar Redis +
  desconectar sockets asociados (el adapter permite localizar por room
  `device:<id>`).
- Cada evento del socket se autoriza contra `socket.data.session` (nunca
  contra claims del cliente).

## 4. Redis — uso por clave

| Clave | Tipo | TTL | Uso |
|---|---|---|---|
| `chal:<id>` | string | 60 s | challenge single-use (GETDEL) |
| `sess:<id>` | hash | 24 h (sliding) | sesión autenticada |
| `dedup:<account>:<message_id>` | string NX | 24 h | idempotencia de mensajes |
| `rl:<scope>:<bucket>` | string INCR | ventana 60 s | rate limits |
| `cursor:<conv>` | INCR | — | `server_seq` por conversación |
| `presence:<account>` | hash | 5 min | online/last_seen |

## 5. Rooms

- `account:<account_id>` — todos los sockets de una cuenta (sync, device.*).
- `device:<device_id>` — sockets de un dispositivo (revocación dirigida).
- `conv:<conversation_id>` — fan-out de mensajes (join verificado por
  membresía; el servidor NUNCA confía en un `join` pedido por el cliente
  sin check en Supabase).
- `presence-audience:<account_id>` — audiencia autorizada de presencia.

## 6. Eventos y autorización (resumen)

Catálogo completo: `lib/core/socket/socket_events.dart` y
`SOCKET_ARCHITECTURE.md` §4. Autorización: `AuthorizationPolicy` →
consultas Supabase (`conversation_members`, `contacts`/`blocked_users`,
privacy settings) con caché Redis 30 s. Reglas: membresía para
`message.*`, relación para `call.*`, audiencia para presencia, cuenta
propietaria para `device.*`.

Mensajes: el servidor recibe `message.send` (ciphertext + message_id):
1. dedup `SET NX dedup:...` (si existe → responder ack original);
2. `INCR cursor:<conv>` → `server_seq`;
3. persistir en Supabase (`messages`, ciphertext opaco);
4. `message.ack {message_id}` al emisor;
5. fan-out a `conv:<id>` con `message.new {...,server_seq}`;
6. recibo del destinatario → `message.delivered`; lectura → `message.read`.

## 7. Rate limiting servidor

Token bucket en Redis (script Lua atómico) con los valores de
`SocketRateLimitPresets` (5 auth/min, 30 msg/min, 12 typing/min, 60
signaling/min, 6 sync/min, 120 total/min) + por-IP para conexiones nuevas
(60/min) + penalización en violación de protocolo. `sync.request` y
`auth.challenge/response` son los más protegidos (brute force).

## 8. Escalabilidad horizontal

- **WebSocket-only** (sin polling en prod) + redis adapter → **no se
  requieren sticky sessions**. Si algún día se habilita polling como
  fallback, sí harían falta (documentado como razón técnica del fallback).
- Dimensionamiento: ver `SOCKET_ARCHITECTURE.md` §10 (1 k → 1 M usuarios).
- vCPU por nodo: ~1 core maneja ~3–5 k conexiones activas con mensajes
  moderados; dimensionar a ~50% de pico.
- Redis: 1 réplica + sentinel a partir de 3 nodos; cluster por encima de
  ~100 k conexiones.
- `@socket.io/redis-emitter` para emitir desde workers (webhooks FCM,
  revocaciones desde Supabase functions, etc.) sin acoplarse a un nodo.
- Cola de sync: para desconexiones largas, `sync.response` puede paginarse
  o degradar a REST/Supabase para históricos (el socket solo lleva lo
  reciente).

## 9. Integración Supabase

- Lecturas: `devices` (estado/clave), `users` (nova_id/account), membresías
  (`conversation_members`), bloqueos (`blocked_users`), privacidad.
- Escrituras: `messages` (ciphertext+seq), `sessions` (espejo), presencia.
- Acceso con **service role** SOLO desde el servidor realtime (nunca en el
  cliente); RLS protege el acceso directo del cliente.
- Revocación reactiva: Supabase function/webhook sobre UPDATE de
  `devices.status='revoked'` → `redis-emitter` emite `device.revoked` a
  `device:<id>` y borra sesiones.
- El Realtime de Supabase NO se usa para el transporte de chat (el
  transporte es este servidor); puede complementar datos fríos.

## 10. Deployment

1. Contenedor: `node:20-slim`, build TS, healthcheck `/healthz` (HTTP),
   readiness por conexión Redis.
2. LB L7 con WSS (TLS 1.2+; HSTS; sin downgrade), idle timeout ≥ 120 s
   (> pingInterval+pingTimeout).
3. Variables: `REDIS_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
   `SOCKET_PATH=/socket.io/`, `PING_INTERVAL=25000`, `PING_TIMEOUT=20000`,
   `MAX_PAYLOAD=64kB` (sobres E2EE pequeños), `CORS_ORIGIN=<app>` (el
   cliente móvil no usa CORS, pero el web sí).
4. `transports: ['websocket']` (server-side también), `maxHttpBufferSize:
   1e6`, `perMessageDeflate: false` (CPU), `pingInterval: 25000`,
   `pingTimeout: 20000`.
5. Observabilidad: métricas de conexiones/auth-rate/latencia de ack;
   logs redactados según `SOCKET_SECURITY.md` §10; alarmas por picos de
   `AUTH_FAILED` y rate limit.
6. CI: portar los tests de `lib/core/socket/protocol/` a TS (mismos
   casos) + tests de carga (artillery/socket.io benchmark).

## 11. Plan de construcción — ejecutado en PASO 5 (§0)

1. ✅ Esqueleto Node+TS + Docker compose (server + redis) local
   (`server/`).
2. ✅ Handshake completo (port del `HandshakeEngine`) + tests paridad con
   Dart (`server/test/e2e_handshake.test.ts`).
3. ✅ Sesiones + revocación + rooms de device
   (`server/test/e2e_sessions_devices.test.ts`).
4. ✅ `message.*` con dedup + seq + persistencia (directorio/almacén
   Supabase cableado; memoria por defecto)
   (`server/test/e2e_messaging.test.ts`).
5. ✅ sync + presencia + signaling (solo relay, con autorización)
   (`server/test/e2e_sync.test.ts`, `server/test/e2e_presence_calls.test.ts`).
6. ⏳ Redis adapter + segunda réplica + prueba de conmutación wifi↔móvil
   real contra el app — **PASO 6**.

El estado del servidor ya no es PENDIENTE: ver §0. Lo que NO existe
todavía (y no debe presentarse como existente): despliegue multi-nodo,
adapter Redis, caché de autorización, redis-emitter y validación contra
el app Flutter real (requiere dispositivo/backend desplegado).
