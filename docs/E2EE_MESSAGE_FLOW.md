# E2EE_MESSAGE_FLOW.md — FASE 1

Recorrido completo de un mensaje, de la tecla al descifrado.

Fecha: 2026-08-25

---

## 1. Invariante

> El servidor procesa **ciphertext, ids, secuencias, timestamps y estados
> de entrega**. Nunca contenido.

Consecuencia operativa: un volcado completo de la base de datos revela
**quién habló con quién y cuándo**, nunca **qué se dijo**. Ese metadata
residual es real y está declarado; ocultarlo requeriría enrutado
anónimo, fuera del alcance de esta fase.

---

## 2. Camino de ida

```
 usuario escribe
      │
 [1] MessageBody (plaintext, sólo en RAM)
      │
 [2] ConversationService.resolveRecipients()   ← §29 bloqueo, dispositivos activos
      │
 [3] por CADA dispositivo destino:
      │      MessageAad.build(...)             ← §9 liga el enrutado
      │      DoubleRatchetService.encrypt()    ← §7 AES-256-GCM + X25519
      │      context tag HMAC-SHA256           ← liga la AAD al AEAD
      │
 [4] OutboxStore.enqueue()   ★ PUNTO DE DURABILIDAD (§10)
      │
 [5] MessageTransport.send()  Socket.IO/WSS
      │
 [6] SERVIDOR: autoriza · secuencia · persiste · fan-out
      │
 [7] message.ack → Outbox: SENT
```

**Por qué [4] va antes que [5].** Si el proceso muere entre el emit y el
ack, un Outbox en memoria pierde el mensaje sin avisar: el usuario lo ve
enviado y nunca llegó. En disco, el arranque lo recupera y reintenta. El
Outbox de FASE 0.5 (`lib/core/socket/messaging/outbox.dart`) era en
memoria; por eso este motor trae `store/outbox_store.dart`.

**Por qué la AAD se construye por dispositivo.** Incluye
`recipient_device_id`, así que la copia de B1 no se puede reproducir
contra B2. Sin eso, un servidor comprometido podría reproducir la copia
de un dispositivo en otro y ambos la aceptarían.

---

## 3. Camino de vuelta

```
 message.new
      │
 [1] InboxStore.persist()   ★ PUNTO DE DURABILIDAD (§13)
      │                       PRIMARY KEY(message_id) + IGNORE → dedup
 [2] ACK al servidor         ← sólo DESPUÉS de escribir en disco
      │
 [3] recomprobar el context tag  (comparación en tiempo constante)
      │
 [4] DoubleRatchetService.decrypt()
      │
 [5] MessageBody.decode()
      │
 [6] markProcessed() · message.delivered → el emisor ve DELIVERED
      │
 [7] cuando el usuario lo abre: message.read → READ
```

**Persistir antes del ACK** es lo que hace la entrega *at-least-once*
segura. Si se hiciera al revés, un fallo tras el ACK perdería el mensaje
para siempre: el servidor cree que llegó y no lo reenvía.

At-least-once + PRIMARY KEY = **exactly-once en efectos**. Verificado en
`e2e_phase1_multidevice` caso 7: un mensaje entregado en vivo y luego
repetido por sync se procesa **una sola vez**.

**Un fallo de descifrado no borra nada** (`decrypt_failed=1,
processed=1`): el sobre queda para diagnóstico y no bloquea la cola. Un
mensaje corrupto no debe congelar la conversación.

**Sin oráculo**: todo error de descifrado produce el mismo
`MessageDecryptionError` genérico. Distinguir "MAC inválido" de "sesión
desconocida" da al atacante una señal explotable.

---

## 4. Establecimiento de sesión (§7)

Se reutiliza sin modificar lo que ya estaba auditado:

```
X3DH (x3dh_service.dart)                → secreto compartido inicial
  IK_A · EK_A · SPK_B · OPK_B (X25519)
        │
Double Ratchet (double_ratchet_service.dart)
  HKDF-SHA256 → cadenas de envío/recepción
  X25519 DH ratchet en cada cambio de turno
        │
  AES-256-GCM + HMAC-SHA256 por mensaje
```

Propiedades heredadas: **forward secrecy** (comprometer la clave de hoy
no abre los mensajes de ayer) y **post-compromise security** (el
siguiente paso DH recupera la seguridad).

Una sesión por **par de dispositivos**, no por cuenta. Tres dispositivos
en B = tres sesiones independientes. Las claves privadas **nunca** se
copian entre dispositivos (§16).

`encryption_service.dart` (DH estático, sin ratchet ni forward secrecy)
es legado y el motor **no lo usa**.

---

## 5. Multimedia (§23–§26)

```
archivo → cifrar LOCAL (AES-256-GCM, clave por objeto)
        → subir SOLO ciphertext a Storage
        → el mensaje lleva {object_id, key, nonce, sha256}  ← dentro del ciphertext
        → el receptor descarga, VERIFICA el digest, y descifra
```

Nunca por Socket.IO: un archivo de 50 MB en base64 bloquea el canal de
control y castiga a los mensajes de texto.

La clave del objeto es **independiente** de la del ratchet: reenviar un
archivo no obliga a compartir la sesión, y su compromiso no afecta a la
conversación.

El **digest se verifica antes de descifrar**, y se calcula sobre el
**ciphertext**. Sobre el plaintext obligaría a descifrar datos no
verificados. La miniatura comparte clave pero usa un **nonce distinto**:
reutilizar (clave, nonce) en GCM es catastrófico y filtra el XOR de
ambos textos.

URLs firmadas y caducas, nunca públicas permanentes (§26).

---

## 6. Qué ve cada actor

| Actor | Ve | No ve |
|---|---|---|
| Servidor NovaApp | ciphertext, ids, secuencias, tamaños, tiempos | contenido, claves |
| Supabase Storage | blobs cifrados, tamaños | contenido, claves, nombres reales |
| FCM/APNs | "Nuevo mensaje en NovaApp" | remitente real, contenido |
| Red / operador | tráfico TLS a NovaApp | todo lo anterior |
| Destinatario | todo | nada del resto de conversaciones |

---

## 7. Límites conocidos

- **Sin verificación de identidad todavía.** Sin comparar números de
  seguridad, un servidor malicioso puede inyectar un dispositivo suyo en
  el fan-out (MITM clásico). Es el hueco más importante que queda.
  Mitigación parcial: `multi_device_service` exige aprobación explícita.
- **Metadata visible** (§1).
- **Confianza en el dispositivo**: comprometido el terminal, el E2EE es
  irrelevante. La base local **todavía no está cifrada en reposo**
  (SQLCipher **PENDIENTE**, no simulado).
- **Criptografía pendiente de auditoría independiente.** Se han validado
  el diseño y las pruebas; no sustituye a una auditoría externa.
