# FASE 1.1 — Cierre de bloqueantes y validación real del motor E2EE

Fecha: 2026-08-31 · Rama: `arena/01a04505-novaapp` (base `main` = 5b7acac,
que incluye el motor 649b3b2 y el fix de upgrade de esquema cfd832e) ·
Regla rectora respetada: **no se empezó FASE 2, no hay UI, no hay WebRTC, no
hay funcionalidad nueva** — sólo cierre de bloqueantes y validación.

## 1. Bloqueantes

Los 5 bloqueantes del informe de FASE 1, transcritos y resueltos/auditados
uno por uno en **`docs/PHASE1_1_BLOCKERS.md`**. Resumen: 2 cerrados con
pruebas EJECUTADAS (5) o auditoría concluyente (2), 1 cerrado en código con
verde atado a la gate de Dart (4), 2 permanecen abiertos por limitación dura
de entorno (1) o por decisión de alcance honesta (3).

## 2. Resultados de ejecución (este pase)

| Suite | Resultado | Naturaleza |
|---|---|---|
| `cd server && npm test` | **137/137** (129 base + 5 delete/expiry + **3 nuevas** conc/reconexión) | EJECUTADO, 17.7 s |
| `npm run typecheck` (`tsc --noEmit`) | **0 errores** | EJECUTADO |
| `supabase/test/run_schema_tests.py` (PostgreSQL 16.2 real vía pgserver) | **14/14** — incluye migración 002 sola/repetida, idempotencia x3, upgrade sobre 4 esquemas antiguos, ruta legacy completa, no-destrucción de datos, abort por tipo incompatible | EJECUTADO |
| `supabase/test/run_rls_tests.py` (nuevo) | **23/23** — RLS **aplicada de verdad**: `SET ROLE authenticated` + claims JWT como inyecta Supabase; ataque a datos ajenos denegado en 7 tablas; positivos por dueño para que el verde no venga de GRANT ausente; `realtime_*` inaccesible al cliente incluso suyo; `service_role` sí (canal del servidor) | EJECUTADO |
| `flutter --version` / `dart --version` | `command not found` | INTENTO REAL, no disponible |
| `flutter analyze` / `flutter test` | — | **NOT RUN — Reason: Environment limitation** (sin Flutter/Dart SDK; egreso de red verificado: `storage.googleapis.com`/`pub.dev` bloqueados, sólo npm/PyPI/GitHub; instalar desde espejos no oficiales prohibido por la fase) |

Regresión FASE 0.5: todas las suites previas siguen dentro del 137/137
(109 de FASE 0.5 + 20 de FASE 1/port) — el conteo **no bajó**.

## 3. Nuevo material de este pase (todo con su prueba o su "NOT RUN")

* `server/test/e2e_phase1_concurrency.test.ts` — §15/§16: ráfaga M1–M5
  simultánea (acks en orden, `server_seq` contiguo 1..5, exactamente una
  copia por dispositivo, replay de la ráfaga = no-op que re-achea el seq
  original); sync tras ráfaga (5 eventos, re-aplicación = dedup puro
  `applied:0/duplicates:5`); corte de conexión a mitad de ráfaga (los 3
  sin-ack quedan `pending()`, el flush tras reconectar los reenvía con el
  **mismo id lógico**, B recibe 5/5, cero duplicados). **EJECUTADO 3/3.**
* `test/messaging/outbox_retry_policy_test.dart` — §7: ventana de backoff
  exponencial sin hot-retry, terminal `failed` en `maxAttempts` (nunca se
  reanima), ACK detiene y guarda `server_seq`, estados forward-only
  (`delivered` tardío no revierte `read`), dedup `(message_id, dispositivo)`
  sin resucitar filas fallidas, caducidad dura `maxAge` → `EXPIRED`, e
  independencia por dispositivo en el fan-out. **NOT RUN** (sin SDK); escrito
  contra las firmas leídas de `outbox_store.dart`.
* `supabase/test/run_rls_tests.py` — ver tabla anterior. **EJECUTADO.**
* Fuga de notificaciones: `chat_repository_impl.dart` cableado a
  `NotificationPolicy.build(level: senderOnly, …)`; `decryptedText` ya no
  viaja a la notificación local. **Verificación estática + grep** (único
  punto de llamada saneado); suite de la política (9 casos) NOT RUN.

## 4. Áreas (§23)

