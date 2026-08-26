# E2E_REALTIME_TESTING.md — FASE 0.5

Cómo se prueba el realtime de NovaApp, qué cubre cada caso y qué se
ejecutó realmente.

Fecha: 2026-08-24

---

## 1. Topología bajo prueba

```
NOVA CLIENT A                                            NOVA CLIENT B
  (Ed25519 + X3DH + Double Ratchet)                (identidad SEPARADA)
      │                                                        ▲
      │ Socket.IO / WebSocket                                  │
      ▼                                                        │
┌──────────────────────────────────────────────────────────────────┐
│                     REALTIME SERVER (Node 20 / TS)               │
│  handshake · sesiones · authz · dedup · server_seq · rate limit  │
└──────────────────────────────────────────────────────────────────┘
      │                                                        ▲
      ▼                                                        │
              SUPABASE (PostgREST, service role)
```

A y B son **dos cuentas distintas** con material criptográfico
independiente: claves Ed25519 de handshake propias, bundles X3DH propios y
sesiones de ratchet propias. Nada se comparte entre ellas.

---

## 2. Ejecutar

```bash
cd server
npm install
npm test          # suite completa
```

Una suite concreta:

```bash
node --import tsx --test test/e2e_ab_flow.test.ts
```

Servidor real para pruebas manuales:

```bash
cd server && npm run dev      # PORT=4000, GET /healthz
```

---

## 3. Resultado de la última ejecución

```
# tests 109
# pass  109
# fail  0
# duration_ms ~12900
```

Node v22.22.3 · sin red externa · WebSockets reales sobre loopback.

| Suite | Casos | Cubre |
|---|---:|---|
| `e2e_handshake.test.ts` | 10 | Challenge/respuesta, códigos genéricos, lockout |
| `e2e_auth_matrix.test.ts` | 17 | Matriz completa de autenticación (§4) |
| `e2e_ab_flow.test.ts` | 10 | A→E2EE→servidor→B, idempotencia, ACK/DELIVERED/READ, orden |
| `e2e_sessions_devices.test.ts` | 6 | Ciclo de vida de sesión y dispositivo |
| `e2e_authorization.test.ts` | 12 | Aislamiento A/B, rooms, spoofing, revocación |
| `e2e_messaging.test.ts` | 10 | Envelope, fan-out, validación de payload |
| `e2e_sync.test.ts` | 4 | Replay por cursor |
| `e2e_reconnect_sync.test.ts` | 10 | Reconexión, cambio de red, sync, reinicio |
| `e2e_presence_signaling_logs.test.ts` | 14 | Presencia, señalización, logs, rate limit, concurrencia |
| `e2e_rate_limits.test.ts` | 4 | Límites por dominio |
| `e2e_supabase_store.test.ts` | 6 | Ruta A→Supabase→B, service role, RPC atómico |
| **Total** | **109** | |

---

## 4. Cobertura frente a la lista obligatoria (§21)

| # | Prueba pedida | Dónde | Estado |
|---:|---|---|---|
| 1 | valid authentication | `e2e_auth_matrix` 1-2 | ✅ |
| 2 | invalid authentication | `e2e_auth_matrix` 4-5, 10-13 | ✅ |
| 3 | replay attack | `e2e_auth_matrix` 7-8 | ✅ |
| 4 | expired challenge | `e2e_auth_matrix` 6 | ✅ |
| 5 | revoked device | `e2e_auth_matrix` 14 | ✅ |
| 6 | expired session | `e2e_auth_matrix` 15 | ✅ |
| 7 | E2EE message | `e2e_ab_flow` 2-3 | ✅ |
| 8 | duplicate message | `e2e_ab_flow` 5 | ✅ |
| 9 | ACK | `e2e_ab_flow` 6 | ✅ |
| 10 | DELIVERED | `e2e_ab_flow` 6 | ✅ |
| 11 | READ | `e2e_ab_flow` 6-7 | ✅ |
| 12 | reconnect | `e2e_reconnect_sync` 1-3 | ✅ |
| 13 | network switch | `e2e_reconnect_sync` 6-7 | ✅ |
| 14 | authorization | `e2e_authorization` 1-12 | ✅ |
| 15 | rate limit | `e2e_presence_signaling_logs` 10-12 | ✅ |
| 16 | sync | `e2e_reconnect_sync` 3-5, 8-9 | ✅ |
| 17 | presence | `e2e_presence_signaling_logs` 1-4 | ✅ |
| 18 | signaling | `e2e_presence_signaling_logs` 5-8 | ✅ |
| 19 | server restart | `e2e_reconnect_sync` 10 | ✅ |
| 20 | concurrent connections | `e2e_presence_signaling_logs` 13-14 | ✅ |

---

## 5. Detalle de las pruebas críticas

### 5.1 El servidor nunca ve plaintext (§5)

`e2e_ab_flow` caso 3 envía una cadena marcada
(`CLAVE-SECRETA-QUE-EL-SERVIDOR-NUNCA-DEBE-VER`) cifrada con el ratchet y
comprueba tres cosas distintas:

1. la cadena no aparece en el registro persistido;
2. el `ciphertext` decodificado de base64 **tampoco** la contiene (no es
   un simple encoding);
3. el registro no tiene ningún campo `plaintext/text/content/body/message`.

El caso 4 recorre esa lista de claves prohibidas y comprueba que el
servidor responde `PAYLOAD_INVALID` a cada una.

El caso 10 comprueba lo complementario: un tercero con un X3DH distinto
**no puede** descifrar tráfico A→B.

### 5.2 Idempotencia (§6)

El arnés distingue dos situaciones que se confunden a menudo:

- el outbox del cliente ya suprime reenvíos de un mensaje con ACK;
- el caso real que el servidor debe absorber es un cliente que **nunca
  vio el ACK** (se perdió con el socket) y retransmite.

`e2e_ab_flow` caso 5 fuerza esa retransmisión y comprueba: mismo
`server_seq`, `duplicate:true`, un solo mensaje persistido y un solo
fan-out a B.

### 5.3 ACK / DELIVERED / READ (§7)

Caso 6, en orden estricto, comprobando que cada estado **no** dispara los
otros:

```
A --message.send--> SERVER --message.ack--> A        (SENT)
                    SERVER --message.new--> B
B --message.delivered--> SERVER ----------> A        (DELIVERED)
B --message.read------> SERVER ----------> A         (READ)
```

Tras el ACK se verifica activamente (`expectNone`) que no llegó ningún
delivered ni read: los estados no se mezclan.

### 5.4 Orden y secuencia (§8)

Caso 8 envía cinco mensajes con `client_ts_ms` **decreciente**. El orden
observado por B corresponde al `server_seq`, no al timestamp del cliente.
Bajo concurrencia (10 clientes simultáneos), las secuencias son únicas y
contiguas.

### 5.5 Reconexión y red (§9, §10)

- La sesión anterior **no** revalida nunca tras reconectar.
- Un `session_id` viejo enviado explícitamente en un evento se ignora: la
  autorización usa la sesión ligada al socket.
- Cambio de red mid-send: el outbox reintenta con el **mismo**
  `message_id` y B recibe exactamente una copia.

### 5.6 Sync (§15)

- A offline → B envía 3 → A vuelve → sync recupera los 3, **descifrables
  con el mismo ratchet**, en orden, y una segunda sync no devuelve nada.
- Los recibos emitidos mientras A estaba offline también se recuperan
  (esto fallaba antes del arreglo del `log_seq`).
- Sync de cuenta completa recupera chats que el cliente nunca abrió.
- La paginación no salta eventos: se recorre el cursor y se comprueba que
  ningún `log_seq` se entrega dos veces ni se pierde.

### 5.7 Logs (§17)

`e2e_presence_signaling_logs` caso 9 hace dos comprobaciones
independientes sobre los logs producidos durante un flujo real:

1. **Contenido**: no aparecen el plaintext, el ciphertext, la clave
   pública, el `session_id`, el `account_id` completo ni el `message_id`
   completo.
2. **Estructura**: se parsea cada línea y se comprueba que ninguna clave
   pertenece a la lista prohibida (`FORBIDDEN_LOG_KEYS`).

Los identificadores se emiten truncados (`acc-…`).

### 5.8 Supabase (§18)

Un proyecto Supabase real no es alcanzable desde este entorno. La suite
`e2e_supabase_store` ejerce el **código de producción**
(`SupabaseRealtimeStore`) contra un doble de PostgREST en proceso que
respeta el mismo contrato HTTP (rutas, cabeceras, forma de las RPC) y
rechaza cualquier petición sin la service role key.

Prueba: la ruta A→servidor→**Supabase**→servidor→B, que sólo se persiste
ciphertext, que la service role key nunca llega al cliente ni al log, que
las secuencias vienen de la RPC atómica y son únicas bajo concurrencia, y
que la ausencia de la RPC **falla cerrado**.

No prueba: RLS real de Postgres ni comportamiento de red real.

### 5.9 Concurrencia (§22)

10 clientes simultáneos: handshakes en paralelo, sesiones distintas, un
mensaje cada uno con secuencias únicas y contiguas, y cada cliente recibe
exactamente los 9 mensajes de los demás. Después, una tormenta de
reconexión de los 10 a la vez sin cruce de identidades.

---

## 6. Pruebas Dart

```
test/socket/                 protocolo (handshake, sesiones, dedup, límites)
test/socket/sync_contract_test.dart   NUEVO — contrato de cursores de sync
test/crypto/                 X3DH, Double Ratchet, firma de handshake
```

**`flutter analyze` y `flutter test`: NOT RUN — Flutter SDK unavailable.**

No hay SDK de Flutter/Dart instalado y la red del entorno bloquea
`storage.googleapis.com` y `pub.dev`, así que tampoco se pudo instalar.
Las pruebas Dart nuevas y modificadas están escritas y revisadas, pero
**no ejecutadas**. Deben ejecutarse antes de dar por cerrada la fase en un
entorno con SDK:

```bash
flutter analyze
flutter test
```

---

## 7. Arnés de cliente

`server/src/client/nova_client.ts` — cliente real reutilizable:

- handshake completo con firma Ed25519 sobre el canónico `NOVA_AUTH_v1`;
- outbox idempotente con reintento del mismo `message_id`;
- cursores de sync por conversación;
- dedup de entrada por `message_id`;
- `dropConnection()` para simular pérdida de red y `reconnect()` que
  exige un `session_id` nuevo;
- `socketTap()` para auditar todo lo que el servidor envía al cliente.

`server/src/client/e2ee.ts` — X3DH + Double Ratchet reales sobre
`node:crypto`, con la misma construcción que la implementación Dart.

---

## 8. Limitaciones de estas pruebas

- Se ejecutan sobre **loopback**: no cubren latencia, pérdida de paquetes,
  MTU ni proxies intermedios.
- El E2EE del arnés **reproduce** el protocolo de la app; no ejecuta el
  código Dart. Verifica el protocolo, no la corrección línea a línea del
  cliente Flutter.
- No hay prueba multi-nodo (requiere Redis, ausente).
- Las llamadas se validan como **señalización**; no hay media WebRTC.
- 10 conexiones concurrentes según lo pedido; no es una prueba de carga.
