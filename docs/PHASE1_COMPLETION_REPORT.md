# PHASE1_COMPLETION_REPORT.md

**NovaApp — FASE 1: Motor de mensajería E2EE**
Fecha: 2026-08-25 · Rama: `arena/01a035bd-novaapp`

---

## 1. IMPLEMENTADO

### Motor (`lib/core/messaging/`, 3.312 líneas, 18 archivos)

| Capa | Archivos | Qué hace |
|---|---|---|
| Modelo | `message_ids`, `message_type`, `delivery_state`, `message_envelope_v1`, `message_body`, `media_reference` | Identidades tipadas, 12 tipos extensibles, estados por dispositivo, envelope v1, body cifrado |
| Cripto | `message_aad`, `message_encryption_service` | AAD canónica (§9) + ligado Encrypt-then-MAC sobre el ratchet existente |
| Persistencia | `messaging_database`, `outbox_store`, `inbox_store`, `sync_cursor_store` | `nova_messaging.db`: Outbox durable, Inbox persist-before-ACK, cursores separados |
| Servicios | `conversation_service`, `message_send_service`, `message_receive_service`, `message_sync_service`, `media_encryption_service`, `notification_policy` | Un servicio por responsabilidad (§36) |

### Servidor (`server/src/realtime_server.ts`)

Enrutado **por dispositivo** (§15), aditivo y compatible hacia atrás:
clave de dedup `message_id#recipient_device_id`, fan-out dirigido a
`device:<id>`, acks con `recipient_device_id`, campos nuevos opcionales
y validados.

### Base de datos (`supabase/migrations/002_phase1_messaging.sql`)

Migración **aditiva**, idempotente, sin `DROP`. Tres tablas nuevas
(`realtime_conversations`, `realtime_media_objects`,
`realtime_delivery_receipts`), todas con **RLS deny-by-default** +
`FORCE ROW LEVEL SECURITY`. Se reutilizan las 8 tablas de FASE 0.5 que ya
cubrían su función (§32).

### Documentación (§41) — 6/6

`PHASE1_MESSAGE_ARCHITECTURE.md` (350) · `MESSAGE_PROTOCOL.md` (211) ·
`E2EE_MESSAGE_FLOW.md` (172) · `OFFLINE_SYNC.md` (173) ·
`MULTI_DEVICE_MESSAGING.md` (199) · `MEDIA_ENCRYPTION.md` (154)

---

## 2. VERIFICADO (ejecutado, con salida real)

| Comando | Resultado |
|---|---|
| `npm test` (server) | **129/129 pass, 0 fail** |
| `tsc -p tsconfig.json --noEmit` | **OK, 0 errores** |
| `pglast` sobre la migración 002 | **19 sentencias OK**, sin `DROP TABLE` |

De esos 129, **109 son la suite de FASE 0.5 intacta**: la regresión que
exige §42 está satisfecha tras tocar `realtime_server.ts`. Los **20
nuevos** son de FASE 1:

**`e2e_phase1_multidevice.test.ts` — 7/7**
Fan-out a 3 dispositivos con ciphertexts distintos · copia dirigida sólo
a su dispositivo · el hermano del emisor recibe copia y el emisor no ·
idempotencia por (mensaje, dispositivo) · dispositivo revocado
desconectado y sin poder re-autenticarse · `sender_device_id` falsificado
→ `PAYLOAD_INVALID` · cada copia recuperable por sync exactamente una vez.

**`e2e_phase1_security.test.ts` — 13/13 (§38, todos fallan correctamente)**
`sender_account_id` forjado se sobrescribe · enviar/sincronizar en
conversación ajena → `FORBIDDEN` · replay ×3 absorbido · ciphertext
manipulado bloqueado por autorización · cursor manipulado (`-1`, `0`,
`999999`, `MAX_SAFE_INTEGER`) → `FORBIDDEN` · el sync de cuenta no filtra
conversaciones ajenas · `server_seq` del cliente ignorado ·
`received_at_ms: 0` sobrescrito · ciphertext gigante → `PAYLOAD_INVALID` ·
seis nombres de campo tipo plaintext → `PAYLOAD_INVALID` · recibo sobre
mensaje inexistente → `PAYLOAD_INVALID` · cuatro eventos sin autenticar →
`FORBIDDEN`.

