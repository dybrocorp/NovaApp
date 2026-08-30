# PHASE1_MESSAGE_ARCHITECTURE.md

**FASE 1 — Motor de mensajería E2EE de NovaApp**
Fecha: 2026-08-25 · Rama: `arena/01a035bd-novaapp`
Estado: análisis previo a implementación (§3 obligatorio)

---

## 0. Alcance

Este documento es el **análisis exigido por §3**: qué existe, qué es
reutilizable, qué falta y qué está roto. Ninguna decisión de
implementación se tomó antes de completarlo.

FASE 1 construye el **motor**. No hay UI de producto (§40): sólo lo
mínimo para ejercitar el dominio.

---

## 1. Inventario del código existente

### 1.1 Capa socket (FASE 0.5 — reutilizar, no tocar)

```
lib/core/socket/
  auth/{auth_payloads,auth_signer,socket_session}.dart   handshake Ed25519
  messaging/{message_envelope,outbox,ack_state,gap_detector}.dart
  protocol/{challenge_store,session_registry,device_registry,
            handshake_engine,message_dedup,authorization_policy}.dart
  {socket_config,socket_events,rate_limiter,reconnect_policy,
   network_transition_handler,heartbeat_watchdog,socket_log}.dart
lib/core/services/websocket_service.dart                 cliente Socket.IO
server/src/…                                             servidor real
```

**Validado en FASE 0.5 con 109 pruebas E2E.** Se reutiliza tal cual.

### 1.2 Criptografía existente (reutilizar)

| Componente | Archivo | Estado real |
|---|---|---|
| X3DH | `lib/core/services/x3dh_service.dart` | Real: 4 DH → HKDF-SHA256. Verificado en FASE 0.5 |
| Double Ratchet | `lib/core/services/double_ratchet_service.dart` | Real: HKDF root, HMAC-SHA256 chains, AES-256-GCM. Verificado |
| Firma de handshake | `lib/core/socket/auth/auth_signer.dart` | Ed25519 sobre canónico `NOVA_AUTH_v1` |
| `EncryptionService` | `lib/core/services/encryption_service.dart` | X25519 + ChaCha20-Poly1305. **Ruta legacy**, ver §3.2 |

Primitivas en uso: **X25519, Ed25519, HKDF-SHA256, HMAC-SHA256,
AES-256-GCM**. Cumple §7: no hay AES-CBC, ECB, MD5, SHA1 ni criptografía
propia. **No se cambia ninguna primitiva.**

### 1.3 Dominio de chat actual (legacy — NO reutilizable como motor)

`lib/features/chat/domain/models.dart` define `Message`:

```dart
class Message {
  final String senderId;      // Nova ID como identidad → viola §4
  final String chatId;        // no es un conversation_id UUID
  final String? text;         // PLAINTEXT en el modelo → viola §5
  final MessageType type;     // 6 tipos, sin extensibilidad → §6
  final String status;        // string suelto 'sent'/'delivered'/'read'
}
```

Problemas frente a los requisitos de FASE 1:

- **§5 lo prohíbe explícitamente**: el modelo lleva `text` en claro.
- **§4**: usa Nova ID como identidad de enrutado; no hay `conversation_id`,
  `account_id`, `device_id` ni `client_message_id`.
- **§17**: `status` es un string único, no estados por destinatario.
- Sin `server_sequence`, `version`, `edited_at`, `deleted_at`, `expires_at`.

**Decisión: no se modifica ni se borra.** Se construye el motor nuevo en
paralelo (`lib/core/messaging/`) y el legacy queda intacto hasta que la UI
migre en una fase posterior. Así no se rompe nada que hoy compile (§42).

### 1.4 Almacenamiento local actual

`lib/core/services/database_service.dart` — SQLite v5, dos tablas
(`contacts`, `messages`) con **plaintext en la columna `text`**, sin
cifrado en reposo y con datos de ejemplo sembrados.

Frente a §34 (threat model del almacenamiento local): un backup del
dispositivo o un atacante con acceso al sistema de archivos lee todos los
mensajes. Se aborda en §7 de este documento.

### 1.5 Servicios auxiliares revisados

| Servicio | Reutilizable | Nota |
|---|---|---|
| `offline_sync_service.dart` | ❌ | Cola **en memoria** (`List<Map>`): se pierde al cerrar el app. Viola §12 (Outbox persistente) |
| `message_status_service.dart` | Parcial | Trabaja sobre el modelo legacy |
| `multi_device_service.dart` | ✅ | `device_approvals`, revocación — sirve para §16 |
| `ephemeral_message_service.dart` | Parcial | Lógica de TTL aprovechable para §22 |
| `media_service.dart` | ❌ | `uploadFile` es un **stub**: construye una URL pública y no sube nada. Viola §23/§24 |
| `notification_service.dart` | ⚠️ | Muestra `body` con texto del mensaje → viola §27 |
| `privacy_service.dart` | ✅ | Lee/escribe `user_settings` — base para §28 |
| `moderation_service.dart` | ✅ | `blocked_users` — base para §29 |

