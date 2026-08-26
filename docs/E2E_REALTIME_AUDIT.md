# E2E_REALTIME_AUDIT.md — FASE 0.5

**Auditoría end-to-end del realtime de NovaApp**
Fecha: 2026-08-24 · Alcance: FASE 0.5 (validación), NO FASE 1
Rama: `arena/01a035bd-novaapp` · Commit base: `5c10f93`

---

## 0. Método

Se auditó **el código real**, no la existencia de archivos. Para cada
componente se leyó la implementación, se buscó el punto donde la garantía
se aplica de verdad (no donde está documentada) y se escribió o ejecutó
una prueba que la ejercita contra el servidor real por WebSockets de
loopback.

Clasificación usada:

| Etiqueta | Significado |
|---|---|
| **VERIFICADO** | Implementado **y** ejercitado por una prueba automatizada que falla si se rompe |
| **IMPLEMENTADO** | El código existe y es correcto por revisión, pero no hay prueba que lo cubra |
| **PARCIAL** | Funciona en un subconjunto de casos, o depende de un supuesto no validado |
| **NO VERIFICADO** | Existe código pero no se pudo ejercitar en este entorno |
| **AUSENTE** | No existe |

---

## 1. Inventario real del repositorio

```
lib/core/socket/            21 archivos  — especificación ejecutable del protocolo (Dart)
lib/core/services/
  websocket_service.dart    cliente Socket.IO endurecido (~1.1k líneas)
  x3dh_service.dart         X3DH real (Ed25519 + X25519 + HKDF)
  double_ratchet_service.dart Double Ratchet real (HMAC-SHA256 + AES-GCM)
server/src/                 servidor Socket.IO real (Node 20 / TypeScript)
server/test/                suite E2E sobre WebSockets reales
test/socket/                pruebas Dart del protocolo (unitarias)
docs/                       arquitectura + seguridad
supabase_*.sql              migraciones de la app
server/sql/realtime_schema.sql esquema del tier realtime
```

**Redis: AUSENTE.** No hay ni una línea de código Redis en `server/src/`
ni en `lib/`. Aparece únicamente en documentación y como contenedor
declarado en `docker-compose.yml` (sin que el servidor lo use). Se
documenta como requisito de producción multi-nodo, **no se finge**.

**TURN: AUSENTE.** `lib/core/services/webrtc_service.dart` sólo declara
servidores STUN públicos de Google; la entrada TURN está comentada. Sin
TURN, las llamadas fallan tras NAT simétrico. Fuera del alcance de FASE
0.5 (aquí sólo se valida el transporte de señalización), pero es
bloqueante para llamadas reales.

---

## 2. Tabla de clasificación por componente

### 2.1 Transporte

| Componente | Estado | Evidencia |
|---|---|---|
| Socket.IO 4 servidor | **VERIFICADO** | `server/src/realtime_server.ts`; toda la suite E2E corre sobre él |
| Transporte WebSocket-only | **VERIFICADO** | `transports:['websocket']` en servidor y cliente de pruebas; sin polling |
| WSS / TLS obligatorio | **PARCIAL** | El cliente rechaza `ws://` en release (`socket_config.dart`, probado en `test/socket/websocket_service_test.dart`). El **servidor no termina TLS**: espera un balanceador L7. No validado con certificado real |
| `connectionStateRecovery` desactivado | **VERIFICADO** | `maxDisconnectionDuration: 0`; toda reconexión re-ejecuta el handshake |
| Límite de tamaño de paquete | **IMPLEMENTADO** | `maxHttpBufferSize` + `maxCiphertextBase64Chars` |

### 2.2 Identidad y handshake