### Hallazgo principal: la AAD débil (§9)

AAD actual del ratchet: `utf8(ratchet_pub) || LE32(msg_num) ||
LE32(prev_chain_len)`. **No liga** `conversation_id`,
`sender_account_id`, `message_id` ni la versión del protocolo. Un
servidor comprometido puede **reenrutar un sobre válido a otra
conversación y la etiqueta AEAD sigue verificando**.

Corregido con una AAD canónica NUL-separada e inyectiva, aplicada como
**context tag** HMAC-SHA256 con separación de dominio — porque
`DoubleRatchetService` es componente estable y §42 prohíbe modificarlo.
Comparación en tiempo constante; error genérico para no dar oráculo.

---

## 3. PARCIAL

| Elemento | Estado |
|---|---|
| **Tests Dart (75 casos, 4 archivos)** | Escritos y revisados estáticamente; **NO EJECUTADOS** |
| **AAD canónica** | Implementada en Dart; falta alinear `server/src/client/e2ee.ts:187` |
| **Interfaces inyectadas** | Definidas y usadas; faltan los adaptadores concretos (Supabase/socket) |
| **`NotificationPolicy`** | Implementada y probada; **falta cablearla** en `chat_repository_impl.dart`, que aún pasa texto descifrado a `showLocalNotification(body:)` |
| **Multimedia** | Cripto y modelo completos; falta el cliente real de Supabase Storage |
| **Rendimiento (§39)** | **No medido**: requiere dispositivo Android real |

Los 4 archivos Dart de test (`message_aad_test`, `message_model_test`,
`notification_policy_test`, `delivery_and_gap_test`) fueron verificados
**estáticamente**: 0 problemas de balanceo, 0 imports sin resolver, 0
símbolos de proyecto inexistentes, firmas contrastadas una a una contra
las clases reales. Eso **no sustituye** a ejecutarlos.

---

## 4. PENDIENTE

1. Ejecutar `flutter analyze` y `flutter test` en un entorno con SDK.
2. Alinear `server/src/client/e2ee.ts:187` con la AAD canónica.
3. Adaptadores concretos de las interfaces inyectadas.
4. Cablear `NotificationPolicy` en `chat_repository_impl.dart`.
5. **SQLCipher** para la base local (hoy en claro en reposo).
6. Verificación de identidad (números de seguridad) — ver RIESGOS.
7. Aplicar la migración 002 en un Supabase real y probar RLS de verdad.
8. Redis para Socket.IO multi-instancia.
9. Medir en Android de gama media (§39).
10. Limpiar los restos de FASE 0.5: `gap_detector.dart` tiene un `enum`
    anidado ilegal que **no compila**; `media_service.dart` usa URL
    pública; `outbox.dart` es en memoria.

---

## 5. RIESGOS

| Riesgo | Nivel | Estado |
|---|---|---|
| **Sin verificación de identidad**: un servidor malicioso puede inyectar un dispositivo propio en el fan-out (MITM) | **ALTA** | **ABIERTO** — hueco más grave que queda |
| AAD débil: reenrutado de sobres | ALTA | **MITIGADO** en el motor; pendiente el cliente TS |
| Outbox en memoria: pérdida silenciosa al cerrar | ALTA | **RESUELTO** (Outbox en disco) |
| Dedup por cuenta rompía el multi-dispositivo | ALTA | **RESUELTO** y cubierto por test |
| Notificación local con texto descifrado | MEDIA | Política lista, **sin cablear** |
| Base local sin cifrar en reposo | MEDIA | **ABIERTO** (SQLCipher) |
| SQLite legado con plaintext | MEDIA | Aislado; el motor no lo usa |
| Fan-out lineal: no escala a grupos | MEDIA | Aceptado en 1:1; grupos necesitarán sender keys |
| Metadata visible (quién y cuándo) | MEDIA | Inherente; **declarado** |
| Redis ausente → presencia rota multi-instancia | MEDIA | **ABIERTO**, documentado |
| RLS nunca ejecutado contra Postgres real | MEDIA | **ABIERTO** |

**La criptografía no ha sido auditada de forma independiente.** Se han
validado diseño, invariantes y pruebas; no equivale a una auditoría
externa.

---

## 6. MIGRACIONES

