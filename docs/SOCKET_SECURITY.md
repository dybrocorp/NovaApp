# SOCKET_SECURITY.md — FASE 0.5 — PASO 4

Modelo de seguridad de la capa Socket.IO/WebSocket de NovaApp.

Fecha: 2026-08-24

---

## 1. Principios

1. **No confiar en el cliente**: ni `userId` ni Nova ID identifican a
   nadie. La identidad la establece una firma Ed25519 verificada contra la
   clave pública REGISTRADA del `(account_id, device_id)`.
2. **Autenticación ≠ autorización**: la sesión autenticada no otorga
   acceso global; cada evento re-verifica permisos (§7).
3. **Fail closed**: ante cualquier anomalía de protocolo (challenge
   malformado, identidad eco incorrecta, URL insegura, identidad ausente)
   se corta/rechaza; nunca se "intenta seguir".
4. **Mínima exposición**: errores genéricos, logs redactados, sin
   enumeración posible de cuentas/dispositivos.

## 2. Autenticación criptográfica (handshake)

Ver detalle completo en `SOCKET_ARCHITECTURE.md` §3. Resumen de verificaciones
del servidor (implementadas como especificación ejecutable en
`lib/core/socket/protocol/handshake_engine.dart`):

| # | Verificación | Fallo → wire |
|---|---|---|
| 1 | Forma del payload `auth.response` | `AUTH_FAILED` |
| 2 | `device_id` existe y está **activo** (no revocado) | `AUTH_FAILED` |
| 3 | `account_id` y `nova_id` coinciden con el dispositivo registrado | `AUTH_FAILED` |
| 4 | Challenge existe, no expiró, es de un solo uso y está ligado a ESTE intento (socket) | `AUTH_FAILED` |
| 5 | Firma Ed25519 sobre el mensaje canónico con la clave REGISTRADA | `AUTH_FAILED` |
| 6 | → crear sesión (id aleatorio 256-bit, TTL 24 h, ligada a account+device+socket) | `auth.success` |

Mensaje canónico firmado:
```
NOVA_AUTH_v1|<account_id>|<device_id>|<nova_id>|<challenge_id>|<challenge>
```
Propiedad clave: una firma válida para un dispositivo/intento NO sirve
para otro (tests: firma de otro dispositivo, firma sobre otro challenge,
device id incorrecto).

El cliente además rechaza localmente: challenges < 32 bytes, challenges
vencidos o con expiración absurda (> 10 min), y `auth.success` que evo
identidades que no sean las locales.

## 3. Anti-replay

Un challenge debe ser: criptográficamente aleatorio (32 bytes CSPRNG),
tener expiración (TTL 60 s), ser de un solo uso, estar asociado al intento
de conexión (socket + account + device) e invalidarse al usarse — incluso
si la verificación posterior falla (se "quema" al consumirlo).

Tests asociados: challenge reutilizado, challenge expirado, challenge
modificado, firma modificada, firma de otro dispositivo, device id
incorrecto, replay de firma sobre challenge nuevo. Producción: Redis
`SETEX challenge:<id>` + `DEL` al consumir (atomic via Lua/`GETDEL`).

## 4. Sesiones

- Id aleatorio 256 bits; TTL 24 h con renovación deslizante por actividad.
- Ligada a `(account_id, device_id, socket)`.
- Revocable: individual (`revoke`), por dispositivo (`revokeByDevice`),
  por logout total.
- **Single-use por conexión**: al desconectar, el cliente descarta la
  sesión (`SocketSession.none`); el servidor evicta la sesión previa del
  dispositivo al crear una nueva (una sesión viva por dispositivo).
- Tras la autenticación NO se envían firmas ni identidad en cada evento:
  la sesión (en el servidor, ligada al socket) autoriza. El cliente jamás
  re-envía información crítica.

## 5. Revocación de dispositivo

```
Device revocado (owner / backend)
   → devices.status = revoked
   → servidor detecta (handshake futuro rechazado + push device.revoked)
   → socket desconectado forzosamente
   → sesiones del device invalidadas (revokeByDevice)
   → el device NO puede reconectarse (handshake → AUTH_FAILED genérico)
```
En el cliente, `device.revoked` (propio) o `auth.failure DEVICE_REVOKED`
→ estado `blocked`: desconexión, limpieza de outbox/sesión y rechazo de
reconexiones hasta re-registro. Nota: el servidor responde `AUTH_FAILED`
genérico para no revelar por qué falló; `DEVICE_REVOKED` solo se envía
push al propio dispositivo legítimo conectado.

## 6. Mensajes E2EE (el servidor no puede leer)