| Componente | Estado | Evidencia |
|---|---|---|
| Nova ID / Account ID / Device ID separados | **VERIFICADO** | Los tres viajan en `auth.response` y los tres se verifican contra el registro (`handshake_engine.ts` pasos 1-2) |
| Ed25519 (firma de challenge) | **VERIFICADO** | `canonical.ts` + `auth_signer.dart`; mensaje canónico `NOVA_AUTH_v1\|...` idéntico en ambos lados |
| Firma contra clave **registrada** | **VERIFICADO** | El cliente nunca envía su clave pública; `e2e_auth_matrix` caso 5 |
| Challenge CSPRNG ≥32 B, TTL, uso único | **VERIFICADO** | `challenge_store.ts`; casos 3, 6, 7, 8, 9 de `e2e_auth_matrix` |
| Challenge quemado incluso al fallar | **VERIFICADO** | `consume()` borra antes de validar; caso 8 |
| `AUTH_FAILED` genérico (sin oráculo) | **VERIFICADO** | `e2e_auth_matrix` caso 16 compara 5 fallos distintos |
| X25519 | **VERIFICADO** | Usado en X3DH y en el ratchet; ejercitado en `e2e_ab_flow` |
| X3DH | **VERIFICADO** | `x3dh_service.dart` (app) y `client/e2ee.ts` (arnés): 4 DH → HKDF. Convergencia A/B comprobada en cada corrida |
| Double Ratchet | **VERIFICADO** | Cadenas HMAC-SHA256, paso DH, claves omitidas, rechazo de replay: `e2e_ab_flow` 2/9/10 |

> Matiz honesto sobre X3DH/Double Ratchet: **verificados funcionalmente**
> (interoperan, cifran, descifran, rotan y rechazan replays). NO han
> pasado una auditoría criptográfica independiente. La implementación del
> arnés (`client/e2ee.ts`) reproduce el contrato de la implementación
> Dart; no es la misma línea de código, así que prueba el **protocolo**,
> no la corrección línea a línea del código Dart.

### 2.3 Sesiones y dispositivos

| Componente | Estado | Evidencia |
|---|---|---|
| Sesión aleatoria de 256 bits | **VERIFICADO** | `session_registry.ts`; `e2e_authorization` caso 12 |
| Expiración + renovación deslizante | **VERIFICADO** | `e2e_auth_matrix` 15, `e2e_sessions_devices` 5-6 |
| Binding socket + device + account | **VERIFICADO** | `validate(sessionId, socketKey)`; `e2e_authorization` 7 |
| Una sesión viva por dispositivo | **VERIFICADO** | `e2e_sessions_devices` 2 |
| Revocación de sesión | **VERIFICADO** | `e2e_authorization` 11 |
| Revocación de dispositivo (mata sesión + socket + bloquea re-auth) | **VERIFICADO** | `e2e_auth_matrix` 14 |
| Limpieza de sesión al desconectar | **VERIFICADO** (nuevo) | Antes la sesión quedaba en el registro tras un `disconnect`; corregido en `onDisconnect()` |

### 2.4 Mensajería

| Componente | Estado | Evidencia |
|---|---|---|
| Sólo ciphertext en el cable | **VERIFICADO** | `e2e_ab_flow` 3: el secreto no aparece ni en el almacén ni en el blob |
| Rechazo de campos en claro | **VERIFICADO** | `e2e_ab_flow` 4 prueba `plaintext/text/content/body/message` |
| `message_id` idempotente | **VERIFICADO** | `e2e_ab_flow` 5: reintento → mismo `server_seq`, un solo mensaje, un solo fan-out |
| Dedup con alcance por cuenta | **VERIFICADO** (corregido) | Antes global: otra cuenta podía "quemar" un `message_id` ajeno. Ahora la clave es `account\|message_id` |
| ACK ≠ DELIVERED ≠ READ | **VERIFICADO** | `e2e_ab_flow` 6 comprueba los tres por separado |
| `server_seq` monótono por conversación | **VERIFICADO** | `e2e_ab_flow` 8; unicidad bajo concurrencia en `e2e_presence_signaling_logs` 13 |
| Timestamps de cliente no ordenan | **VERIFICADO** | `e2e_ab_flow` 8 envía timestamps decrecientes a propósito |
| Recibos no pueden inventar mensajes | **VERIFICADO** (nuevo) | `e2e_authorization` 9 |
| `last_read_seq` acotado | **VERIFICADO** (nuevo) | `e2e_ab_flow` 7: un cliente no puede "leer el futuro" |

### 2.5 Sync

