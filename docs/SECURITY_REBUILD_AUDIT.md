# FASE 0.5 — Reconstrucción de Seguridad e Identidad

**Fecha:** 2026-08-21
**Estado:** Auditoría completada + Errores de compilación corregidos

---

## Resumen Ejecutivo

El repositorio `NovaApp` fue auditado en su estado HEAD (`4f4f172`). Se encontraron **vulnerabilidades CRÍTICAS** en la capa de seguridad, errores de compilación (64 errores → **0 errores** tras correcciones), y una arquitectura criptográfica que requiere refactoring significativo.

**Acciones completadas:**
- Corregidos 64 errores de compilación (X3DH, Double Ratchet, GroupEncryption, Auth, Supabase, Voice, Biometric, etc.)
- Implementado `generateAccountId()` y `generateDeviceId()` en `IdentityUtils` usando HMAC-SHA256 y CSPRNG
- Corregido API de `Hkdf`, `Session`, `AuthenticationOptions`, `.inFilter()`, `onBroadcast`, y otros

---

## CRÍTICO — Vulnerabilidades de Seguridad

### C1. Messages RLS abierto (Supabase RLS bypass)

**Archivo:** `supabase_setup.sql:147`
**Problema:** La política de SELECT para mensajes usa `sender_id = auth.uid()::text`, pero `sender_id` es TEXT (Nova ID) mientras que `auth.uid()` es UUID. El cast `::text` de un UUID produce un formato diferente al Nova ID, por lo que la política **nunca coincide** y los mensajes son inaccesibles o, peor, el RLS puede ser bypassed.

```sql
-- PROBLEMA: UUID cast != Nova ID format
CREATE POLICY "Users can read own sent messages" ON messages
  FOR SELECT USING (sender_id = auth.uid()::text);
```

**Impacto:** Cualquier usuario autenticado podría leer TODOS los mensajes si la política falla silenciosamente, o nadie puede leerlos si falla de forma restrictiva.

**Corrección requerida:** Mapear `auth.uid()` → `nova_id` via join con `users`, o usar `auth.uid()` como `sender_id` (UUID).

### C2. Tabla users — SELECT público sin restricción

**Archivo:** `supabase_setup.sql:141`
**Problema:**
```sql
CREATE POLICY "Permitir lectura pública de usuarios" ON public.users FOR SELECT USING (true);
```
Permite que **cualquier usuario autenticado** lea todos los campos de TODOS los usuarios, incluyendo `public_key`, `fcm_token`, y datos sensibles.

**Corrección requerida:** Restringir a campos necesarios (nova_id, display_name, avatar_url, public_key) y denegar acceso a fcm_token y campos internos.

### C3. Contacts RLS — UUID vs Nova ID mismatch

**Archivo:** `supabase_setup.sql:152`
**Problema:** Igual que C1, `user_nova_id = auth.uid()::text` nunca coincidirá porque los formatos son incompatibles.

### C4. Call History RLS — UUID vs Nova ID mismatch

**Archivo:** `supabase_setup.sql:158`
**Problema:** Mismo problema que C1 y C3.

### C5. Sin forward secrecy en mensajes 1-a-1

**Archivo:** `lib/core/services/encryption_service.dart`
**Problema:** El cifrado actual usa ECDH estático (X25519) + ChaCha20-Poly1305. La misma clave se reutiliza para todas las mensajes entre dos usuarios. Si la clave privada se compromete, TODOS los mensajes históricos pueden descifrarse.

**Implementación actual:**
```dart
Future<String> encryptForRecipient(String plainText, String recipientPublicKeyBase64) async {
  final sharedSecret = await computeSharedSecret(recipientPubKey); // Misma clave siempre
  // ...
}
```

**Corrección requerida:** Implementar X3DH + Double Ratchet para forward secrecy.

### C6. Pre-keys y devices abiertos sin RLS

**Archivos:** `supabase_x3dh_migration.sql`
**Problema:** Las tablas `signed_pre_keys`, `one_time_pre_keys`, y `devices` no tienen RLS habilitado o tienen políticas demasiado permisivas.

---

## ALTO — Problemas Arquitectónicos

### H1. Account ID derivado con MD5 (previo) / HMAC-SHA256 (corregido)

**Estado:** Parcialmente corregido.
- Antes: `generateAccountId()` usaba MD5 (roto, no existía)
- Ahora: Usa HMAC-SHA256 con key `nova-account-id-v1` (determinístico, no reversible)

**Riesgo residual:** HMAC-SHA256 es adecuado para derivación determinística, pero el Account ID no es un identificador criptográfico fuerte. Considerar usar un UUID v5 con namespace fijo.

### H2. Device ID — Ahora usa CSPRNG

**Estado:** Corregido.
- Antes: `generateDeviceId()` usaba timestamp (predecible)
- Ahora: Usa `Random.secure()` con 16 bytes → UUID format

### H3. X3DH compilaba pero no funcionaba

**Estado:** Corregido.
- `class_in_class` (X3DHResult, X3DHKeyBundle declaradas dentro de X3DHService) → Movidas a nivel superior
- `Hkdf.hmacSha256()` no existe → Corregido a `Hkdf(hmac: Hmac.sha256(), outputLength: 32)`

### H4. Double Ratchet compilaba pero no funcionaba

**Estado:** Corregido.
- `class_in_class` (RatchetState) → Movida a nivel superior
- `receiveCount` referencia externa → Corregido a `state.receiveCount`
- Serialización de skipped keys incorrecta → Corregida

### H5. Group Encryption — getKeyFromPassword no existe

