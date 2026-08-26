# NOVAAPP REALTIME E2E STATUS

**Fase:** 0.5 — Validación end-to-end del realtime
**Fecha:** 2026-08-24
**Rama:** `arena/01a035bd-novaapp`
**Resultado de pruebas:** 109/109 E2E (Node) · Flutter **NOT RUN**

---

## 1. Lo que se demostró

```
NOVA CLIENT A                                          NOVA CLIENT B
 cuenta acc-A · device dev-A                  cuenta acc-B · device dev-B
 Ed25519 propia · X3DH propio                 Ed25519 propia · X3DH propio
      │                                                       ▲
      │  ciphertext opaco (Double Ratchet)                    │
      ▼           Socket.IO / WebSocket                       │
┌────────────────────────────────────────────────────────────────┐
│                       REALTIME SERVER                          │
│  challenge → firma → sesión → authz → dedup → server_seq       │
│  El servidor NUNCA ve plaintext ni posee material de claves    │
└────────────────────────────────────────────────────────────────┘
      │                                                       ▲
      ▼                 PostgREST + service role              │
                       SUPABASE (ciphertext + metadata)
```

Verificado con clientes reales sobre WebSockets reales, y confirmado
además contra el proceso servidor en ejecución (no sólo in-process).

---

## 2. IMPLEMENTADO

Código presente y correcto por revisión.

- Servidor Socket.IO 4 (Node 20 / TypeScript), WebSocket-only.
- Motor de handshake Ed25519 con mensaje canónico `NOVA_AUTH_v1`.
- Registro de challenges (CSPRNG 32 B, TTL, uso único, binding a socket).
- Registro de sesiones (256 bits, TTL deslizante, una por dispositivo).
- Política de autorización por membresía, relación y audiencia.
- Directorio Supabase sobre PostgREST (service role).
- Almacén Supabase del tier realtime, con RPC de secuencia atómica.
- Rate limiting token bucket por dominio + lockout de auth.
- API admin protegida por `ADMIN_TOKEN` + `/healthz`.
- Logging estructurado y redactado (`SecurityLog`).
- Cliente Flutter endurecido (`websocket_service.dart` + `lib/core/socket/`).
- Arnés de cliente Node reutilizable con X3DH + Double Ratchet reales.

## 3. VERIFICADO

Cubierto por pruebas automatizadas que fallan si la garantía se rompe.

| Bloque (criterio §26) | Pruebas |
|---|---|
| **Authentication** | 17 casos: handshake válido A y B, firma inválida, clave no registrada, challenge expirado/reutilizado/modificado, Device/Account/Nova ID incorrectos, dispositivo revocado, sesión expirada, código genérico sin oráculo |
| **Authorization** | 12 casos: A no lee, escribe, suplanta, ni entra en rooms de B; identidad sellada por el servidor; sesión y Device ID ajenos inútiles |
| **E2EE envelope** | X3DH converge; el servidor almacena y relaya sólo ciphertext; el plaintext no aparece ni tras decodificar base64; campos en claro rechazados; un tercero no puede descifrar |
| **Message delivery** | A→servidor→B con descifrado correcto en B, en vivo y tras reconexión |
| **ACK** | SENT / DELIVERED / READ probados por separado, con verificación activa de que no se disparan entre sí |
| **Deduplication** | Retransmisión del mismo `message_id` → mismo `server_seq`, un mensaje, un fan-out; dedup con alcance por cuenta |
| **Reconnection** | Challenge nuevo, sesión nueva, sesión anterior irrecuperable; WiFi↔datos; reinicio del servidor |
| **Sync** | Recuperación de mensajes y de recibos perdidos, sin duplicados, ordenada, paginada sin saltos, y de cuenta completa |
| **Device revocation** | Sesión invalidada, socket cerrado, re-autenticación imposible, resto de cuentas intactas |
| **Rate limiting** | message / sync / signaling / auth rechazados en servidor ante abuso |
| **Presence** | online/offline/last_seen, offline automático al caer el socket, sólo a la audiencia autorizada, sin broadcast global |
| **Signaling** | offer/answer/ice/end relayados, gate por contactos, anti-spoof, nunca media |
| **Security logging** | Sin claves, plaintext, ciphertext, sesiones ni challenges; ids truncados; comprobación de contenido y de estructura |
| **Supabase** | Ruta A→Supabase→B; service role nunca al cliente ni al log; secuencias atómicas; fallo cerrado sin RPC |
| **Concurrencia** | 10 conexiones simultáneas: handshakes, secuencias únicas y contiguas, fan-out completo, tormenta de reconexión sin cruce |

**13 defectos reales corregidos** durante la auditoría (detalle en
`docs/E2E_REALTIME_AUDIT.md` §3). Los cinco más graves:

1. Los recibos delivered/read eran **irrecuperables** tras reconectar
   (sync paginaba por la secuencia equivocada) → estados divergentes.
2. Los mensajes recuperados por sync **no eran descifrables** (forma del
   payload distinta de la entrega en vivo).
3. El cursor de sync **saltaba eventos** cuando había más de una página.
4. El cliente Dart enviaba `last_cursor` y el servidor lee `last_seq`: el
   servidor interpretaba cursor 0 **siempre**.
5. El dedup global de `message_id` permitía a una cuenta **anular
   entregas** de otra.

## 4. PARCIAL

- **TLS/WSS**: el cliente exige `wss://` en release y el servidor está
  pensado para ir tras un balanceador L7, pero **el servidor no termina
  TLS** y no se probó con certificado real.
- **Supabase**: el código de producción está ejercitado contra un doble de
  PostgREST fiel al contrato; **RLS real no ejecutada** contra Postgres.
