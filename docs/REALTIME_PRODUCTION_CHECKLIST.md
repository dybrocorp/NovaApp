# REALTIME_PRODUCTION_CHECKLIST.md — NovaApp

Qué falta para que el realtime validado en FASE 0.5 pueda atender usuarios
reales. Cada punto indica si **bloquea producción**, por qué, y cómo se
cierra.

Fecha: 2026-08-24 · Estado del tier realtime: **validado en un nodo**

---

## Leyenda

| Marca | Significado |
|---|---|
| 🔴 | Bloqueante para producción |
| 🟠 | Bloqueante para escalar más allá de un nodo |
| 🟡 | Necesario antes de tráfico real, no bloqueante para un piloto cerrado |
| ✅ | Hecho y verificado en FASE 0.5 |

---

## 1. Transporte y despliegue

| | Punto | Estado |
|---|---|---|
| ✅ | Socket.IO 4 con transporte WebSocket-only (sin polling) | Verificado |
| ✅ | El cliente rechaza `ws://` en release | Verificado |
| 🔴 | **Terminación TLS (WSS) en el borde** | El servidor **no** termina TLS: escucha HTTP y espera un LB L7 (ALB/NLB/Cloudflare) con TLS 1.2/1.3. Sin eso, el tráfico va en claro |
| 🔴 | **`CORS_ORIGIN` restringido** | Hoy por defecto `*`. En producción debe ser la lista exacta de orígenes web |
| 🔴 | **`ADMIN_TOKEN` obligatorio** | Sin token, `/admin/*` queda abierto. Registra y revoca dispositivos: es una API crítica |
| 🟡 | Healthcheck y readiness | `/healthz` existe; falta readiness que dependa del almacén |
| 🟡 | Límite de conexiones por IP en el borde | Existe en la app; conviene duplicarlo en el LB |

### Sobre el fallback de polling

Se mantiene **sólo en builds de debug** del cliente Flutter
(`socket_config.dart`), por una razón concreta: proxies corporativos y
portales cautivos durante el desarrollo. En release el transporte es
`['websocket']` exclusivamente. Motivo de no permitirlo en producción:
degradar en silencio a polling oculta problemas de conectividad, multiplica
el coste por conexión y amplía la superficie de ataque. Además, con
websocket-only **no hacen falta sticky sessions** en el balanceador.

---

## 2. Redis — AUSENTE

**No está implementado. No se finge que lo esté.** No hay código Redis en
`server/src/`. El contenedor de `docker-compose.yml` está declarado pero el
servidor no lo usa.

| | Punto | Por qué hace falta |
|---|---|---|
| 🟠 | Adapter multi-nodo (`@socket.io/redis-adapter`) | Sin él, dos réplicas no se ven: un mensaje emitido en el nodo 1 nunca llega a un socket del nodo 2 |
| 🟠 | Challenges compartidos | Un challenge emitido por un nodo no se puede consumir en otro: la reconexión falla de forma aleatoria tras un balanceo |
| 🟠 | Sesiones compartidas | La revocación sólo mata sockets del nodo local: un dispositivo revocado sigue operando en otro nodo |
| 🟠 | Dedup compartido | El mismo `message_id` se acepta una vez por nodo: mensajes duplicados |
| 🟠 | Cursores compartidos | `nextSeq` en memoria por nodo produce `server_seq` repetidos y rompe el orden |
| 🟠 | Rate limits compartidos | Los token buckets son por proceso: la cuota efectiva del atacante se multiplica por el número de nodos |
| 🟠 | Presencia compartida + TTL | La presencia sólo refleja el nodo local |

**Mientras Redis no exista, el despliegue soportado es de UN nodo.** Con
`STORE_BACKEND=supabase` los cursores y el log ya son compartidos (RPC
atómicas en Postgres), pero challenges, sesiones, dedup, rate limits y
presencia siguen en memoria del proceso.

Mapeo previsto cuando se implemente:

```
chal:<id>            SETEX 60           challenge (uso único vía GETDEL)
sess:<id>            HASH + TTL 24h     sesión, TTL deslizante
dedup:<acct>:<msg>   SET NX EX 86400    idempotencia por cuenta
cursor:<conv>        INCR               server_seq
logcur:<conv>        INCR               log_seq
rate:<socket>:<dom>  Lua token bucket   límites atómicos
presence:<acct>      HASH + TTL         online/last_seen
```

---

## 3. Supabase

| | Punto | Estado |
|---|---|---|
| ✅ | Service role sólo en backend, nunca al cliente ni al log | Verificado (`e2e_supabase_store` 2-3) |
| ✅ | Sólo se persiste ciphertext opaco + metadata | Verificado |
| ✅ | Secuencias atómicas por RPC, con fallo cerrado si faltan | Verificado |
| 🔴 | **Aplicar `server/sql/realtime_schema.sql`** en el proyecto real | Incluye tablas, RPC y RLS deny-by-default del tier realtime |
| 🔴 | **Verificar RLS con Postgres real** | El esquema es deny-by-default por revisión, pero **nunca se ejecutó**. Hay que comprobar que anon/authenticated no leen `messages`, `realtime_events` ni `conversation_cursors` |
| 🔴 | **Auditar las políticas RLS de las tablas de la app** | Las migraciones históricas (`supabase_setup.sql` y siguientes) no se revisaron en esta fase; el roadmap del repo advierte de políticas permisivas heredadas |
| 🔴 | **Rotar la service role key** si estuvo alguna vez en un `.env` versionado | |
| 🟡 | Caché de autorización (30 s) para membresías | Hoy cada decisión consulta el directorio: correcto pero costoso |
| 🟡 | Webhook de revocación Supabase → servidor | Hoy la revocación entra por `/admin/devices/revoke` |
| 🟡 | Política de retención del log de eventos | `realtime_events` crece sin límite |