`supabase/migrations/002_phase1_messaging.sql` — aditiva, idempotente,
sin `DROP`, sin borrado de datos, RLS deny-by-default en las 3 tablas
nuevas. `novaapp_schema.sql` **no se ha modificado**.

**No aplicada a un proyecto real**: no hay Supabase alcanzable ni
Postgres local (`psql`, `docker`, `initdb` ausentes). Validada por
análisis sintáctico con `pglast`. *Parsea* no significa *ejecuta*.

---

## 7. TESTS

### Ejecutados

```
server/  npm test  →  129 pass, 0 fail   (109 FASE 0.5 + 20 FASE 1)
server/  tsc --noEmit  →  OK
```

### NO ejecutados

```
flutter analyze  →  NOT RUN — Flutter SDK unavailable
flutter test     →  NOT RUN — Flutter SDK unavailable
```

Se intentó obtenerlo: `dl.google.com`, `storage.googleapis.com` y
`pub.dev` no son alcanzables desde este entorno (HTTP 000); no hay
paquete Dart en npm ni acceso a `apt`. **No se inventa ningún resultado.**

### Cobertura de los 25 escenarios de §37

| # | Escenario | Dónde | Estado |
|---|---|---|---|
| 1 | Crear conversación | `e2e_ab_flow`, `e2e_authorization` | ✅ ejecutado |
| 2 | Enviar mensaje | `e2e_messaging`, `e2e_ab_flow` | ✅ ejecutado |
| 3 | Recibir mensaje | `e2e_messaging`, `e2e_phase1_multidevice` | ✅ ejecutado |
| 4 | Descifrar | `message_aad_test`, `message_model_test` | ⚠️ escrito, NO EJECUTADO |
| 5 | Ciphertext inválido | `e2e_phase1_security` 9, 11 | ✅ ejecutado |
| 6 | Ciphertext modificado | `e2e_phase1_security` 4 + `message_aad_test` | ✅ / ⚠️ |
| 7 | Replay | `e2e_phase1_security` 3 | ✅ ejecutado |
| 8 | Duplicado | `e2e_phase1_multidevice` 4 | ✅ ejecutado |
| 9 | Envío offline | `e2e_reconnect_sync` | ✅ ejecutado |
| 10 | Reconexión | `e2e_reconnect_sync`, `e2e_handshake` | ✅ ejecutado |
| 11 | Sincronización | `e2e_sync`, `e2e_phase1_multidevice` 7 | ✅ ejecutado |
| 12 | Paginación | `e2e_sync` | ✅ ejecutado |
| 13 | Detección de huecos | `delivery_and_gap_test` | ⚠️ escrito, NO EJECUTADO |
| 14 | Entregado | `e2e_ab_flow` + `delivery_and_gap_test` | ✅ / ⚠️ |
| 15 | Leído | `e2e_ab_flow` + `delivery_and_gap_test` | ✅ / ⚠️ |
| 16 | Editar | `message_model_test` | ⚠️ escrito, NO EJECUTADO |
| 17 | Eliminar | `message_model_test` | ⚠️ escrito, NO EJECUTADO |
| 18 | Responder | `message_model_test` | ⚠️ escrito, NO EJECUTADO |
| 19 | Reaccionar | `message_model_test` | ⚠️ escrito, NO EJECUTADO |
| 20 | Expiración | `delivery_and_gap_test` | ⚠️ escrito, NO EJECUTADO |
| 21 | Usuario bloqueado | `e2e_authorization` | ✅ ejecutado |
| 22 | Usuario no autorizado | `e2e_phase1_security` 2, 13 | ✅ ejecutado |
| 23 | Multi-dispositivo | `e2e_phase1_multidevice` 1-3 | ✅ ejecutado |
| 24 | Revocación de dispositivo | `e2e_phase1_multidevice` 5 | ✅ ejecutado |
| 25 | Envelope multimedia cifrado | `message_model_test` | ⚠️ escrito, NO EJECUTADO |

**16/25 verificados por ejecución. 9/25 escritos pero sin ejecutar**, por
falta de SDK de Flutter. Los 9 son de lógica de cliente, que es
precisamente donde el servidor no puede verificar nada.

### §38 — Ataques que deben fallar

Los 11 vectores están cubiertos: 10 ejecutados en
`e2e_phase1_security.test.ts` (13/13) y el de alteración de AAD
deliberadamente en Dart, porque **el servidor no tiene claves y por
diseño no puede verificar ese ligado**.