| Componente | Estado | Evidencia |
|---|---|---|
| Replay del log por cursor | **VERIFICADO** | `e2e_reconnect_sync` 3 |
| Cursor de LOG separado del de MENSAJE | **VERIFICADO** (corregido) | Antes los recibos se paginaban por `server_seq` y eran **irrecuperables**; ahora hay `log_seq`. Prueba: `e2e_reconnect_sync` 5 |
| Forma del payload idéntica en vivo y en sync | **VERIFICADO** (corregido) | Antes sync devolvía claves camelCase y en vivo snake_case: el cliente no podía descifrar lo recuperado |
| Sync de cuenta completa | **VERIFICADO** (nuevo) | `e2e_reconnect_sync` 8 |
| Paginación sin saltos | **VERIFICADO** (corregido) | El cursor avanzaba al head aunque la página se truncara → pérdida silenciosa. Prueba: `e2e_reconnect_sync` 9 |
| Contrato de cursor cliente↔servidor | **VERIFICADO** (corregido) | El cliente Dart enviaba `last_cursor`, el servidor lee `last_seq` → el servidor veía siempre 0. Prueba: `test/socket/sync_contract_test.dart` |
| Sin duplicados vivo+sync | **VERIFICADO** | `e2e_reconnect_sync` 3 y `sync_contract_test` |

### 2.6 Reconexión y red

| Componente | Estado | Evidencia |
|---|---|---|
| Reconexión → challenge nuevo → sesión nueva | **VERIFICADO** | `e2e_reconnect_sync` 1 |
| Sesión antigua nunca reutilizada | **VERIFICADO** | `e2e_reconnect_sync` 1-2 |
| WiFi → datos y datos → WiFi | **VERIFICADO** | `e2e_reconnect_sync` 6-7 (modelado como reciclaje de transporte, igual que `network_transition_handler.dart`) |
| Reintento del outbox sin duplicar | **VERIFICADO** | `e2e_reconnect_sync` 7 |
| Reinicio del servidor | **VERIFICADO** | `e2e_reconnect_sync` 10 |
| Conmutación real de red en dispositivo físico | **NO VERIFICADO** | Requiere el app en un móvil real; el entorno no lo permite |

### 2.7 Autorización

| Componente | Estado | Evidencia |
|---|---|---|
| Membresía como verdad del servidor | **VERIFICADO** | `authorization_policy.ts`; `e2e_authorization` 1-4 |
| Rooms nunca concedidas a petición | **VERIFICADO** | `e2e_authorization` 4 |
| Identidad del emisor sellada por el servidor | **VERIFICADO** | `e2e_authorization` 5 |
| Device ID / sesión ajenos rechazados | **VERIFICADO** | `e2e_authorization` 6-7 |
| Aislamiento entre cuentas | **VERIFICADO** | `e2e_authorization` 3, 10 |

### 2.8 Rate limiting

| Componente | Estado | Evidencia |
|---|---|---|
| Token bucket por dominio (servidor) | **VERIFICADO** | `e2e_rate_limits` 1-3, `e2e_presence_signaling_logs` 10-12 |
| Lockout de auth por device e IP | **VERIFICADO** | `e2e_handshake` 10, `e2e_rate_limits` 4 |
| Límite de conexiones nuevas por IP | **IMPLEMENTADO** | `connectionMiddleware`; sin prueba dedicada |
| Límites compartidos entre nodos | **AUSENTE** | En memoria: un atacante puede multiplicar su cuota por nodo. Requiere Redis |

### 2.9 Presencia

| Componente | Estado | Evidencia |
|---|---|---|
| online / offline / last_seen | **VERIFICADO** | `e2e_presence_signaling_logs` 1-3 |
| offline automático al caer el socket | **VERIFICADO** (nuevo) | Antes: si el móvil perdía cobertura, el contacto lo veía "online" para siempre |
| Sin broadcast global | **VERIFICADO** | Caso 1-2: el desconocido no recibe nada |
| Audiencia por privacidad | **VERIFICADO** | `presenceAudience()` en cada fan-out |

### 2.10 Señalización de llamadas

