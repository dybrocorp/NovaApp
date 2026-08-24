# SOCKET_ARCHITECTURE.md — FASE 0.5 — PASO 4

Arquitectura de la capa de comunicación en tiempo real de NovaApp
(Socket.IO sobre WebSocket).

Fecha: 2026-08-24
Estado: cliente endurecido + especificación ejecutable del protocolo.
**El repositorio NO contiene servidor Socket.IO** (ver
`docs/SOCKET_SERVER_ARCHITECTURE.md`).

---

## 1. Stack de arquitectura

```
NovaApp (Flutter)
   ↓  Socket.IO (capa de eventos + gestión de conexión)
   ↓  WebSocket transport (primario y, en producción, único)
Realtime Server (NO existe aún en el repo — especificado)
   ↓  verificación de sesión + autorización por evento
Supabase / backend (fuente de verdad: cuentas, devices, claves, mensajes)
```

- **Socket.IO** es la capa de eventos, handshake y gestión de conexión.
  NO se sustituye por otra tecnología.
- **WebSocket** es el transporte. Polling NO es mecanismo principal:
  existe solo como fallback de DEBUG (ver §9). En producción no hay
  fallback: WebSocket es requisito (decisión documentada en §9).

## 2. Módulos del cliente (`lib/core/socket/`)

| Módulo | Responsabilidad |
|---|---|
| `socket_events.dart` | Catálogo tipado y namespaced de eventos; lista de eventos emisibles por el cliente |
| `socket_config.dart` | Configuración auditada de Socket.IO; validación de URL (WSS obligatorio); presets de rate limits |
| `reconnect_policy.dart` | Backoff exponencial + jitter completo + tope de intentos |
| `rate_limiter.dart` | Token buckets por dominio de eventos (cliente) |
| `heartbeat_watchdog.dart` | Detección de conexiones muertas sin tráfico extra |
| `network_transition_handler.dart` | Máquina de estados WiFi↔móvil / outage → reconnect + resync |
| `socket_log.dart` | Redacción de logs (identificadores cortos, secrets ocultos) |
| `auth/auth_payloads.dart` | Payloads tipados del handshake (challenge/response/success/failure) |
| `auth/auth_signer.dart` | Firma Ed25519 del mensaje canónico del handshake + verificación de referencia |
| `auth/socket_session.dart` | Sesión del cliente: single-use por conexión, con expiración |
| `messaging/message_envelope.dart` | Sobre de mensaje: SOLO ciphertext + ids + seq |
| `messaging/ack_state.dart` | Estados de entrega SENT / DELIVERED / READ (nunca confluyen) |
| `messaging/outbox.dart` | Cola idempotente de salida (message_id estable, reintentos acotados) |
| `messaging/gap_detector.dart` | Duplicados / fuera de orden / faltantes por `server_seq` |
| `protocol/*` | **Especificación ejecutable** de las reglas del servidor (challenge store, registros de sesión/dispositivo, dedup, autorización, handshake engine). Se usan en tests y como blueprint del servidor real. NO es un servidor. |

`lib/core/services/websocket_service.dart` compone todo lo anterior y
mantiene la API pública previa (`connect`, `sendMessage`, streams,
provider Riverpod). No se reescribió la UI ni se integró chat (esto es
FASE 0.5, no FASE 1).

## 3. Protocolo de conexión

```
CONNECT (Socket.IO/WebSocket)
   ↓
AUTH CHALLENGE        servidor → auth.challenge {challenge_id, challenge, expires_at_ms}
   ↓
DEVICE ID + PUBLIC KEY registrada + NONCE
   ↓
Ed25519 SIGNATURE     cliente → auth.response {challenge_id, signature,
   ↓                   account_id, device_id, nova_id, ts_ms}
SERVER VERIFICATION   payload + device activo + identidad + challenge
   ↓                  (único, vigente, del intento) + firma vs clave REGISTRADA
AUTHENTICATED SESSION servidor → auth.success {session_id, account_id,
   ↓                   device_id, nova_id, expires_at_ms}
EVENTS                el resto de eventos se autorizan contra la sesión
```

- El cliente **no envía** su clave pública en `auth.response`: el servidor
  verifica contra la clave **registrada** para `(account_id, device_id)`.
  Enviar la clave permitiría suplantación trivial.
- Mensaje canónico firmado (v1):
  `NOVA_AUTH_v1|<account_id>|<device_id>|<nova_id>|<challenge_id>|<challenge>`
  La firma queda ligada a ESTE dispositivo y ESTE challenge: no sirve para
  otro device ni para otro intento.
- NO se confía en `userId`/Nova ID enviados por el cliente por sí solos:
  la identidad la establece la verificación criptográfica + el estado del
  dispositivo en backend.