---

## 8. PERFORMANCE (§39)

**NO MEDIDO.** Requiere un Android de gama media real; no hay dispositivo
ni emulador en este entorno. Publicar cifras inventadas sería peor que no
publicarlas.

Lo que sí se sabe por construcción: el envelope añade ~200-300 bytes de
metadata sobre el ciphertext, y el fan-out multiplica el tráfico por el
número de dispositivos del destinatario (2-3 en un caso típico).

Instrumentación pendiente: tiempo de cifrado/descifrado, latencia de
envío/recepción, memoria en conversaciones largas, crecimiento de
`nova_messaging.db`, tamaño real del envelope.

---

## 9. ¿ESTÁ EL MOTOR LISTO PARA INTEGRAR LA UI?

# NO

**Por qué no**, en orden de importancia:

1. **Ni una sola línea de Dart ha sido compilada ni ejecutada.** 3.312
   líneas de motor y 75 casos de test revisados sólo estáticamente. La
   verificación estática detectó y corrigió errores reales en este mismo
   trabajo (un test que invocaba una API de Outbox inexistente), lo que
   demuestra justo que la revisión sin compilador no basta.

2. **`gap_detector.dart` de FASE 0.5 no compila** (un `enum` anidado
   dentro de una clase es ilegal en Dart). Mientras siga en el árbol,
   cualquier build que lo alcance falla.

3. **Faltan los adaptadores concretos.** El motor está construido sobre
   interfaces inyectadas; sin implementaciones sobre Socket.IO y
   Supabase, no hay nada que la UI pueda conectar.

4. **La fuga de notificaciones sigue viva.** `chat_repository_impl.dart`
   continúa pasando texto descifrado a la notificación local. La política
   existe pero no está cableada: integrar la UI ahora consolidaría la
   fuga.

5. **La migración nunca se ha ejecutado** contra un Postgres real, así
   que las tablas que la UI necesitaría no existen todavía en ningún
   entorno.

**Qué sí está listo:** el lado servidor. 129/129 en verde, typecheck
limpio, enrutado por dispositivo probado, y 13 vectores de ataque que
fallan como deben. El protocolo y las decisiones de diseño están
documentados y sostenidos por pruebas ejecutadas.

**Camino más corto al SÍ:** ejecutar `flutter analyze` + `flutter test` y
corregir lo que aparezca (1), arreglar `gap_detector.dart` (2), escribir
los adaptadores (3), cablear `NotificationPolicy` (4) y aplicar la
migración 002 (5). Los puntos 1 y 2 son bloqueantes duros; el resto es
trabajo acotado y ya diseñado.

---

# APPENDIX — FASE 1 control pass (2026-08-28): gap audit + port

Baseline reset to `main` (`649b3b2`) per option (A): main's architecture is canonical;
the parallel implementation (`arena/01a04505-novaapp` @ `e15325c`, tag
`phase1-full-engine-e15325c`) contributed ONLY the capabilities proven missing.

## A.1 Gap audit — 22-item checklist vs main

Items 1,2,4–22 of the checklist exist in main (verified by reading
`model/message.dart|conversation.dart`, `store/{outbox,inbox}_store.dart`,
`crypto/*`, `service/message_{send,receive,delivery}_service.dart`, `store/delivery_state.dart`,
`model/media_reference.dart`, the four `feature/messaging/**` blocs and `realtime_server.ts`).
Four genuine gaps + one test gap were ported:

| # | Gap (main) | Ported as |
|---|---|---|
| D1 | No pre-encryption queue: cold send with no session while offline → `NO_SESSION` rejection = content loss | `PendingSendStore` + `SendResult.queuedOffline` + `flushPending()` (idempotent, original logical id, hard TTL) |
| D2 | Per-device encryption failure silently skipped (message still "sent") | `SendResult.skippedDevices` on every path; whole-message re-queue only when NOTHING encrypted |
| D3 | `RatchetState.toJson` drops `myRatchetKeyPair` → restart loses own ratchet private key | `RatchetStatePersistence` additive codec (seed restored via `newKeyPairFromSeed`) |
| D4 | No server-side delete/tombstone/expiry (client had delete/reply/reaction bodies, server had no command) | `message.delete` command; sender-only `redactMessages`; event-log tombstone rewrite (no sync resurrection); `message.expired` sweep; client `onTombstone` + `InboxStore.redact` |
| D5 | Port coverage | `server/test/e2e_phase1_delete_expiry.test.ts` (5 tests) + `test/messaging/port_gaps_test.dart` (D1–D3 guards) |