### 1.6 Base de datos (Supabase)

`supabase/novaapp_schema.sql` (unificado, 34 tablas). Relevantes:

- App: `messages`, `contacts`, `message_reactions`, `typing_indicators`,
  `blocked_users`, `user_settings`, `reports`.
- Tier realtime (`realtime_*`, deny-by-default): `realtime_messages`,
  `realtime_events`, `realtime_cursors`, `realtime_conversation_members`,
  `realtime_contacts`, `realtime_presence*`.

**§32 — no duplicar tablas.** Antes de crear nada se buscó equivalente:

| Necesidad FASE 1 | ¿Existe? | Decisión |
|---|---|---|
| Sobres E2EE + secuencia | `realtime_messages` | **Reutilizar** |
| Log de eventos + cursor sync | `realtime_events`, `realtime_cursors` | **Reutilizar** |
| Membresía de conversación | `realtime_conversation_members` | **Reutilizar** |
| Bloqueo | `blocked_users` | **Reutilizar** |
| Ajustes de privacidad | `user_settings` | **Reutilizar** |
| Reacciones | `message_reactions` (ligada a `messages` legacy) | **No sirve**: el motor no usa `messages`. Las reacciones viajan como **eventos cifrados**, sin tabla nueva |
| Metadata de conversación | ✗ | Sólo hay membresía. **Nueva**: `realtime_conversations` (migración aditiva) |
| Objetos multimedia cifrados | ✗ | **Nueva**: `realtime_media_objects` (migración aditiva) |

Sólo **dos tablas nuevas**, ambas en una migración aditiva separada, sin
tocar destructivamente el esquema unificado (§43).

---

## 2. Modelo de identidad y conversación (§4)

Se respeta la separación ya existente:

```
Nova ID       NVA-7K4X-92PM   identificador público, legible
Account ID    UUID            identidad de cuenta (routing/authz)
Device ID     UUID            identidad criptográfica por dispositivo
Conversation  UUID            NUNCA derivado del Nova ID
Message ID    UUID v4         generado por el cliente = clave de idempotencia
```

**Nova ID nunca es primary key** (§4). El servidor autoriza por
`account_id` contra `realtime_conversation_members`.

`conversation_id` es un UUID aleatorio, **no** una función de los
participantes. Razón: un id derivado (p. ej. `hash(A|B)`) permitiría a
cualquiera enumerar si dos cuentas concretas hablan entre sí, sondeando
ids. Un UUID opaco no filtra el grafo social.

---

## 3. Decisiones criptográficas

### 3.1 AAD — hallazgo principal del análisis (§9)

El AAD actual (`double_ratchet_service.dart:338`) sólo cubre:

```
ratchet_public_key || message_number || previous_chain_length
```

**No cubre** `conversation_id`, `sender_account_id`, `message_id` ni la
versión de protocolo. §9 exige exactamente lo contrario: el servidor no
debe poder alterar en silencio la identidad de conversación, remitente,
mensaje ni versión.

Consecuencia concreta hoy: un servidor comprometido puede tomar un sobre
válido de la conversación X y **reenrutarlo a la conversación Y** (o
cambiar el `sender_account_id` mostrado). El AEAD sigue verificando,
porque esos campos no están autenticados. El destinatario ve un mensaje
auténticamente cifrado atribuido a un contexto falso.

**Decisión:** el motor de FASE 1 define un AAD canónico versionado que
liga el contexto completo, sin tocar el Double Ratchet existente
(compatibilidad §42):

```
NOVA_MSG_AAD_v1 | conversation_id | sender_account_id | sender_device_id
                | message_id | message_type | envelope_version
```

Se documenta en `docs/MESSAGE_PROTOCOL.md` y se prueba en los tests de
seguridad (§38): alterar cualquiera de esos campos debe producir **fallo
de autenticación**, no un descifrado silencioso.

### 3.2 `EncryptionService` legacy

Usa X25519 + ChaCha20-Poly1305 con DH **estático**: sin ratchet, sin
forward secrecy, y la misma clave compartida para toda la conversación.
Es la ruta del chat legacy.

**Decisión:** el motor **no** lo usa. Todo mensaje del motor pasa por
X3DH + Double Ratchet. `EncryptionService` se deja intacto para no romper
el chat legacy, y se documenta como deprecado para el motor.