- Después de autenticar, **no se vuelve a firmar por evento**: la sesión
  (id aleatorio, TTL, revocable, ligada a account+device) porta la
  identidad en el servidor.

## 4. Catálogo de eventos (namespaced y tipado)

`SocketEvent` (`socket_events.dart`) es la única fuente de nombres. Un
handler no puede registrarse para un evento no declarado.

| Dominio | Evento | Dirección | Payload (resumen) |
|---|---|---|---|
| AUTH | `auth.challenge` | S→C | `{challenge_id, challenge, expires_at_ms}` |
| AUTH | `auth.response` | C→S | `{challenge_id, signature, account_id, device_id, nova_id, ts_ms}` |
| AUTH | `auth.success` | S→C | `{session_id, account_id, device_id, nova_id, expires_at_ms}` |
| AUTH | `auth.failure` | S→C | `{code}` — genérico |
| MESSAGE | `message.send` | C→S | sobre E2EE (ciphertext) con `message_id` |
| MESSAGE | `message.new` | S→C | sobre E2EE + `server_seq` |
| MESSAGE | `message.ack` | S→C | recepción del SERVIDOR (solo eso) |
| MESSAGE | `message.delivered` | S→C / C→S | recibido por el dispositivo destino |
| MESSAGE | `message.read` | S→C / C→S | leído |
| MESSAGE | `message.typing` | bidireccional | indicador de escritura |
| SYNC | `sync.request` | C→S | `{last_cursor, device_id}` |
| SYNC | `sync.response` | S→C | `{events[], cursor}` |
| PRESENCE | `presence.update` | C→S | propio estado (online/offline/last_seen) |
| PRESENCE | `presence.changed` | S→C | solo a audiencia autorizada por privacidad |
| CALL | `call.offer` / `call.answer` / `call.ice` / `call.end` | bidireccional | señalización WebRTC EXCLUSIVAMENTE |
| DEVICE | `device.added` | S→C | nuevo dispositivo aprobado |
| DEVICE | `device.revoked` | S→C | `{device_id}` — desconexión forzosa si es el propio |
| SYSTEM | `system.error` / `system.shutdown` | S→C | genéricos |

Regla: `isClientEmittableEvent` define qué puede emitir el cliente; todo
lo demás es del servidor. El servidor aplica la misma lista.

## 5. Mensajería: E2EE, ACK, idempotencia, orden

### 5.1 Solo ciphertext
```
NovaApp → E2EE (Double Ratchet local) → ciphertext
       → Socket.IO → servidor (ve bytes opacos) → destinatario
       → decrypt local
```
El sobre (`MessageEnvelope`) lleva `message_id`, `conversation_id`,
`ciphertext`, `header_type` y —solo como pista de UI— `client_ts_ms`.
El guard `containsPlaintextPayload` rechaza localmente cualquier mapa con
campos de texto plano (`text`, `content`, `body`, ...). El servidor no
tiene claves para descifrar: no debe poder leer contenido, por diseño.

### 5.2 ACK: tres estados distintos
- `SENT` = `message.ack`: el servidor RECIBIÓ y persistió. Nada más.
- `DELIVERED` = el dispositivo del destinatario acusó recibo.
- `READ` = el destinatario leyó.
`AckStateMachine` fuerza avance hacia adelante; nunca se mezclan.

### 5.3 Idempotencia
Cada mensaje genera un `message_id` (UUID v4) **estable**: los reintentos
tras reconexión re-emiten el MISMO id (Outbox → mismo sobre). El servidor
deduplica por `message_id` (`MessageDedup`, mapeable a Redis SET+TTL) y
responde con el ack ORIGINAL: un reenvío no duplica el mensaje.

### 5.4 Orden
- Autoridad de orden: `server_seq` monótono por conversación (asignado
  por el servidor). Los timestamps del cliente son solo hints de UI.
- `SequenceGapDetector` detecta duplicados (mismo id), fuera de orden
  (buffer) y faltantes (gap → se dispara `sync.request` con el cursor
  contiguo). El contenido E2EE nunca se modifica ni reordena.

## 6. Reconexión

Flujo (spec §6):
```
Internet se pierde → socket disconnect → backoff (+jitter)
→ reconnect → NUEVO challenge → NUEVA firma → NUEVA sesión → resync
```
- Política (`ReconnectPolicy`): base 1 s, ×2 por intento, tope 30 s,
  **jitter completo** (`delay = U(0, cap)`) para evitar stampedes,
  **máximo 12 intentos** consecutivos → estado `failed` (sin bucles
  infinitos). `reset()` al autenticar con éxito o al recuperar red.
- La auto-reconexión de la librería está DESACTIVADA
  (`'reconnection': false`): cada reconexión pasa por nuestro ciclo que
  exige re-handshake completo. **Nunca se reutiliza una sesión vieja.**