| Componente | Estado | Evidencia |
|---|---|---|
| `call.offer/answer/ice/end` por Socket.IO | **VERIFICADO** | `e2e_presence_signaling_logs` 5 |
| Sólo señalización, nunca media | **VERIFICADO** | Caso 8 + revisión: no hay ruta de audio/vídeo en el servidor |
| Gate por relación (contactos) | **VERIFICADO** | Caso 6 |
| Anti-spoof de identidad | **VERIFICADO** | Caso 7 |
| TURN | **AUSENTE** | Sólo STUN público; llamadas reales fallarán tras NAT simétrico |

### 2.11 Logging

| Componente | Estado | Evidencia |
|---|---|---|
| Logging redactado del servidor | **VERIFICADO** (nuevo) | `server/src/logger.ts`; antes el servidor no tenía logging estructurado |
| Sin claves/plaintext/sesiones/challenges | **VERIFICADO** | `e2e_presence_signaling_logs` 9 comprueba contenido **y** estructura |
| Identificadores truncados | **VERIFICADO** | Mismo caso: ni el account id completo aparece |
| Redacción en el cliente Dart | **IMPLEMENTADO** | `socket_log.dart` |

### 2.12 Supabase

| Componente | Estado | Evidencia |
|---|---|---|
| Directorio sobre PostgREST | **IMPLEMENTADO** | `supabase_directory.ts` |
| Almacén realtime sobre PostgREST | **VERIFICADO** (nuevo) | `supabase_store.ts` + `e2e_supabase_store` (6 casos) contra un doble de PostgREST |
| Service role sólo en backend | **VERIFICADO** | `e2e_supabase_store` 2-3: nunca llega al cliente ni al log |
| Secuencias atómicas | **VERIFICADO** (nuevo) | RPC `nova_next_seq` / `nova_next_log_seq`; falla cerrado si faltan (caso 6) |
| RLS deny-by-default del tier realtime | **IMPLEMENTADO** | `server/sql/realtime_schema.sql`; **no ejecutado** contra Postgres real |
| RLS de las tablas de la app | **NO VERIFICADO** | Las migraciones existen; no hay proyecto Supabase alcanzable para probarlas |

### 2.13 Redis

| Componente | Estado |
|---|---|
| Sesiones / challenges / dedup / rate limit / presencia compartidos | **AUSENTE** |

Consecuencia honesta: **el servidor es hoy de un solo nodo**. Con dos
réplicas sin Redis, el fan-out entre nodos no ocurre, los cursores se
duplican y los rate limits se multiplican. Está documentado en el
checklist de producción como bloqueante de escalado, no de FASE 0.5.

---

## 3. Defectos encontrados y corregidos en esta fase

Todos fueron detectados leyendo el código y confirmados con una prueba
que fallaba antes del arreglo.

| # | Defecto | Impacto | Corrección |
|---|---|---|---|
| 1 | Sync paginaba el log por `server_seq` | Un recibo delivered/read sobre un mensaje antiguo era **irrecuperable** tras reconectar: los estados divergían en silencio | Se separó `log_seq` (cursor de sync) de `server_seq` (orden de mensajes) |
| 2 | Sync devolvía el payload con claves camelCase | Un mensaje recuperado por sync **no era descifrable** por el cliente: forma distinta a la entrega en vivo | El log guarda exactamente el paquete de cable |
| 3 | El cursor de sync saltaba al head aunque la página se truncara | **Pérdida silenciosa** de eventos con >100 pendientes | El cursor avanza al último evento realmente entregado |
| 4 | Cliente Dart enviaba `last_cursor`; el servidor lee `last_seq` | El servidor interpretaba cursor 0 **siempre**: resync completo en cada reconexión | Contrato corregido + `test/socket/sync_contract_test.dart` |
| 5 | Un único cursor escalar en el cliente | Conversaciones activas arrastraban a las silenciosas: eventos saltados | Cursores por conversación |
| 6 | Dedup de `message_id` en espacio global | Una cuenta podía preregistrar ids y **anular entregas** de otra (denegación de entrega) | Clave `account_id\|message_id` |
| 7 | La sesión sobrevivía al `disconnect` del socket | Sesiones huérfanas acumulándose en el registro | Limpieza en `onDisconnect()` |
| 8 | Sin presencia offline al caer el socket | Un contacto que perdía cobertura quedaba **"online" indefinidamente** | offline + `last_seen` al último socket de la cuenta |
| 9 | `message.delivered` aceptaba ids inexistentes | Cualquier miembro podía inyectar entradas de log arbitrarias | Se valida que el mensaje exista, sea de esa conversación y no sea propio |
| 10 | `last_read_seq` sin acotar | Un cliente podía marcar como leído el futuro y silenciar mensajes posteriores | Acotado al `server_seq` real |
| 11 | Sin sync de cuenta completa | Tras reconectar no se recuperaban chats no abiertos | `sync.request` sin `conversation_id` |
| 12 | Sin logging estructurado en el servidor | Imposible auditar; riesgo de logs ad-hoc con secretos | `SecurityLog` redactado + prueba de fuga |
| 13 | El cliente Dart no emitía `message.delivered` | DELIVERED nunca se producía en la app real | `markMessageDelivered()` |