| Área | Estado | Evidencia |
|---|---|---|
| Server | ✅ EJECUTADO | 137/137 + typecheck 0 |
| Flutter | ⛔ NOT RUN | Environment limitation (§2 arriba); analyze/test pendientes en estación |
| E2EE | 🟡 PARCIAL | Flujo A→B opaco servidor **ejecutado** (`e2e_ab_flow`); A→B con descifrado real en cliente = suites Dart escritas, NOT RUN |
| AAD | 🟡 PARCIAL | Tampering de campos del sobre en servidor **ejecutado y rechazado** (security 1/2/5/8/9); binding criptográfico AAD = `message_aad_test.dart` (12 casos) NOT RUN |
| Outbox | 🟡 PARCIAL | Persistencia/idempotencia servidor **ejecutada**; política retry/backoff/max/expire/dedup = test nuevo NOT RUN (sin cobertura previa, ahora escrita) |
| Inbox | 🟡 PARCIAL | Fan-out+sync **ejecutados**; persist+ACK-antes-de-descifrado y recuperación = Dart NOT RUN |
| Sync | ✅ EJECUTADO | `e2e_sync` 4/4 + `e2e_reconnect_sync` 10/10 (página truncada, cursor viejo/adelantado, orden, gaps) + concurrencia nueva |
| Multi-device | ✅ EJECUTADO | `e2e_phase1_multidevice` 7/7 (copias por dispositivo, idempotencia por dispositivo, revocada no recibe) |
| RLS | ✅ EJECUTADO | 23/23 enforcement real en PostgreSQL + 14/14 esquema (66 políticas creadas) |
| Security | ✅ EJECUTADO | 13 vectores FASE 1 + matriz auth 14 + rate limits + plaintext guards (security 11, messaging 7) + auditoría §13/§14 abajo |
| Offline | 🟡 PARCIAL | Servidor: sin-ack sobrevive a cortes (ejecutado); cliente cold-queue portado: test NOT RUN |
| Reconnect | ✅ EJECUTADO (server) / NOT RUN (cliente) | nueva prueba 3 ráfaga-cortada verde |
| Dedup | ✅ EJECUTADO (server) | ids lógicos reenviados = 1 fila/1 entrega por dispositivo |
| Authorization | ✅ EJECUTADO | `e2e_authorization` 12 + delete sender-only 5/5 |
| Device revocation | ✅ EJECUTADO | auth-matrix 14 (kill session + re-auth denegado), multidevice 5, authorización 10 |
| Plaintext protection | ✅ EJECUTADO | campos plaintext → PAYLOAD_INVALID (2 suites); `toWire()` del sobre revisado: sólo ids/seq/ciphertext/header/ts; auditoría de claves abajo |

## 5. Auditorías manuales (con evidencia)

* **§13 Claves privadas:** `grep -riE 'privateKey|secretKey|identitySecret|
  seed'` sobre `server/src` → únicos hits: `client/e2ee.ts` (cliente de
  TEST, genera X25519 locales; nunca viajan), `logger.ts` (lista de
  **redacción** que incluye `private_key`/`secret`/`service_role`),
  `admin_api.ts` ("seed" = sembrar datos). En Dart: ningún log contiene
  material de clave (grep 0 hits). El único bytes privados nuevos — la seed
  del ratchet X25519 — sólo se persiste vía `RatchetStatePersistence` en el
  store local de sesiones del host (misma superficie que `rootKey` ya tiene;
  nunca Socket.IO/Supabase/analytics).
* **§14 Plaintext:** el servidor **no posee** ninguna ruta que acepte
  `text|body|content|plaintext` en `message.send` (rechazo probado) y los
  campos del envelope saliente (`toWire()`) son exactamente
  `message_id, conversation_id, sender_device_id, recipient_device_id,
  message_type, envelope_version, ciphertext, header_type[, client_ts_ms,
  expires_at_ms]`. La redacción `message.delete` guarda `''` (nunca NULL,
  nunca texto) — probado end-to-end en la suite portada.
* **Bloqueante 2:** `enum` anidado en clase es legal en Dart ≥ 2.17; SDK del
  proyecto `^3.10.8` → la reclamación "no compila" queda refutada por
  auditoría (sin cambio de código).

## 6. Riesgos restantes y dependencias

1. **Gate Dart** (único impedimento grande): 87 casos en `test/messaging/` (75
   previos + 6 port + 6 outbox nuevos) y las suites `test/socket/` requieren `flutter test` en una
   estación. Riesgo: errores de compilación residuales en el código escrito
   a ciegas (port D1–D3, tests nuevos). Mitigación: todas las firmas usadas
   fueron leídas del árbol real; el fix es acotado si aparece.
2. **Proyecto Supabase gestionado** (GoTrue real, extensiones reales,
   Storage): NOT RUN — entorno no disponible; sustituido por emulación
   fiel (roles/claims/tablas idénticas) en PostgreSQL 16.2 real.
3. **Adaptadores de integración** (bloqueante 3): abiertos a propósito; sin
   ellos la UI no conecta — pero FASE 1.1 no es la fase de UI.
4. El nivel de notificación quedó fijo en `senderOnly` en el punto de
   cableado; respetar `previewEnabled`/`senderAndContent`+estado de bloqueo
   requiere el provider de ajustes (trabajo de integración, anotado).

## 7. Estado

**FASE 1.1 STATUS: NOT READY FOR PHASE 2**

Todo lo verificable en este entorno fue verificado EJECUTANDO
(137/137 servidor, typecheck, 14/14 esquema PG real, 23/23 RLS real).
Los criterios §21 "Flutter analyze pasa" y "Flutter tests pasan" **no
pueden afirmarse** en este entorno; la fase no declara verde que no corrió.
Al ejecutarse `flutter analyze && flutter test` en una estación con SDK y
quedar verdes (con los ajustes menores que revelen), los criterios restantes
de §21 ya están cubiertos por la evidencia de arriba y la fase podrá
declararse COMPLETE sin trabajo adicional de motor.
