# MESSAGE_PROTOCOL.md — FASE 1

Contrato de cable del motor de mensajería de NovaApp.

Fecha: 2026-08-25 · Versión del envelope: **v1**

---

## 1. Capas

```
MessageBody      contenido        CIFRADO   (sólo el destinatario)
MessageEnvelope  enrutado         EN CLARO  (ligado por AAD)
Socket.IO        transporte       WSS
```

Regla: si el servidor lo necesita para entregar, va en el envelope y
queda **ligado a la AAD**. Si no lo necesita, va **dentro del ciphertext**.

---

## 2. Envelope v1

`message.send` (cliente → servidor):

```jsonc
{
  "message_id":          "uuid-v4",   // idempotencia; estable en reintentos
  "conversation_id":     "uuid",
  "sender_device_id":    "uuid",      // el servidor lo verifica y re-sella
  "recipient_device_id": "uuid",      // fan-out por dispositivo (§15)
  "message_type":        "text",
  "envelope_version":    1,
  "ciphertext":          "base64",    // AEAD opaco
  "header_type":         "dr.v1",
  "client_ts_ms":        1767225600000, // pista de UI; NUNCA ordena
  "expires_at_ms":       1767229200000  // opcional (§22)
}
```

Prohibido: `text`, `plaintext`, `content`, `body`, `message`, `decrypted`.
El servidor responde `PAYLOAD_INVALID` si aparecen (verificado en
`e2e_phase1_security` caso 11).

`message.ack` (servidor → emisor):

```jsonc
{
  "message_id": "uuid-v4",
  "conversation_id": "uuid",
  "recipient_device_id": "uuid",  // para casar con la fila de Outbox
  "server_seq": 42,               // orden de MENSAJES
  "log_seq": 87,                  // cursor de SYNC
  "duplicate": true               // sólo en reintentos
}
```

`message.new` (servidor → destinatario): el envelope más
`sender_account_id`, `server_seq`, `log_seq` y `received_at_ms`, todos
**sellados por el servidor** (un cliente no puede falsificarlos).

---

## 3. Las dos secuencias

| Campo | Qué ordena | Uso |
|---|---|---|
| `server_seq` | Mensajes de una conversación | Orden y detección de huecos |
| `log_seq` | Eventos del log | Cursor de sync |

Son **distintas a propósito**. Un recibo sobre un mensaje antiguo recibe
un `log_seq` NUEVO, así que un cliente ya adelantado lo sigue recibiendo
al sincronizar. Confundirlas fue un fallo real de FASE 0.5: los recibos
quedaban irrecuperables tras reconectar.

Los timestamps de cliente **nunca** ordenan (verificado en
`e2e_ab_flow` caso 8, con timestamps decrecientes a propósito).

---

## 4. AAD canónica (§9)

```
NOVA_MSG_AAD_v1 \0 conversation_id \0 sender_account_id \0 sender_device_id
                \0 recipient_device_id \0 message_id \0 message_type
                \0 envelope_version
```

Separador **NUL**: los ids son UUIDs y no pueden contenerlo, y el
constructor rechaza cualquier campo que lo lleve, de modo que la
codificación es **inyectiva** (no se puede desplazar el límite entre dos
campos para producir los mismos bytes).

### Qué impide

| Ataque | Resultado |
|---|---|
| Reenrutar un sobre a otra conversación | Fallo de autenticación |
| Reatribuirlo a otro remitente | Fallo de autenticación |
| Reproducir la copia de un dispositivo en otro | Fallo de autenticación |
| Convertir un `text` en un `deletion` | Fallo de autenticación |
| Degradar `envelope_version` | Fallo de autenticación |

Verificado en `test/messaging/message_aad_test.dart`.

### Cómo se aplica

El `DoubleRatchetService` auditado construye su AAD internamente y no
expone un punto de extensión. En lugar de modificar un componente estable
(§42), el motor calcula un **context tag**:

