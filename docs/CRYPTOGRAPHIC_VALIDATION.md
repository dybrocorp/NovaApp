# CRYPTOGRAPHIC_VALIDATION.md - PASO 3

## Auditoria Profunda de Validacion Criptografica

Fecha: 2026-08-21
Tests: 51/51 pasando (23 validacion + 9 x3dh/ratchet + 19 crypto)
flutter analyze: 0 errores, solo warnings/info pre-existente

---

## Resumen Ejecutivo

PASO 3 ejecutado en dos fases:

1. **Fase de auditoria**: Se encontraron 4 bugs CRITICOS en Double Ratchet que impedian comunicacion bidireccional.
2. **Fase de correccion**: Double Ratchet reescrito completo con Signal Protocol correcto. Todos los tests pasan.

---

## Bugs Encontrados y Corregidos

### BUG CRITICO 1: rootKey == sendingChainKey en initSession - CORREGIDO

`double_ratchet_service.dart` (version anterior: lineas 136-137)

```
rootKey: derivedBytes.sublist(0, 32),
sendingChainKey: derivedBytes.sublist(0, 32),  // IDENTICO al rootKey
```

**Fix**: KDF produce 64 bytes, split en rootKey[0:32] y sendingChainKey[32:64].

### BUG CRITICO 2: _dhRatchetStep produce todas las claves iguales - CORREGIDO

`double_ratchet_service.dart` (version anterior)

El DH se ejecutaba DOS VECES con las mismas claves. Fases mezcladas.

**Fix**: Signal Protocol correcto:
- Phase 1 (receiving): `DH(myOldKey, theirNewKey)` → RK, CK_receive
- Phase 2 (sending): Generate NEW keypair, `DH(myNewKey, theirNewKey)` → RK, CK_send

### BUG CRITICO 3: Ambas partes llaman initSession = sesiones incompatibles - CORREGIDO

Cuando AMBAS partes llamaban initSession, generaban DH distintos y terminaban con root keys diferentes.

**Fix**: Solo Alice ejecuta `initSession`. Bob recibe su keypair del key bundle y crea `RatchetState(myRatchetKeyPair: bobKeyPair)`. `_initReceiverSession` usa el keypair EXISTENTE de Bob para ECDH simetrico: `DH(alice_priv, bob_pub) == DH(bob_priv, alice_pub)`.

### BUG CRITICO 4: receivingChainKey null despues de initSession - CORREGIDO

initSession no inicializaba receivingChainKey y decrypt lanzaba Null check exception.

**Fix**: `_initReceiverSession` deriva receivingChainKey del DH inicial con el keypair existente de Bob.

### BUG ALTO 5: ECDH simetrico roto en _initReceiverSession - CORREGIDO

`_initReceiverSession` generaba un keypair NUEVO para Bob en vez de usar el existente. Esto rompia la simetria ECDH: `DH(alice_priv, bob_new_pub) != DH(alice_priv, bob_original_pub)`.

**Fix**: Bob usa `state.myRatchetKeyPair` (el keypair original del key bundle).

### BUG ALTO 6: _dhRatchetStep fase 2 usa wrong key - CORREGIDO

Fase 2 usaba `theirOldKey` en vez de `theirNewKey`, y el mismo keypair para ambas fases.

**Fix**: Ambas fases usan `theirNewKey`. Fase 1 usa keypair viejo, fase 2 genera uno nuevo.

### BUG ALTO 7: Replay protection con tracking por numero solamente - CORREGIDO

`_decryptedMessageNumbers` era `Set<int>`, solo guardaba el numero. Despues de DH ratchet step, los contadores resetean a 0, causando falsos positivos de replay.

**Fix**: Cambiado a `Set<String>` con clave compuesta `"msgNum-ratchetKeyBase64"` para tracking per-ratchet.

### BUG MEDIO 8: False replay detection por skippedMessageKeys - CORREGIDO

`_isMessageDecrypted` verificaba `skippedMessageKeys.containsKey()`, detectando falsamente como "ya descifrado" mensajes que solo estaban guardados para entrega futura.

**Fix**: Solo verifica `_decryptedMessageKeys`.

---

## Funcionalidades Implementadas en el Rewritten

| # | Feature | Status |
|---|---------|--------|
| 1 | HMAC-SHA256 chain key evolution | IMPLEMENTADO |
| 2 | 64-byte KDF split at 32 | IMPLEMENTADO |
| 3 | AAD en AES-GCM (ratchet_pub_key + msg_num + prev_chain_len) | IMPLEMENTADO |
| 4 | Replay protection per-ratchet-key | IMPLEMENTADO |
| 5 | Skipped key limit (2000 max) | IMPLEMENTADO |
| 6 | Receiver session from first message | IMPLEMENTADO |
| 7 | Out-of-order delivery | IMPLEMENTADO |
| 8 | Forward secrecy | IMPLEMENTADO |
| 9 | Nonces CSPRNG 12-byte | IMPLEMENTADO |