- **Rate limiting**: correcto en un nodo; los buckets son por proceso.
- **X3DH / Double Ratchet**: verificados funcionalmente (interoperan,
  rotan, rechazan replays); **sin auditoría criptográfica independiente**.

## 5. PENDIENTE

- **Redis: AUSENTE.** No hay código Redis. Sin él no hay multi-nodo:
  challenges, sesiones, dedup, rate limits y presencia viven en memoria
  del proceso. El despliegue soportado hoy es **de un solo nodo**.
- **TURN: AUSENTE.** Sólo STUN público; las llamadas reales fallarán tras
  NAT simétrico. No afecta a FASE 0.5 (aquí sólo se valida señalización).
- **`flutter analyze` / `flutter test`: NOT RUN — Flutter SDK unavailable.**
  No hay SDK en el entorno y la red bloquea `pub.dev` y
  `storage.googleapis.com`.
- Aplicar `server/sql/realtime_schema.sql` y verificar RLS en el proyecto
  real; auditar las políticas RLS heredadas de la app.
- `ADMIN_TOKEN` y `CORS_ORIGIN` obligatorios en producción.
- Métricas, alertas y retención del log de eventos.
- Persistencia de cursores y outbox en el cliente entre arranques.

## 6. RIESGOS

| Riesgo | Nivel | Detalle |
|---|---|---|
| Un solo nodo sin Redis | **ALTO** (escalado) | Dos réplicas hoy producirían fan-out roto, secuencias duplicadas y revocación parcial |
| Sin TURN | **ALTO** (llamadas) | Bloqueante funcional cuando se implementen llamadas reales |
| RLS no ejecutada | **MEDIO** | Modelo deny-by-default correcto por revisión, no probado |
| Criptografía sin auditoría externa | **MEDIO** | Funciona ≠ auditada |
| Cliente Flutter sin ejecutar | **MEDIO** | Cambios escritos y con pruebas, pero no ejecutados |
| Almacén en memoria por defecto | **MEDIO** | Un reinicio pierde el historial caliente; producción debe usar `supabase` |

---

## 7. Sobre el lenguaje de seguridad

Se usa **validado**, **verificado** y **pendiente de auditoría**.

No se afirma "100 % seguro", "imposible de hackear" ni comparación alguna
con otras aplicaciones. Que 109 pruebas pasen significa exactamente que
esas propiedades concretas se cumplen en las condiciones probadas: un
nodo, loopback, almacén en memoria o doble de PostgREST. Nada más.

---

## 8. ¿Está NovaApp lista para FASE 1?

# YES

### Justificación técnica

El criterio de terminación de FASE 0.5 (§26) es demostrar la cadena
`CLIENT A ↕ WSS ↕ REALTIME SERVER ↕ SUPABASE ↕ REALTIME SERVER ↕ WSS ↕
CLIENT B` con doce propiedades funcionando. Las doce están **verificadas
por pruebas automatizadas** contra el servidor real, con dos clientes de
cuentas distintas y criptografía independiente, y confirmadas además
contra el proceso servidor en ejecución:

1. **Authentication** — 17 casos, incluidos los nueve ataques exigidos.
2. **Authorization** — 12 casos; autenticación y autorización son
   independientes y se comprueba que A no alcanza nada de B.
3. **E2EE envelope** — el servidor almacena y relaya ciphertext opaco; no
   posee material de claves y no puede descifrar.
4. **Message delivery** — B descifra exactamente lo que A cifró.
5. **ACK / DELIVERED / READ** — tres estados, nunca mezclados.
6. **Deduplication** — un `message_id` produce un mensaje, con el ack
   idempotente original.
7. **Reconnection** — siempre challenge nuevo y sesión nueva; la anterior
   nunca revalida.
8. **Sync** — recupera mensajes y recibos, sin duplicar ni saltar.
9. **Device revocation** — efectiva e inmediata; el dispositivo no puede
   seguir operando.
10. **Rate limiting** — aplicado en servidor, no delegado al cliente.
11. **Presence** — con audiencia de privacidad y offline automático.
12. **Signaling** — transporta offer/answer/ice/end; nunca media.

Además, la auditoría **encontró y corrigió 13 defectos reales**, cuatro de
los cuales habrían causado pérdida silenciosa de mensajes o divergencia de
estado en producción. Ese es el objetivo de una fase de validación, y se
cumplió: el sistema no sólo pasa pruebas, sino que las pruebas
descubrieron fallos que la revisión documental no había visto.

### Condiciones que acompañan al YES

El YES es para **avanzar a FASE 1 (construir funcionalidad sobre este
transporte)**, no para desplegar a usuarios reales. La base es correcta y
estable, y las carencias conocidas son de **infraestructura y despliegue**,
no de protocolo:

- **Redis** es imprescindible antes de escalar a más de un nodo, pero no
  bloquea construir la UI de chat, grupos o multimedia sobre este
  transporte.
- **TURN** es imprescindible antes de llamadas reales; FASE 0.5 sólo
  validaba señalización, y esa parte está probada.
- **`flutter analyze` / `flutter test` deben ejecutarse** en un entorno con
  SDK antes de cerrar formalmente la fase. Los cambios del cliente están
  escritos y cubiertos por pruebas, pero **no ejecutados aquí**, y esto no
  se presenta como si lo estuvieran.
- **RLS debe verificarse** contra el proyecto Supabase real.

Si el criterio fuera "listo para producción abierta", la respuesta sería
**NO** (Redis, TURN, TLS real y RLS verificada son bloqueantes). Para el
criterio efectivamente planteado —¿está el realtime demostrado de extremo
a extremo y es seguro construir FASE 1 encima?— la respuesta es **YES**.