- Solo `ciphertext` viaja (`MessageEnvelope`). El servidor no posee claves
  privadas; no descifra contenido; persiste bytes opacos + metadata.
- Guards del cliente: rechazo local de mapas con campos de texto plano
  (`text`, `content`, `body`, `plaintext`, ...) y de sobres sin ciphertext.
- `header_type` (p. ej. `dr.v1`) es una etiqueta de formato, no contenido.

## 7. Autorización por evento

Especificada en `protocol/authorization_policy.dart`; el servidor real la
implementa sobre Supabase (membership + RLS). Reglas:

| Operación | Requisito |
|---|---|
| `message.send` / leer eventos de conversación | sesión autenticada **Y** membresía del account en la conversación |
| `message.delivered`/`read` | participante de la conversación |
| `call.*` (señalización) | relación de contacto vigente entre pares (no bloqueados) |
| presencia de un sujeto | estar en la audiencia de privacidad del sujeto (nunca broadcast global) |
| `device.*` gestión | solo la propia cuenta |

Tests: autorización de mensajería incorrecta y señalización no autorizada.

## 8. Rate limiting

Cliente (`SocketRateLimiters`, token bucket) y servidor (equivalente en
Redis, valores iguales o más estrictos):

| Dominio | Límite cliente | Nota |
|---|---|---|
| `auth.response` | 5/min + 3 intentos por conexión + lockout local 2 min tras 5 fallos consecutivos | protege brute-force de challenge/response |
| `message.send` | 30/min | |
| `message.typing` | 12/min | |
| `call.*` | 60/min | ráfagas ICE |
| `sync.request` | 6/min | tormentas de reconexión |
| `presence.update` | 12/min | |
| total emitido | 120/min | red de seguridad |

El servidor añade: límites por IP para conexiones nuevas, por account
agregado, y penalización (drain) ante violaciones de protocolo.

## 9. Heartbeat / conexiones muertas

Ver `SOCKET_ARCHITECTURE.md` §8: ping/pong engine.io (25 s/20 s) +
watchdog de silencio (75 s) — detecta half-open sin tráfico extra.

## 10. Logs

NUNCA se registran: claves privadas, mensajes en claro, secretos de
sesión, challenges, firmas, tokens, ciphertext/plaintext E2EE.
- Identificadores → prefijos cortos (`SocketLog.id`, p. ej. `a1b2…`).
- URLs → scheme+host sin query (`SocketLog.url`).
- Estructuras → `SocketLog.scrub` redacta claves sensibles (incl. anidadas).
- Errores del servidor → solo códigos genéricos.

## 11. Errores (sin filtraciones)

- Toda denegación criptográfica del handshake responde `AUTH_FAILED`
  (nunca "firma incorrecta para el dispositivo X").
- Códigos existentes: `AUTH_FAILED`, `RATE_LIMITED` (el cliente honesto
  debe retrasarse), `DEVICE_REVOKED`, `SESSION_EXPIRED`, `FORBIDDEN`,
  `DUPLICATE`, `PAYLOAD_INVALID`, `SERVER_CLOSING`.
- Sin oracle de enumeración: unknown device, revoked device y firma mala
  son indistinguibles para el atacante.

## 12. Seguridad del transporte

- Producción: **WSS/TLS obligatorio**. `SocketConfig.validateServerUrl`
  rechaza `ws://`/`http://` (a menos que `allowInsecureTransport` — solo
  debug). La validación de certificados NO se deshabilita nunca (no se
  toca `badCertificateCallback`).
- `transports: ['websocket']` en producción; polling solo debug.

## 13. Riesgos pendientes (honestos)

1. **No hay servidor real todavía**: toda la seguridad server-side está
   especificada y testeada como referencia, pero NO desplegada. Hasta que
   exista, el cliente no debe considerarse "en producción".
2. El challenge autentica al cliente ante el servidor; la autenticidad
   del SERVIDOR descansa íntegramente en TLS (WSS) — de ahí que sea
   obligatorio. ( Futuro: pinning o challenge firmado por el servidor. )
3. Rate limits de servidor (Redis) sin implementar (sin servidor).
4. `sync.request`/`sync.response` definidos y probados a nivel cliente;
   el cursor persistente (`last_cursor` en storage) se integrará en FASE 1.
5. Presencia: eventos y política de audiencia definidos; la persistencia
   de `last_seen` y su privacidad granular quedan para FASE 1.
6. Tests de integración end-to-end contra un servidor Socket.IO real
   (docker/local) pendientes hasta que el servidor exista.

Que los tests pasen NO significa que el sistema sea "seguro": significa
que las reglas especificadas se cumplen donde se pueden verificar hoy.