### 3.3 Separación identidad / autenticación / cifrado (§7)

| Función | Clave | Uso |
|---|---|---|
| Identidad y firma | Ed25519 (por dispositivo) | Firmar el challenge del handshake |
| Acuerdo de claves | X25519 (IK/SPK/OPK) | X3DH |
| Cifrado de mensajes | AES-256-GCM con MK del ratchet | Contenido |

Tres dominios de clave separados. La clave de handshake **nunca** cifra
contenido; la clave de mensaje **nunca** autentica identidad.

---

## 4. Multidispositivo (§15) — decisión y su coste

Modelo elegido: **fan-out por dispositivo (sender-side)**.

```
Account A                          Account B
├── Device A1  (envía)             ├── Device B1  sesión ratchet propia
├── Device A2  copia propia        └── Device B2  sesión ratchet propia
└── Device A3  copia propia
```

El emisor cifra **una vez por dispositivo destino** (incluidos sus otros
dispositivos) y emite N sobres con el **mismo `client_message_id`** y
distinto `target_device_id`.

Por qué así y no un "sender key" de conversación:

- Cada par de dispositivos mantiene su propio Double Ratchet → se conserva
  forward secrecy y post-compromise security por dispositivo.
- Revocar un dispositivo no obliga a rotar la clave de todos.
- Nunca se copia una clave privada entre dispositivos (§15 lo prohíbe).

Coste honesto: el tráfico crece **lineal con el número de dispositivos**
del destinatario. Para 1:1 con 2-3 dispositivos por cuenta es aceptable.
Para grupos grandes no escala; los grupos (fase posterior) necesitarán
sender keys. Queda documentado como límite conocido.

Un dispositivo **no aprobado** no recibe sobres (§16): la lista de
destinos sale de `devices` con `status='active'`, verdad del servidor.

---

## 5. Estados de entrega (§17)

`SENT`, `DELIVERED` y `READ` ya están separados en el servidor y en
`AckStateMachine` (FASE 0.5). FASE 1 añade la dimensión que faltaba: el
estado es **por destinatario y dispositivo**, no un escalar del mensaje.

```
message_id X
├── device B1 → DELIVERED (t1)
└── device B2 → READ (t2)
```

El estado agregado que verá la UI se **deriva** (mínimo de los
dispositivos activos), no se almacena como booleano.

---

## 6. Multimedia (§23-§26)

`media_service.uploadFile()` es hoy un stub que devuelve una URL pública
y no sube nada — inservible y, si se completara así, violaría §24
("no URLs públicas permanentes").

Arquitectura de FASE 1:

```
archivo → clave AES-256-GCM aleatoria POR OBJETO (no la del ratchet)
        → cifrado local → subida del blob cifrado a Storage
        → el mensaje E2EE lleva {object_id, key, nonce, sha256, size}
        → el receptor descarga, verifica el hash y descifra localmente
```

Puntos clave:

- La **clave del objeto viaja dentro del ciphertext del mensaje**, nunca
  en metadata. El servidor almacena bytes opacos y no puede descifrarlos.
- `object_id` aleatorio, sin relación con la conversación (§24).
- Thumbnails **generados localmente antes de cifrar** (§25); el servidor
  no puede leer la imagen.
- Notas de voz: mismo camino, sin procesamiento server-side (§26).

---

## 7. Threat model del almacenamiento local (§34)

**Qué se guarda en el dispositivo**

| Dato | Dónde | Protección |
|---|---|---|
| Claves privadas de identidad | `flutter_secure_storage` | Keychain / Keystore |
| Estado del ratchet | secure storage | Keychain / Keystore |
| Mensajes descifrados | SQLite | **Hoy sin cifrar** |
| Cola Outbox/Inbox | SQLite | Sólo ciphertext + metadata |

**De qué protege**: pérdida del dispositivo con bloqueo activo; otras apps
del sistema (sandbox); lectura del tráfico de red (E2EE).

**De qué NO protege** (declarado sin adornos):

- dispositivo rooteado o con jailbreak;
- backups sin cifrar del sistema operativo;
- atacante con el dispositivo desbloqueado;
- capturas de pantalla o exportaciones hechas por el propio usuario.

**Decisión FASE 1**: Outbox e Inbox guardan **sólo ciphertext**; el
plaintext descifrado se mantiene en memoria para la UI. Persistir
plaintext descifrado requiere SQLCipher y queda documentado como
pendiente — no se finge que esté hecho.

---

## 8. Qué se implementa en FASE 1

