# NovaApp Realtime Server (FASE 0.5 — PASO 5)

Servidor Socket.IO **real** (Node.js 20+ / TypeScript) para NovaApp. Implementa
el protocolo especificado en PASO 4 (`lib/core/socket/`) — challenge/response
Ed25519, sesiones con revocación, mensajes idempotentes con `server_seq`,
rate limiting y autorización por membresía — contra el que el cliente Flutter
ya se valida.

Especificación de referencia: `docs/SOCKET_SERVER_ARCHITECTURE.md`.

## Estado

| Pieza | Estado |
|---|---|
| Handshake criptográfico (challenge single-use, firma Ed25519 sobre clave REGISTRADA, AUTH_FAILED genérico) | ✅ implementado + E2E |
| Sesiones (1 viva por dispositivo, TTL deslizante, revocación) | ✅ implementado + E2E |
| `message.*` (dedup por `message_id`, `server_seq` por conversación, fan-out por membresía, delivered/read) | ✅ implementado + E2E |
| `sync.request/response` (replay del log por cursor) | ✅ implementado + E2E |
| Presencia (audiencia privada) + signaling de llamadas (relay, anti-spoof) | ✅ implementado + E2E |
| Rate limits de servidor (token bucket por dominio + lockout auth) | ✅ implementado + E2E |
| Almacén | `memory` (un nodo) por defecto; `supabase` (PostgREST, service role) **implementado + E2E** |
| Presencia offline automática al caer el socket | ✅ implementado + E2E |
| Logging redactado (sin claves/plaintext/sesiones) | ✅ implementado + E2E |
| Redis (multi-nodo, sesiones/challenges/dedup/cursores compartidos) | ❌ **AUSENTE** — ver `docs/REALTIME_PRODUCTION_CHECKLIST.md` §2 |
| Contenedor + healthcheck + compose (server+redis) | ✅ |

## Ejecutar

```bash
cd server
npm install
npm run build
npm start            # PORT=4000 por defecto; GET /healthz

# desarrollo:
npm run dev

# tests E2E (40/40):
npm test
```

Configuración por variables de entorno: ver `.env.example` (TTLs, límites,
CORS, `ADMIN_TOKEN`, backend de almacén).

### Docker

```bash
docker compose up --build     # server + redis (ver comentario en el yml)
```

## Contrato de cable (resumen)

- Transporte: **WebSocket only** (`transports: ['websocket']`, sin polling
  en producción; sin sticky sessions necesarias).
- `connection` → `auth.challenge {challenge_id, challenge(≥32B), expires_at_ms}`.
- `auth.response {challenge_id, signature, account_id, device_id, nova_id}` →
  `auth.success {session_id, ...}` | `auth.failure {code}` (código genérico
  `AUTH_FAILED`; `RATE_LIMITED` solo cuando el cliente honesto debe frenar).
- Mensaje canónico firmado: `NOVA_AUTH_v1|account|device|nova|challenge_id|challenge`.
- Tras `auth.success`, cada evento se autoriza contra la sesión del socket:
  el cliente nunca re-envía identidad ni firmas.
- El servidor solo ve **ciphertext opaco** + metadata (`server_seq`,
  `received_at_ms`). Orden canónico: `server_seq` por conversación.
- Rooms concedidos por verdad del servidor (`account:`, `device:`, `conv:`).

## API admin (HTTP)

`GET /healthz`; `POST /admin/devices`, `/admin/devices/revoke`,
`/admin/sessions/revoke`, `/admin/conversations`, `/admin/relationships`,
`/admin/presence-audience`. En producción requieren `Authorization: Bearer
$ADMIN_TOKEN` (equivalente local del webhook de revocación de Supabase, §9
del doc de arquitectura).

## Tests

`npm test` — **109 casos E2E** sobre WebSockets reales en loopback con
firmas Ed25519 reales y E2EE real (X3DH + Double Ratchet):

| Suite | Casos |
|---|---:|
| `e2e_auth_matrix` — matriz completa de autenticación | 17 |
| `e2e_presence_signaling_logs` — presencia, señalización, logs, límites, concurrencia | 14 |
| `e2e_authorization` — aislamiento A/B, rooms, spoofing | 12 |
| `e2e_ab_flow` — A →E2EE→ servidor →E2EE→ B | 10 |
| `e2e_reconnect_sync` — reconexión, cambio de red, sync, reinicio | 10 |
| `e2e_handshake` | 10 |
| `e2e_messaging` | 10 |
| `e2e_sessions_devices` | 6 |
| `e2e_supabase_store` — ruta A→Supabase→B | 6 |
| `e2e_rate_limits` | 4 |
| `e2e_sync` | 4 |

Arnés de cliente reutilizable: `src/client/nova_client.ts` (cliente real
con handshake, outbox idempotente y cursores) y `src/client/e2ee.ts`
(X3DH + Double Ratchet sobre `node:crypto`).

Detalle: `docs/E2E_REALTIME_TESTING.md`.
