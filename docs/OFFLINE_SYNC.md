# OFFLINE_SYNC.md — FASE 1

Envío sin conexión, reconexión y recuperación de historial.

Fecha: 2026-08-25

---

## 1. Outbox (§10, §12)

`lib/core/messaging/store/outbox_store.dart` — SQLite, sobrevive al
cierre de la app.

### Estados

```
QUEUED ──emit──> SENDING ──ack──> SENT ──> DELIVERED ──> READ
   ▲                │
   └──backoff───────┴──error permanente──> FAILED
```

### Reglas

| Regla | Decisión | Motivo |
|---|---|---|
| Orden | FIFO por `created_at` dentro de la conversación | Sin esto los mensajes se leen desordenados |
| Reintentos | Backoff exponencial 1s → 60s (tope) | Un bucle cerrado tira la batería y castiga al servidor caído |
| Máximo | 8 intentos → FAILED | Reintentar eternamente esconde el fallo al usuario |
| Caducidad | 7 días → FAILED | Un mensaje de la semana pasada ya no es útil |
| Dedup | `message_id` estable entre reintentos | El servidor deduplica; regenerarlo crearía copias |
| Cancelación | Sólo en QUEUED | Ya emitido, no se puede retirar |
| Errores permanentes | `BLOCKED`, `NO_ACTIVE_RECIPIENT_DEVICE`, `NO_SESSION` → FAILED sin reintento | Reintentar un rechazo determinista no cambia el resultado |

`markAttempt` se escribe **antes** del intento. Si se hiciera después, un
crash durante el envío dejaría el contador intacto y el mensaje
reintentaría en bucle tras cada arranque.

### Recuperación al arrancar

Toda fila en `SENDING` al iniciar la app quedó a medias en un crash: se
devuelve a `QUEUED`. Como `message_id` es estable, si el servidor sí la
recibió responderá `duplicate: true` y no se creará una copia.

---

## 2. Inbox (§13)

`store/inbox_store.dart`.

```
message.new → INSERT (PK message_id, ConflictAlgorithm.ignore)
            → ACK
            → descifrar → markProcessed()
```

El dedup es la **PRIMARY KEY**, no una comprobación en código: es atómica
y no tiene ventana de carrera. Un mensaje entregado en vivo y repetido
por sync se inserta una vez y se procesa una vez.

`pendingProcessing()` recupera lo persistido pero no procesado (crash
entre el ACK y el descifrado).

---

## 3. Sync (§14)

Se reutiliza el protocolo de FASE 0.5 (`sync.request` / `sync.response`
sobre `log_seq`).

```
sync.request { since_log_seq: cursor, limit: 100 }
      ↓
sync.response { events: [...], has_more: true, next_log_seq: N }
      ↓
aplicar CADA evento → avanzar el cursor SÓLO hasta el último aplicado
      ↓
repetir mientras has_more
```

### La regla que más importa

> **El cursor nunca salta a la cabeza.** Avanza sólo hasta el último
> evento realmente aplicado.

Si al recibir `has_more: true` el cliente saltara a `next_log_seq`, todas
las páginas intermedias se perderían **en silencio**: el usuario no ve
mensajes que sí existen y nada lo señala. Es la clase de fallo que se
descubre semanas después.

### Guardas

| Riesgo | Guarda |
|---|---|
| Huecos | `lastContiguousSeq` para en el primer agujero (1,2,3,7 → 3) |
| Duplicados | PK del Inbox |
| Desorden | Se ordena por `server_seq` al presentar, no por llegada |
| Cursor corrupto | El servidor valida la pertenencia; un cursor fuera de rango da `FORBIDDEN` |
| Bucle infinito | `has_more` sin progreso corta; tope de 50 páginas |
| Recibos antiguos | Van por `log_seq`, no por `server_seq`, así que siempre se recuperan |

`emitDelivered: false` durante el replay: reenviar recibos de mensajes ya
confirmados generaría tormentas de eventos redundantes en cada
reconexión.

### Detección de huecos

`server_seq` es **contiguo por conversación**, así que un salto es
detectable con certeza: recibido 1,2,3,7 → faltan 4,5,6 → se piden por
rango en vez de aceptar un historial incompleto.

---

## 4. Reconexión (§43, FASE 0.5)

**Sin reutilización ciega de sesión.** Cada reconexión repite el
handshake completo con un **challenge nuevo**:

```
connect → auth.challenge (nonce fresco) → firma Ed25519 → auth.ok → sync
```

Un token reutilizable capturado una vez valdría para siempre. Además el
servidor recomprueba en cada handshake que el dispositivo **sigue
activo**: un dispositivo revocado no vuelve a entrar (verificado en
`e2e_phase1_multidevice` caso 5).

Detalle aprendido en pruebas: las salas se conceden **en el handshake** a
partir de la membresía del servidor. Un cliente autenticado antes de que
exista la conversación no está en la sala y no recibe nada hasta
reconectar.

---

## 5. Paginación de historial

Hacia atrás, por `server_seq` descendente y por conversación:

```
loadPage(before: seq, limit: 50)
```

Nunca se carga la conversación entera: con 100k mensajes eso agota la
memoria de un Android de gama media (§39).

---

## 6. Escenario completo (§44)

```
1. A escribe sin conexión        → Outbox QUEUED (en disco)
2. A cierra la app               → sigue ahí
3. A abre la app, hay red        → SENDING → ack → SENT
4. B está desconectado           → el servidor lo guarda
5. B conecta                     → re-auth con challenge nuevo
6. B sincroniza desde su cursor  → recibe el mensaje
7. B persiste → ACK → descifra   → message.delivered
8. A ve DELIVERED
9. B abre el chat                → message.read → A ve READ
```

Cubierto por `e2e_ab_flow.test.ts` y `e2e_phase1_multidevice.test.ts`.

---

## 7. Pendiente

- **Redis AUSENTE.** El estado de presencia y las salas viven en la
  memoria del proceso: con varias instancias, dos clientes en procesos
  distintos no se ven. En producción hace falta el adaptador Redis de
  Socket.IO. No está implementado y no se simula.
- Sin compactación del log de eventos: crece indefinidamente.
- Barrido de multimedia caducada: `nova_expire_media_objects()` marca,
  pero el borrado físico en Storage necesita un worker del backend.