```
lib/core/messaging/
  model/       ids, conversation, message, envelope, delivery state, media ref
  crypto/      AAD canónico + servicio de cifrado de mensajes
  store/       Outbox e Inbox PERSISTENTES (SQLite) + esquema propio
  service/     conversación, envío, recepción, sync, media
```

Servicios separados según §36 (sin God Object): modelo, repositorio,
cifrado, outbox, inbox, sync, entrega, media — cada uno con una
responsabilidad.

### Lo que NO se implementa (§45)

Videollamadas, llamadas de audio, TURN, grupos avanzados, historias,
canales, bots, pagos, publicidad, IA. Tampoco UI de producto (§40).

---

## 9. Riesgos identificados en el análisis

| # | Riesgo | Severidad | Tratamiento en FASE 1 |
|---|---|---|---|
| 1 | AAD no liga conversación/remitente/mensaje | **ALTA** | AAD canónico v1 + tests de §38 |
| 2 | Outbox en memoria: mensajes perdidos al cerrar el app | **ALTA** | Outbox persistente en SQLite |
| 3 | `media_service` es un stub con URL pública | **ALTA** | Arquitectura de objeto cifrado |
| 4 | Notificaciones muestran el texto del mensaje | **MEDIA** | Payload mínimo configurable |
| 5 | Mensajes descifrados en SQLite sin cifrar | **MEDIA** | Documentado; SQLCipher pendiente |
| 6 | Fan-out por dispositivo no escala a grupos | **MEDIA** | Documentado; sender keys en fase de grupos |
| 7 | Modelo legacy con plaintext sigue en el árbol | **BAJA** | Aislado; el motor no lo usa |

---

## 10. Compatibilidad (§42)

No se modifica: Nova ID, Account ID, Device ID, Ed25519, X3DH, Double
Ratchet, Socket.IO, WebSocket, Realtime Server ni el esquema Supabase
existente. Los cambios de servidor son **aditivos** (eventos nuevos), y
las 109 pruebas de FASE 0.5 deben seguir en verde como regresión.

---

## 21. Ported deltas — parallel-engine gaps closed onto this architecture (2026-08-28)

Under option (A) (main canonical), the four genuinely missing capabilities found in the
gap audit were ported from `arena/01a04505-novaapp` @ `e15325c`. Nothing else was moved;
the rejected-gap findings (edit/delete/expiration/reply/reaction coverage) are recorded in
the completion-report addendum.

* **D1 — cold-offline queue.** `MessageSendService` previously discarded user content when
  no Double Ratchet session existed while disconnected (`NO_SESSION` rejection). It now
  persists the PLAINTEXT body in the new `msg_pending_send` table
  (`store/pending_send_store.dart`), keyed by the logical message id (re-queue is a no-op;
  items expire at the message's own `expires_at` — never persisted indefinitely). On
  reconnect the app calls `flushPending()`, which encrypts per target, enqueues to the
  normal Outbox under the ORIGINAL logical id (idempotent at the server), and sends —
  "no duplication, no loss" holds for cold sends too.
* **D2 — partial fan-out visibility.** A per-device encryption failure skipped the device
  silently while the logical message was marked Queued. The service now tracks
  `SendResult.skippedDevices` for every outcome (including queuedOffline flushes) and
  re-queues the whole logical message ONLY when no device could be encrypted at all —
  the sender UI must surface non-empty `skippedDevices`.
* **D3 — ratchet-state persistence fix.** `RatchetState.toJson()` (frozen FASE 0.5
  serializer) does not serialize `myRatchetKeyPair`; persisting with it alone loses the
  private ratchet key across restart. `crypto/ratchet_state_persistence.dart` wraps the
  frozen serializer and adds one key (`my_ratchet_private`, the 32-byte X25519 seed),
  restoring via `newKeyPairFromSeed`. Additive format: legacy payloads still decode
  (without the key — documented, not a regression). The security store keeps whatever
  protection it already applies to `rootKey`; no new surface.
* **D4 client side — tombstones.** `MessageReceiveService.onTombstone` handles
  `message.deleted` / `message.expired` fan-outs by deleting the Inbox envelope; plaintext
  never touches disk, so envelope removal is the full local wipe. `InboxStore.redact`
  backs it. `onAck/onDelivered/onRead/onExpired` moved above the redaction barrier
  (`_isRedacted`).

Server-side counterpart (§19 extended): sender-account-only authorization (non-sender →
generic `forbidden`, no existence leak), logical-id redaction across ALL per-device
copies, event-log payload rewrite on redact (sync replay never resurrects content;
already-acked clients converge via tombstone), `message.expired` fan-out at TTL from the
sender's authoritative row, and a configurable purge sweep (`messagePurgeIntervalMs`,
default 5000 ms) bounding the pre-delivery plaintext window for undelivered messages.