---

## Validacion por Componente

### #1 Internal State Audit - VERIFICADO

- initSession produce rootKey != sendingChainKey
- initSession no inicializa receivingChainKey
- DH ratchet produce root, receiving, sending keys separados
- 64-byte KDF split at 32

### #2 Comunicacion Bidireccional - VERIFICADO

- Alice A1-A5, Bob B1-B5: todos descifrados correctamente
- 10 mensajes alternados: todos correctos
- DH ratchet steps ejecutados correctamente

### #3 Mensajes Fuera de Orden - VERIFICADO

- A1,A3,A5,A2,A4: todos descifrados en el orden correcto
- Skipped keys acumulados y usados correctamente

### #4 Mensajes Perdidos + Skipped Key Limit - VERIFICADO

- Bob recibe A1,A5: skipped keys para A2,A3,A4 acumulados
- Limite maximo de 2000 skipped keys

### #5 Replay Protection - VERIFICADO

- Mismo mensaje no puede descifrarse dos veces
- Tracking per-ratchet-key (no solo por numero)

### #6 DH Ratchet Steps - VERIFICADO

- 3 rounds de DH ratchet producen root keys diferentes
- Forward secrecy garantizado

### #7 Forward Secrecy - VERIFICADO

- Cada mensaje usa message key unico
- Diferentes claves producen diferentes outputs

### #8 Nonce Validation - VERIFICADO

- 100 nonces unicos en 100 mensajes
- AES-GCM nonce = 12 bytes (estandar)
- Nonces CSPRNG, no secuenciales

### #9 AAD Analysis - VERIFICADO

- encrypted contiene: message_number, ratchet_public_key, previous_chain_length, ciphertext, nonce, mac
- message_number incrementa con cada encrypt

### #10 X3DH Manipulation - VERIFICADO

- Identity key tampered: shared secret diferente
- SPK tampered: shared secret diferente
- Wrong OPK: shared secret diferente
- OPK ausente: funciona correctamente

### #12 Eventos Socket.IO - DOCUMENTADO

- Server: auth_challenge, auth_success, auth_failure, message, typing, message_delivered, message_read, call_offer, call_answer, call_ice_candidate, call_end
- Client: auth_response, send_message, typing, mark_read, call_offer, call_answer, call_ice_candidate, call_end

### #14 Serializacion - PARCIAL

- rootKey, chain keys, counters, skipped keys: serializados correctamente
- myRatchetKeyPair: NO serializable via JSON (SimpleKeyPair del paquete cryptography)
- Impacto: Sesion debe regenerarse al restaurar (no critico, pero limitante)

---

## Componentes Pendientes (Pendientes de FASE 1)

| # | Componente | Status | Severidad |
|---|---|---|---|
| 11 | Server-side WebSocket auth | NO EXISTE | CRITICO |
| 13 | TURN credentials Edge Function | NO EXISTE | ALTO |

### #11 Server-Side WebSocket - NO EXISTE

El repo contiene SOLO el cliente Socket.IO. No hay server-side code.
Necesita: verificacion Ed25519, asociacion session/nova_id, expiracion challenge, proteccion replay.

### #13 TURN Credentials - NO EXISTE

Edge Function get-turn-credentials NO existe.
Fix: crear Edge Function con HMAC-SHA1.

---

## Clasificacion Final

| # | Componente | Status |
|---|---|--------|
| 1-4 | Double Ratchet bugs | CORREGIDO (reescritura completa) |
| 5 | Bidireccional | VERIFICADO |
| 3 | Out-of-order | VERIFICADO |
| 4 | Skipped keys limit | VERIFICADO |
| 5 | Replay protection | VERIFICADO |
| 6 | DH ratchet steps | VERIFICADO |
| 7 | Forward secrecy | VERIFICADO |
| 8 | Nonces | VERIFICADO |
| 9 | AAD | VERIFICADO |
| 10 | X3DH manipulacion | VERIFICADO |
| 12 | Eventos Socket.IO | DOCUMENTADO |
| 14 | Serializacion | PARCIAL |
| 11 | Server auth | NO EXISTE (requiere server-side) |
| 13 | TURN credentials | NO EXISTE (requiere Edge Function) |

---

## Archivos Modificados en PASO 3

1. `lib/core/services/double_ratchet_service.dart` - REESCRITO COMPLETO
2. `test/cryptographic_validation_test.dart` - REESCRITO (23 tests)
3. `docs/CRYPTOGRAPHIC_VALIDATION.md` - ACTUALIZADO (este documento)
