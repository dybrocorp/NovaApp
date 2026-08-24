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
| Almacén | `memory` (un nodo) por defecto; `supabase` (PostgREST, service role) cableado |
| Redis adapter multi-nodo / caché 30s / redis-emitter | ⏳ PASO 6 |
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

`npm test` — 40 casos E2E sobre WebSockets reales en loopback con firmas
Ed25519 reales (`server/test/e2e_*.test.ts`): handshake (10), sesiones y
dispositivos (6), mensajería (10), rate limits (4), sync (4), presencia y
llamadas (6). Paridad con los tests Dart de `test/socket/`.