- Tras cada `auth.success` post-reconexión se emite `sync.request`
  (`last_cursor`) y se re-envía el outbox pendiente (mismos ids).

## 7. Cambios de red (WiFi ↔ móvil)

`NetworkTransitionHandler` + `WebSocketService.bindConnectivity()`:
- Cambio wifi→móvil o móvil→wifi con socket "vivo": el socket viejo queda
  sospechoso (half-open) → disconnect forzado + reconexión inmediata +
  re-autenticación + resync.
- Outage real y regreso: reconexión inmediata (no espera el backoff
  restante) y reset del contador de intentos.
- Cubierto por tests de ambos sentidos (§ tests 11 y 12).

## 8. Heartbeat

- El ping/pong de engine.io (Socket.IO) ya existe: el servidor hace ping
  cada `pingInterval` (recomendado 25 s) y corta si no hay pong en
  `pingTimeout` (recomendado 20 s). El cliente contesta solo — cero
  paquetes extra, cero gasto extra de batería.
- `HeartbeatWatchdog` (cliente) detecta conexiones **muertas en silencio**
  que el transporte no notó (típico en cambios de red): si no hay ningún
  paquete durante 75 s (> 25+20+30 de margen) fuerza el reciclado de la
  conexión. Chequeo cada 15 s (barato).

## 9. Configuración Socket.IO (auditada)

| Opción | Valor | Decisión |
|---|---|---|
| `transports` | `['websocket']` (prod) / `['websocket','polling']` (debug) | WebSocket es el transporte. Polling SOLO debug (proxies/captive portals de desarrollo). En producción sin fallback: degradar a polling oculta fallos, encarece el servidor y amplía superficie. |
| `autoConnect` | `false` | Conexión explícita tras validación de identidad/URL. |
| `reconnection` | `false` | La librería no reconecta: nuestro ciclo exige re-handshake por reconexión (§6). |
| `forceNew` | `true` | Evita managers cacheados al reciclar el socket manualmente. |
| `timeout` | 15 000 ms | Handshake móvil razonable (redes lentas incluidas). |
| backoff propio | base 1 s ×2, cap 30 s, full jitter, máx 12 | §6. |
| `authChallengeTimeout` | 20 s | Ventana para challenge+veredicto; si no llega, reciclado. |
| `pingInterval/pingTimeout` (servidor) | 25 s / 20 s (recomendado) | §8; el watchdog cliente usa 75 s. |

Seguridad del transporte: en producción SOLO `wss://` (TLS). `ws://` se
rechaza por `SocketConfig.validateServerUrl` salvo flag explícito de
debug. La validación de certificados NO se desactiva jamás.

## 10. Escalabilidad (análisis; NO se implementa complejidad aún)

| Usuarios | Conexiones simultáneas (~30% online) | Memoria servidor (~100 KB/conexión) | Estrategia |
|---|---|---|---|
| 1 000 | ~300 | ~30 MB | 1 nodo Socket.IO, sin Redis |
| 10 000 | ~3 000 | ~300 MB | 1 nodo + Redis adapter (preparado) |
| 100 000 | ~30 000 | ~3 GB (varios nodos) | N nodos + `@socket.io/redis-adapter`, LB L7, sticky sessions NO requeridas con websocket-only + adapter |
| 1 000 000 | ~300 000 | ~30 GB (decenas de nodos) | Fleet regional, Redis cluster, rooms por conversación, presencia sharded, sync por REST+Supabase para colas |

Decisiones actuales: transporte websocket-only → sin necesidad de sticky
sessions para el upgrade; el adapter Redis se diseña pero no se despliega
hasta >5 000 conexiones sostenidas. Detalle completo en
`docs/SOCKET_SERVER_ARCHITECTURE.md`.

## 11. WebRTC: señalización solamente

`call.offer / call.answer / call.ice / call.end` transportan EXCLUSIVAMENTE
señalización (SDP/ICE). Audio y video NUNCA pasan por Socket.IO: fluyen por
peer connections WebRTC (E2EE por DTLS-SRTP). El signaling está sujeto a
rate limit propio (60/min) y a autorización de relación (§
SOCKET_SECURITY).

## 12. Estado de implementación

- IMPLEMENTADO (cliente): eventos tipados, handshake con firma ligada a
  device, sesiones single-use, reconexión con jitter y tope, transiciones
  de red, watchdog, rate limits, outbox idempotente, estados de entrega,
  gap detection, redacción de logs, WSS obligatorio.
- ESPECIFICACIÓN EJECUTABLE (protocolo): challenge store single-use,
  registro de dispositivos/sesiones, dedup, autorización, motor de
  handshake. Es el blueprint del servidor y la base de los tests.
- PENDIENTE: servidor real (ver documento de servidor), integración con UI
  (FASE 1), rooms de conversación reales, presencia persistente.