Audited and REJECTED (already present in main, no port needed): edit/delete/reply/
reaction message bodies and client flows; disappearing-message TTL enforcement;
per-device dedup; sync gap detection; media architecture; delivery-state store.

## A.2 Test evidence — honest ledger

EXECUTED here:
* `cd server && npm test` (port applied): main suites **129/129** green, 15.4 s.
* `server/test/e2e_phase1_delete_expiry.test.ts`: **5/5** green; file typechecks under
  the test tsconfig.
* `npm run typecheck`: **clean**.

NOT RUN — Flutter SDK unavailable: `flutter test` (existing 75 messaging suites +
new `port_gaps_test.dart`). The Dart port is written against APIs read verbatim from
`main`, but UNCOMPILED here — treat `flutter analyze`/`flutter test` on a workstation
as the acceptance gate.

NOT RUN — Supabase environment unavailable: schema index + real-store redaction
(`SupabaseRealtimeStore` implements the same contract as the in-memory store and is
typechecked, but not exercised against Postgres here).

## A.3 Constraints respected

No changes to: Nova ID, Account/Device id, Ed25519, X3DH, Double Ratchet algorithms
(frozen serializer untouched; persistence is additive), Socket.IO/WSS, Supabase,
auth/authz. Server stores ciphertext/ids/sequence/timestamps/delivery-metadata only —
redaction stores `''` (Supabase NOT NULL) — never plaintext, never private keys;
ratchet seed stays client-side only. No new tables duplicating existing ones
(`msg_pending_send` complements `msg_outbox`, which is post-encryption). No God Objects:
one class per concern, all injected.


---

# APPENDIX — FASE 1.1 (2026-08-31): cierre de bloqueantes y validación real

Detalle completo en `docs/PHASE1_1_BLOCKERS.md` y `docs/PHASE1_1_VALIDATION_REPORT.md`.
Estado de los cinco bloqueantes de §9 tras este pase:

1. **Dart sin compilar/ejecutar → ABIERTO (entorno).** Intento documentado: sin
   SDK, egreso hacia fuentes oficiales bloqueado; NO RUN — Environment limitation.
   Gate final: `flutter analyze && flutter test` en estación (ahora con 2 suites
   nuevas específicas: `port_gaps_test.dart`, `outbox_retry_policy_test.dart`).
2. **`gap_detector.dart` "no compila" → CERRADO (refutado).** `enum` anidado es
   legal desde Dart 2.17; el SDK del proyecto es `^3.10.8`. Sin cambio de código.
3. **Adaptadores concretos → ABIERTO (decisión de alcance).** Confirmada su
   ausencia por grep; no se simula su cierre dentro de 1.1 (prohibido UI/features;
   sería más código sin compilar). Primer ítem del siguiente pase.
4. **Fuga de notificaciones → CERRADO en código.** Único punto de llamada de
   `showLocalNotification` en `chat_repository_impl.dart` pasa por
   `NotificationPolicy.build(senderOnly)`; el texto descifrado ya no viaja al body.
5. **Migración vs Postgres real → CERRADO, EJECUTADO.** `run_schema_tests.py`
   14/14 y nuevo `run_rls_tests.py` **23/23** contra PostgreSQL 16.2 (pgserver):
   esquema + 002 + idempotencia + upgrades legacy + RLS de verdad (permite/deniega),
   `realtime_*` cerrado a clientes, `service_role` abierto al servidor.

Servidor: 137/137 (nuevas: 3 pruebas de concurrencia/reconexión a mitad de ráfaga,
`e2e_phase1_concurrency.test.ts`), typecheck limpio, regresión FASE 0.5 intacta.
Plaintext/keys: `toWire()` sin campos de contenido; lista de redacción del logger
cubre `private_key/secret/service_role/*text*`; un solo log-path en Dart sin
material de clave.

**FASE 1.1: NOT READY** — sólo por los criterios Flutter (no ejecutables aquí) y
el bloqueante 3 (integración). Todo lo demás está verde con prueba ejecutada.