---

## 4. Seguridad

| | Punto | Estado |
|---|---|---|
| ✅ | Handshake Ed25519 con challenge de un solo uso | Verificado |
| ✅ | `AUTH_FAILED` genérico (sin oráculo de enumeración) | Verificado |
| ✅ | Autorización por membresía en cada evento | Verificado |
| ✅ | Identidad sellada por el servidor (anti-spoof) | Verificado |
| ✅ | Logs redactados, sin claves ni plaintext | Verificado |
| ✅ | Revocación de dispositivo efectiva e inmediata | Verificado (un nodo) |
| 🔴 | **Auditoría criptográfica independiente** de X3DH y Double Ratchet | Funcionan e interoperan; eso **no** equivale a estar auditados |
| 🟡 | Verificación de identidad entre usuarios (safety numbers) | No existe: sin ella no hay defensa frente a un servidor de claves malicioso |
| 🟡 | Rotación de SPK y reposición de OPK | La generación existe; falta el ciclo de vida |
| 🟡 | Protección anti-abuso más allá del token bucket | Ej. reputación por cuenta |
| 🟡 | Monitorización de intentos de auth fallidos | Ya se loguean de forma redactada; falta alertar |

**Lenguaje admitido sobre seguridad:** *validado*, *verificado*,
*pendiente de auditoría*. No se afirma "100 % seguro", "imposible de
hackear" ni comparaciones con otras aplicaciones. Que 109 pruebas pasen
significa que **esas propiedades concretas se cumplen en las condiciones
probadas**, nada más.

---

## 5. Llamadas / WebRTC

| | Punto | Estado |
|---|---|---|
| ✅ | Señalización `call.offer/answer/ice/end` sobre Socket.IO | Verificado |
| ✅ | Nunca fluye media por Socket.IO | Verificado por diseño y prueba |
| ✅ | Señalización autorizada por relación de contactos | Verificado |
| 🔴 | **Servidor TURN** | `webrtc_service.dart` sólo declara STUN público de Google; la entrada TURN está comentada. **Las llamadas fallarán tras NAT simétrico** (móvil↔móvil en redes carrier es el caso común) |
| 🟡 | Credenciales TURN efímeras | Nunca embeber credenciales estáticas en el cliente |
| 🟡 | Máquina de estados de llamada en servidor | Hoy sólo hay relay |

---

## 6. Operación

| | Punto | Estado |
|---|---|---|
| ✅ | Apagado ordenado con aviso `system.shutdown` | Verificado |
| ✅ | Dockerfile con usuario no root y healthcheck | Existe |
| 🟡 | Métricas (conexiones, handshakes, fallos, rechazos, latencia de fan-out) | No hay |
| 🟡 | Trazas correlacionables sin identificadores completos | Parcial: los logs ya truncan ids |
| 🟡 | Alertas sobre picos de `AUTH_FAILED` y `RATE_LIMITED` | No hay |
| 🟡 | Backups y restauración del log de eventos | No definido |
| 🟡 | Runbook de revocación masiva | No existe |

---

## 7. Cliente Flutter

| | Punto | Estado |
|---|---|---|
| ✅ | Handshake, reconexión con backoff, transiciones de red, outbox | Implementado y cubierto por pruebas Dart |
| 🔴 | **Ejecutar `flutter analyze` y `flutter test`** | **NOT RUN — Flutter SDK unavailable** en este entorno. Los cambios de esta fase en `websocket_service.dart` (cursores por conversación, contrato `last_seq`, `markMessageDelivered`) están escritos y revisados pero **no ejecutados** |
| 🟡 | Persistir los cursores de sync entre arranques | Hoy viven en memoria: un reinicio del app fuerza un resync completo |
| 🟡 | Persistir el outbox | Un cierre del app pierde los mensajes no enviados |
| 🟡 | Integrar `markMessageDelivered` en la UI de chat | El método existe; la pantalla aún no lo llama (es trabajo de FASE 1) |

---

## 8. Orden recomendado

1. **Antes de cualquier despliegue**: TLS en el borde, `ADMIN_TOKEN`,
   `CORS_ORIGIN`, aplicar el esquema SQL y verificar RLS contra Postgres
   real, ejecutar `flutter analyze` + `flutter test`.
2. **Antes de tráfico real**: TURN con credenciales efímeras, métricas y
   alertas, retención del log.
3. **Antes de escalar**: Redis completo (adapter + challenges + sesiones +
   dedup + cursores + rate limits + presencia) y prueba real de dos nodos.
4. **Antes de prometer garantías de seguridad**: auditoría criptográfica
   externa y verificación de identidad entre usuarios.