**Estado:** Corregido.
- `AesGcm.getKeyFromPassword()` no existe en la API → Reemplazado por `Hkdf` + `AesGcm.encrypt`
- `class_in_class` (GroupKeyState) → Movida a nivel superior
- Sender key generado con `DateTime.now().microsecondsSinceEpoch` (predecible) → Cambiado a `Random.secure()`

### H6. WebSocket sin autenticación criptográfica

**Archivo:** `lib/core/services/websocket_service.dart`
**Problema:** Socket.IO envía `userId` en texto plano sin prueba criptográfica de identidad.

### H7. TURN credentials embebidas en APK

**Archivo:** `lib/main.dart` (via `--dart-define`)
**Problema:** Las credenciales TURN se compilan en el APK, accesibles mediante descompilación.

---

## MEDIO — Problemas de Compilación Corregidos

| Archivo | Problema | Solución |
|---------|----------|----------|
| `x3dh_service.dart` | `class_in_class` + `Hkdf.hmacSha256()` | Clases movidas a top-level + API Hkdf corregida |
| `double_ratchet_service.dart` | `class_in_class` + `Hkdf.hmacSha256()` + `receiveCount` | Mismo tratamiento |
| `group_encryption_service.dart` | `class_in_class` + `getKeyFromPassword` | Clases movidas + Hkdf para key derivation |
| `auth_service.dart` | `Session()` constructor incorrecto | Usar `setSession(refreshToken, accessToken:)` |
| `biometric_service.dart` | `AuthenticationOptions` eliminado en v3 | API actualizada a parámetros directos |
| `connectivity_service.dart` | Switch no exhaustivo (faltaba `satellite`) | Case añadido |
| `ephemeral_message_service.dart` | `VoidCallback` sin import | Import de `package:flutter/foundation.dart` |
| `message_status_service.dart` | `.in_()` y `.asNameMaps` no existen | `.inFilter()` + Map manual |
| `optimization_service.dart` | `CacheManagerLogger` no existe | `CacheManagerLogLevel` |
| `reaction_service.dart` | `.in_()` no existe | `.inFilter()` |
| `supabase_service.dart` | Tipo `PostgrestFilterBuilder` incorrecto | Cambiado a `SupabaseQueryBuilder` |
| `typing_indicator_service.dart` | `payload` param no existe en `onBroadcast` | Eliminado |
| `voice_call_service.dart` | `String?` a `Object` | `!` null assertion añadido |
| `voice_note_service.dart` | `Amplitude`, `currentDB`, `getDuration`, `getCurrentPosition` | API actualizada a `RecordingDisposition` + `onProgress` stream |
| `identity_repository.dart` | `generateAccountId()` y `generateDeviceId()` no existían | Implementados en `IdentityUtils` |

---

## Arquitectura Criptográfica Objetivo (Fase 0.5)

### Capa de Identidad
```
Nova ID (visible) → HMAC-SHA256 → Account ID (interno, UUID-like)
CSPRNG (16 bytes) → Device ID (UUID format)
```

### Capa de Cifrado 1-a-1
```
X3DH (key establishment) → Session Key
  ↓
Double Ratchet (forward secrecy) → Per-message keys
  ↓
AES-256-GCM / ChaCha20-Poly1305 (message encryption)
```

### Capa de Cifrado Grupal
```
Sender Key Protocol:
  1. Group creator genera Sender Key (32 bytes CSPRNG)
  2. Distribuye via X3DH + SK a cada miembro
  3. Mensajes cifrados con Sender Key (AES-256-GCM)
  4. Rotación de key en cambios de miembros
```

### Estado Actual vs Objetivo
| Componente | Estado | Siguiente paso |
|-----------|--------|----------------|
| Nova ID | Funcional | — |
| Account ID | HMAC-SHA256 ✓ | Integrar en DB schema |
| Device ID | CSPRNG ✓ | Integrar en DB schema |
| X3DH | Compila ✓ | Integrar en flujo de registro |
| Double Ratchet | Compila ✓ | Integrar en chat repository |
| Group Encryption | Compila ✓ | Integrar en group service |
| Supabase RLS | Vulnerable ✗ | Corregir políticas RLS |
| WebSocket Auth | Sin auth ✗ | Añadir challenge-response |
| TURN Credentials | En APK ✗ | Mover a Edge Function |

---

## Archivos Modificados

1. `lib/core/utils/identity_utils.dart` — Añadidos `generateAccountId()`, `generateDeviceId()`
2. `lib/core/services/x3dh_service.dart` — Clases a top-level, Hkdf API corregida
3. `lib/core/services/double_ratchet_service.dart` — Clase a top-level, Hkdf API, receiveCount, serialización
4. `lib/core/services/group_encryption_service.dart` — Clase a top-level, key derivation, CSPRNG
5. `lib/core/services/auth_service.dart` — Session constructor corregido
6. `lib/core/services/biometric_service.dart` — API local_auth v3
7. `lib/core/services/connectivity_service.dart` — Switch exhaustivo
8. `lib/core/services/ephemeral_message_service.dart` — VoidCallback import
9. `lib/core/services/message_status_service.dart` — .inFilter(), map manual
10. `lib/core/services/optimization_service.dart` — CacheManagerLogLevel
11. `lib/core/services/reaction_service.dart` — .inFilter()
12. `lib/core/services/supabase_service.dart` — Tipo de callback corregido
13. `lib/core/services/typing_indicator_service.dart` — onBroadcast sin payload
14. `lib/core/services/voice_call_service.dart` — Null safety
15. `lib/core/services/voice_note_service.dart` — API flutter_sound v9 completa
16. `docs/SECURITY_REBUILD_AUDIT.md` — Este documento