```
ctx = HMAC-SHA256(  AAD,
                    key = HMAC-SHA256("NOVA_MSG_CTX_v1|nonce", key = mac_AEAD) )
```

Se envía junto al ciphertext y se recomprueba en tiempo constante al
recibir. Sin la clave del ratchet no se puede forjar, así que un servidor
que reescriba el enrutado es detectado.

`MessageAad.build()` **falla cerrado** ante un campo vacío o con NUL: una
AAD malformada en silencio anularía la protección que existe para dar.

---

## 5. Fan-out por dispositivo (§15)

Un mensaje lógico → N sobres, uno por dispositivo activo:

```
message_id M
├── recipient_device_id B1  ciphertext_1   (sesión ratchet A1→B1)
├── recipient_device_id B2  ciphertext_2   (sesión ratchet A1→B2)
└── recipient_device_id A2  ciphertext_3   (otro dispositivo propio)
```

Consecuencias en el servidor:

- **Clave de dedup** = `account_id | message_id # recipient_device_id`.
  Sin el dispositivo, sólo el primer destino recibiría el mensaje y el
  resto se descartaría como "duplicado" (bug corregido y cubierto por
  `e2e_phase1_multidevice` caso 1).
- **Enrutado**: una copia dirigida va SÓLO a `device:<id>`. Difundirla a
  la conversación entregaría a cada miembro un ciphertext que no puede
  abrir y filtraría el patrón de dispositivos.
- **Un ack por dispositivo**, con `recipient_device_id` para casarlo.

Coste honesto: el tráfico crece **lineal** con el número de dispositivos.
Aceptable en 1:1 con 2-3 dispositivos; **no escala a grupos grandes**,
que necesitarán sender keys en una fase posterior.

---

## 6. Estados (§17)

```
A --message.send--> SERVER --message.ack--> A     SENT      (servidor lo guardó)
                    SERVER --message.new--> B
B --message.delivered--> SERVER ----------> A     DELIVERED (dispositivo lo recibió)
B --message.read-------> SERVER ----------> A     READ      (usuario lo leyó)
```

Tres estados distintos, nunca un booleano. Cada uno **por dispositivo**;
el agregado que ve la UI es el **mínimo** entre dispositivos activos: si
uno de tres leyó, el mensaje no está "leído".

`last_read_seq` se **acota** en el servidor al `server_seq` real, así que
un cliente no puede marcar el futuro como leído.

---

## 7. Mutaciones (§18, §19, §21)

Nunca se modifica el mensaje original: se emiten eventos nuevos y el
cliente reconstruye el estado.

| Evento | Body | Autorización |
|---|---|---|
| `edit` | `edit_target`, `text` | Sólo el autor original |
| `deletion` | `deletion_target` | Sólo el autor original |
| `reaction` | `reaction_target`, `reaction_emoji` | Cualquier participante |

El objetivo va **dentro del ciphertext**: quién responde a quién, y quién
reacciona a qué, es contenido, no metadata de enrutado.

Validación local obligatoria (§20): el cliente comprueba que el mensaje
citado/editado pertenece a la MISMA conversación antes de aplicarlo
(`MessageReceiveService.isValidReplyTarget` / `isValidMutation`).

### Semántica de borrado (§19)

- **delete for me** — local. El servidor no se entera.
- **delete for everyone** — evento `deletion`; los clientes ocultan el
  original y el servidor puede aplicar retención.

**No garantiza** eliminar copias exportadas, capturadas o ya descargadas.
Está declarado así a propósito: prometer lo contrario sería mentir.

---

## 8. Compatibilidad

Cliente antiguo ↔ servidor nuevo: los campos de FASE 1 son **opcionales**.
Sin `recipient_device_id` el servidor usa la difusión de FASE 0.5 (las 109
pruebas siguen en verde).

Cliente nuevo ↔ mensaje de tipo desconocido: degrada a `system` y la UI
muestra "mensaje no soportado". Nunca lanza.

Los campos desconocidos del body se **conservan** al reserializar, para
no destruir datos de un cliente más nuevo.