---

## 4. Lo que NO se pudo verificar

Declarado explícitamente, sin sustituirlo por afirmaciones optimistas.

| Área | Motivo |
|---|---|
| `flutter analyze` / `flutter test` | **NOT RUN — Flutter SDK unavailable.** No hay SDK en el entorno y la red bloquea `storage.googleapis.com` y `pub.dev` |
| RLS real de Supabase | No hay proyecto alcanzable; el esquema se entrega listo pero sin ejecutar |
| TLS/WSS con certificado real | El servidor no termina TLS por diseño (balanceador L7); no probado extremo a extremo |
| Conmutación WiFi↔datos en hardware real | Modelada a nivel de transporte, no ejecutada en un móvil |
| Comportamiento multi-nodo | Sin Redis no hay segundo nodo que probar |
| WebRTC con media real | Fuera del alcance: FASE 0.5 valida sólo el transporte de señalización |
| Carga masiva | Se probaron 10 conexiones concurrentes según lo pedido; no hay prueba de miles |

---

## 5. Riesgos vigentes

1. **Un solo nodo (ALTO para escalado).** Sin Redis no hay horizontalidad:
   estado caliente en memoria del proceso.
2. **Sin TURN (ALTO para llamadas).** Bloqueante funcional cuando se
   implementen llamadas de verdad; no afecta a FASE 0.5.
3. **RLS no ejecutada (MEDIO).** El modelo es deny-by-default y correcto
   por revisión, pero no probado contra Postgres.
4. **Criptografía sin auditoría externa (MEDIO).** X3DH y Double Ratchet
   funcionan e interoperan; eso no equivale a estar auditados.
5. **Cliente Flutter sin ejecutar (MEDIO).** Los cambios en
   `websocket_service.dart` están cubiertos por pruebas Dart escritas,
   pero **no ejecutadas** en este entorno.
6. **Almacén en memoria por defecto (MEDIO).** Con `STORE_BACKEND=memory`
   un reinicio pierde el historial caliente; producción debe usar
   `supabase`.

---

## 6. Veredicto por bloque

| Bloque del criterio §26 | Estado |
|---|---|
| Authentication | ✅ VERIFICADO |
| Authorization | ✅ VERIFICADO |
| E2EE envelope | ✅ VERIFICADO |
| Message delivery | ✅ VERIFICADO |
| ACK (SENT/DELIVERED/READ) | ✅ VERIFICADO |
| Deduplication | ✅ VERIFICADO |
| Reconnection | ✅ VERIFICADO |
| Sync | ✅ VERIFICADO |
| Device revocation | ✅ VERIFICADO |
| Rate limiting | ✅ VERIFICADO (un nodo) |
| Presence | ✅ VERIFICADO |
| Signaling | ✅ VERIFICADO |
| Supabase en la ruta A→servidor→B | ✅ VERIFICADO (contra doble de PostgREST) |

Detalle de ejecución y comandos: `docs/E2E_REALTIME_TESTING.md`.
Pendientes para producción: `docs/REALTIME_PRODUCTION_CHECKLIST.md`.
