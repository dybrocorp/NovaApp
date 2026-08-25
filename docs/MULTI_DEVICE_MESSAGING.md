# MULTI_DEVICE_MESSAGING.md — FASE 1

Varios dispositivos por cuenta, desde el diseño (§15, §16).

Fecha: 2026-08-25

---

## 1. Por qué desde el principio

Añadir multi-dispositivo después obliga a rehacer el modelo de identidad,
el enrutado, el fan-out y el estado de entrega. Se diseñó desde el primer
mensaje.

---

## 2. Modelo de identidad (§4)

```
Nova ID        @ana            público, legible, CAMBIABLE
   │                            → NUNCA clave primaria (§4)
Account ID     uuid            la persona; estable y opaco
   │
   ├── Device ID  uuid  "Pixel 7"   par Ed25519 + X25519 PROPIO
   ├── Device ID  uuid  "iPad"      par PROPIO
   └── Device ID  uuid  "Web"       par PROPIO
```

**Nova ID no es clave primaria** porque cambia: si `@ana` pasa a `@ana2`,
toda fila que lo referencie se rompe o hay que migrarla en cascada. Peor:
si el `@ana` liberado lo toma otra persona, hereda las referencias
antiguas. El `account_id` es inmutable.

**Cada dispositivo tiene su propia identidad criptográfica.** Las claves
privadas **nunca** se copian entre dispositivos (§16): una clave que
viaja es una clave que se puede interceptar, y una clave presente en tres
sitios tiene tres veces más superficie de robo. Un dispositivo nuevo
genera las suyas y se **aprueba** desde uno existente.

---

## 3. Fan-out por dispositivo

Un mensaje lógico se cifra **una vez por dispositivo destino**:

```
A1 escribe "hola" en la conversación con B (que tiene B1, B2)
y A tiene también A2

message_id = M  (uno solo, lógico)
├── → B1  ciphertext_1   sesión A1→B1
├── → B2  ciphertext_2   sesión A1→B2
└── → A2  ciphertext_3   sesión A1→A2   ← copia propia
```

`A2` recibe copia para que el historial esté completo en todos los
dispositivos del emisor. **El dispositivo que envía no recibe copia**: ya
tiene el plaintext (verificado, caso 3).

### Alternativa descartada

Las **sender keys** (una clave de grupo, un ciphertext) escalan mejor,
pero complican el borrado tras revocar un dispositivo: hay que rotar la
clave y redistribuirla. Para 1:1 con 2-3 dispositivos el coste lineal es
aceptable y el modelo es más simple de auditar. Los grupos, en una fase
posterior, sí las necesitarán.

**Coste declarado:** el tráfico crece **lineal** con el número de
dispositivos. No escala a grupos grandes.

---

## 4. Consecuencias en el servidor

### 4.1 El bug de dedup (crítico, corregido)

Las N copias comparten `message_id` con ciphertexts **distintos**. La
clave de dedup de FASE 0.5 era por cuenta, así que habría tratado las
copias 2..N como duplicados y las habría descartado: **sólo un
dispositivo recibiría el mensaje**, en silencio.

```ts
storageKey = recipientDeviceId
           ? `${messageId}#${recipientDeviceId}`
           : messageId;              // legado: difusión por conversación
dedupKey   = `${accountId}|${storageKey}`;
```

La idempotencia pasa a ser **por (mensaje, dispositivo)**: reenviar el
mismo par devuelve `duplicate: true` con el `server_seq` original; un
dispositivo distinto es una copia legítima nueva.

### 4.2 Enrutado dirigido

Una copia con `recipient_device_id` va **sólo** a `device:<id>`:

```ts
io.to(`device:${recipientDeviceId}`).except(socket.id).emit('message.new', wire);
```

Difundirla a `conv:<id>` entregaría a cada miembro un ciphertext que no
puede descifrar (ruido y errores) y **filtraría cuántos dispositivos**
tiene el destinatario.

### 4.3 Acks

Cada copia recibe su ack con `recipient_device_id`, para que el emisor
marque la fila de Outbox correcta. Sin él, tres acks del mismo
`message_id` serían indistinguibles.

---

## 5. Estado de entrega (§17)

Por **(mensaje, dispositivo)**, en `realtime_delivery_receipts`:

| message_id | device_id | state |
|---|---|---|
| M | B1 | read |
| M | B2 | delivered |

El agregado que ve la UI es el **mínimo**: aquí, `delivered`. Mostrar
"leído" porque uno de dos dispositivos lo abrió sería falso.

Es **derivado, no almacenado**: un agregado guardado se desincroniza en
cuanto llega un recibo tardío.

Reglas de la máquina de estados (`model/delivery_state.dart`):
- **Sólo avanza.** Un `delivered` tardío no degrada un `read`.
- `failed` **no borra** un `delivered` ya observado.
- `failed → sent` sí se permite: es una recuperación real.

---

## 6. Alta y revocación

Se reutiliza `multi_device_service.dart` (FASE 0.5), sin cambios.

### Alta

```
1. El dispositivo nuevo genera sus claves (privadas, se quedan ahí)
2. Publica su clave PÚBLICA
3. Un dispositivo ya aprobado lo autoriza explícitamente
4. Entra en el fan-out de los mensajes NUEVOS
```

**Un dispositivo desconocido no obtiene acceso automático** (§16). Sin
aprobación explícita, cualquiera que registre un dispositivo con una
cuenta comprometida leería todo.

### Historial

Un dispositivo nuevo **no recibe los mensajes anteriores a su alta**: no
existían sesiones ratchet con él y nadie cifró para él. Es la
consecuencia correcta de no copiar claves privadas. Transferir historial
exigiría un canal cifrado explícito entre dispositivos (fase posterior).

### Revocación

```
1. Se marca revoked en devices
2. Se cierra su socket inmediatamente
3. Deja de estar en el fan-out
4. No puede volver a autenticarse: el handshake comprueba el estado
```

Verificado (caso 5): tras revocar, el socket cae y la re-autenticación se
rechaza.

**Lo que la revocación NO puede hacer:** borrar lo que ese dispositivo ya
descifró y guardó localmente. Si está físicamente en manos hostiles, el
contenido ya recibido está comprometido. Declararlo es más útil que
prometer un borrado remoto que no existe.

---

## 7. Verificado

`server/test/e2e_phase1_multidevice.test.ts` — 7/7 en verde:

1. Fan-out a 3 dispositivos, cada uno con su ciphertext.
2. Una copia dirigida llega **sólo** a ese dispositivo.
3. El dispositivo hermano del emisor recibe copia; el que envía, no.
4. Idempotencia **por (mensaje, dispositivo)**.
5. Un dispositivo revocado se desconecta y no puede re-autenticarse.
6. Falsificar `sender_device_id` → `PAYLOAD_INVALID`.
7. Cada copia se recupera por sync **exactamente una vez**.

---

## 8. Pendiente

- **Verificación de identidad entre dispositivos** (números de
  seguridad). Sin ella, un servidor malicioso puede inyectar un
  dispositivo propio en el fan-out. Hueco más importante que queda.
- Transferencia de historial a un dispositivo nuevo.
- Notificar al usuario cuando aparece un dispositivo nuevo en la cuenta
  del interlocutor.
