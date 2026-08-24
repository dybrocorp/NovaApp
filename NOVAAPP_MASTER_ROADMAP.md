# NOVAAPP MASTER ROADMAP

**Fecha de Auditoria:** 2026-08-18
**Version del Proyecto:** 1.0.0+1
**Framework:** Flutter 3.x (SDK ^3.10.8)
**Backend:** Supabase (PostgreSQL + Realtime + Auth + Storage)
**Estado:** Prototipo funcional con deuda tecnica significativa

---

## TABLA DE CONTENIDOS

1. [Diagnostico General](#1-diagnostico-general)
2. [Arquitectura Actual](#2-arquitectura-actual)
3. [Arquitectura Objetivo](#3-arquitectura-objetivo)
4. [Vulnerabilidades Criticas](#4-vulnerabilidades-criticas)
5. [Modelo de Seguridad](#5-modelo-de-seguridad)
6. [Modelo Nova ID](#6-modelo-nova-id)
7. [Modelo Criptografico](#7-modelo-criptografico)
8. [Arquitectura de Chat](#8-arquitectura-de-chat)
9. [Arquitectura de Llamadas](#9-arquitectura-de-llamadas)
10. [Arquitectura de Videollamadas](#10-arquitectura-de-videollamadas)
11. [Arquitectura Multimedia](#11-arquitectura-multimedia)
12. [Arquitectura Multidispositivo](#12-arquitectura-multidispositivo)
13. [Arquitectura Supabase](#13-arquitectura-supabase)
14. [Modelo de Datos](#14-modelo-de-datos)
15. [Roadmap de Implementacion](#15-roadmap-de-implementacion)
16. [Dependencias](#16-dependencias)
17. [Riesgos](#17-riesgos)
18. [Pruebas Necesarias](#18-pruebas-necesarias)

---

## 1. DIAGNOSTICO GENERAL

### Puntuacion Global: 4.5/10

NovaApp es un prototipo funcional con una base solida en concepto pero con problemas criticos de seguridad, deuda tecnica y funcionalidades incompletas. La aplicacion puede enviar/recibir mensajes cifrados y tiene llamadas basicas via WebRTC, pero carece de infraestructura para ser un producto de nivel profesional.

### Lo que funciona bien:
- Arquitectura Riverpod para gestion de estado
- Estructura de directorios limpia (core/features/shared)
- Base de datos local SQLite para offline-first
- Supabase como backend en tiempo real
- Integracion Firebase para notificaciones push
- Tema visual "Purple & Black" con identidad propia
- Sistema de grabacion de notas de voz con waveform
- Escaneo de QR codes para agregar contactos
- Sistema de bloqueo de pantalla (PIN + biometria)
- Identidad Nova ID basada en entropia aleatoria

### Lo que esta mal:
- Cifrado se silencia y envia en texto plano en caso de error
- Socket.io sin autenticacion (cualquiera puede suplantar usuarios)
- Políticas RLS de Supabase permiten TODO a todos los usuarios
- PIN almacenado en texto plano en secure storage
- SQLite sin cifrar en dispositivos comprometidos
- Busqueda de usuarios vulnerable a inyeccion SQL via ilike
- WebRTC sin servidores TURN (falla detras de NAT simetrico)
- Backup, donaciones y transferencia de cuenta son botones muertos
- Gestor de moderacion con join SQL roto
- Logger duplica 5 metodos identicos
- Supabase service duplica patron try-fallback 15+ veces
- Sin tests de widget/integration (solo 3 unit tests de identity)
- Android solicita permisos SMS (bloqueado por Play Store)
- iOS sin descripciones de permisos (crash en runtime)

### Funcionalidades incompletas:
- Grupos: solo UI basica, sin cifrado grupal real
- Historial de llamadas: solo esquema SQL, sin integracion
- Stories/Estados: hardcoded, sin backend
- Notas privadas: funcional pero sin backup
- Donaciones: UI sin implementacion
- Transferencia de cuenta: placeholder vacio
- 2FA: dialogo que dice "proximamente"
- Exportacion de datos: no implementada
- Borrado de datos: no implementa limpieza real

---

## 2. ARQUITECTURA ACTUAL

### 2.1 Estructura de Directorios

```
lib/
├── main.dart                          # Entry point (94 lines)
├── core/
│   ├── services/
│   │   ├── attachment_service.dart     # 211 lines - Media picking
│   │   ├── database_service.dart       # 97 lines  - SQLite CRUD
│   │   ├── encryption_service.dart     # 201 lines - X25519+ChaCha20
│   │   ├── link_preview_service.dart   # 181 lines - OG metadata
│   │   ├── logger_service.dart         # 60 lines  - Logging facade
│   │   ├── moderation_service.dart     # 181 lines - Report/Block
│   │   ├── notification_service.dart   # 123 lines - FCM push
│   │   ├── permission_service.dart     # 161 lines - Permissions
│   │   ├── supabase_service.dart       # 429 lines - Supabase CRUD
│   │   ├── webrtc_service.dart         # 294 lines - WebRTC calls
│   │   └── websocket_service.dart      # 231 lines - Socket.io
│   ├── theme/
│   │   ├── app_mode.dart               # 193 lines - Personal/Corporate
│   │   ├── nova_colors.dart            # 27 lines  - Color constants
│   │   └── nova_theme.dart             # 68 lines  - Material3 themes
│   └── utils/
│       └── identity_utils.dart         # 14 lines  - Nova ID generation
├── features/
│   ├── auth/
│   │   ├── data/
│   │   │   └── identity_repository.dart  # 55 lines
│   │   └── presentation/
│   │       ├── auth_providers.dart        # 18 lines
│   │       ├── identity_generation_screen.dart  # 227 lines
│   │       ├── onboarding_screen.dart     # 159 lines
│   │       ├── profile_setup_screen.dart  # 404 lines
│   │       └── recovery_screen.dart       # 158 lines
│   ├── chat/
│   │   ├── data/
│   │   │   ├── chat_providers.dart        # 32 lines
│   │   │   └── chat_repository_impl.dart  # 255 lines
│   │   ├── domain/
│   │   │   ├── chat_repository.dart       # 9 lines
│   │   │   └── models.dart               # 225 lines
│   │   └── presentation/
│   │       ├── attachment_menu.dart        # 169 lines
│   │       ├── call_screen.dart           # 270 lines
│   │       ├── chat_list_screen.dart      # 653 lines
│   │       ├── chat_screen.dart           # 674 lines
│   │       ├── contact_detail_screen.dart # 268 lines
│   │       ├── group_info_screen.dart     # 166 lines
│   │       ├── location_picker_screen.dart # 362 lines
│   │       ├── media_viewer_screen.dart   # 59 lines
│   │       ├── new_message_screen.dart    # 365 lines
│   │       ├── scanner_screen.dart        # 350 lines
│   │       └── story_viewer_screen.dart   # 174 lines
│   ├── profile/
│   │   └── presentation/
│   │       ├── profile_screen.dart        # 152 lines
│   │       └── settings_screen.dart       # 348 lines
│   └── settings/
│       ├── data/
│       │   ├── models.dart                # 1 line
│       │   └── security_repository.dart   # 136 lines
│       ├── logic/
│       │   └── security_manager.dart      # 84 lines
│       └── presentation/
│           ├── about_screen.dart           # 43 lines
│           ├── account_screen.dart         # 148 lines
│           ├── app_lock_settings_screen.dart # 257 lines
│           ├── app_mode_settings_screen.dart # 196 lines
│           ├── app_unlock_screen.dart      # 367 lines
│           ├── appearance_settings_screen.dart # 145 lines
│           ├── backup_id_screen.dart       # 137 lines
│           ├── blocked_contacts_screen.dart # 87 lines
│           ├── chat_settings_screen.dart    # 146 lines
│           ├── donation_screen.dart         # 61 lines
│           ├── help_screen.dart             # 145 lines
│           ├── notifications_settings_screen.dart # 155 lines
│           ├── privacy_settings_screen.dart # 82 lines
│           └── providers/
│               ├── security_providers.dart  # 29 lines
│               └── settings_provider.dart   # 93 lines
└── shared/
    └── widgets/
        ├── chat_bubble.dart               # 437 lines
        ├── link_preview_widget.dart       # 196 lines
        └── waveform_painter.dart          # 39 lines
```

**Total estimado:** ~7,500 lineas de Dart

### 2.2 Stack Tecnologico

| Capa | Tecnologia | Estado |
|------|-----------|--------|
| Framework | Flutter 3.x (SDK ^3.10.8) | OK |
| Estado | Riverpod 2.5.1 | OK |
| Backend | Supabase 2.12.4 | Basico |
| Auth | Supabase Auth (anon) | Critico |
| DB Local | SQLite (sqflite 2.3.3) | Sin cifrar |
| Almacenamiento | flutter_secure_storage 9.2.2 | OK |
| WebRTC | flutter_webrtc 0.12.0 | Sin TURN |
| Socket | socket_io_client 2.0.3+1 | Sin auth |
| Cifrado | cryptography 2.9.0 | Parcial |
| Push | Firebase Messaging 15.1.4 | Sin BG handler |
| Mapas | flutter_map 8.3.0 + OSM | OK |
| Audio | flutter_sound 9.15.2 | OK |
| QR | mobile_scanner 5.1.0 | OK |
| Camera | image_picker 1.1.2 | OK |
| Contacts | flutter_contacts 1.1.9+2 | OK |
| Biometria | local_auth 3.0.1 | OK |

### 2.3 Dependencias Faltantes Criticas

| Necesidad | Paquete Recomendado | Prioridad |
|-----------|-------------------|-----------|
| Cifrado SQLite | sqflite_common_ffi + sqlcipher_flutter | Alta |
| Group E2EE | sender_keys protocol (custom) | Alta |
| Key verification | visual fingerprint (custom) | Alta |
| Key rotation | periodic rotation protocol | Alta |
| TURN servers | coturn (self-hosted) o Twilio TURN | Alta |
| Image compression | flutter_image_compress | Media |
| Video player | video_player o chewie | Media |
| GIF | gif_view | Baja |
| Stickers | custom asset pipeline | Baja |

---

## 3. ARQUITECTURA OBJETIVO

### 3.1 Capas

```
┌─────────────────────────────────────────┐
│              PRESENTATION               │
│  Widgets + Screens + Animations         │
├─────────────────────────────────────────┤
│              APPLICATION                │
│  Use Cases + State Management (Riverpod)│
├─────────────────────────────────────────┤
│                DOMAIN                   │
│  Entities + Repository Interfaces       │
├─────────────────────────────────────────┤
│                 DATA                    │
│  Repository Implementations + DTOs      │
├─────────────────────────────────────────┤
│             INFRASTRUCTURE             │
│  Supabase + SQLite + WebRTC + Socket.io │
├─────────────────────────────────────────┤
│               PLATFORM                 │
│  Flutter + Native (Android/iOS)         │
└─────────────────────────────────────────┘
```

### 3.2 Separacion de Responsabilidades

```
Authentication
├── AuthRepository (interface)
├── SupabaseAuthDataSource
├── LocalIdentityDataSource
└── BiometricDataSource

Messaging
├── MessageRepository (interface)
├── SupabaseMessageDataSource
├── LocalMessageDataSource (SQLite encrypted)
├── EncryptionService
└── MessageSyncEngine

Calling
├── CallRepository (interface)
├── WebRTCService
├── SignalingService (Socket.io authenticated)
├── TURNService
└── CallQualityMonitor

Groups
├── GroupRepository (interface)
├── GroupEncryptionService (sender keys)
├── SupabaseGroupDataSource
└── LocalGroupDataSource

Contacts
├── ContactRepository (interface)
├── SupabaseContactDataSource
└── LocalContactDataSource
```

---

## 4. VULNERABILIDADES CRITICAS

### CRITICAS (P0) — Requieren correccion inmediata

| # | Ubicacion | Vulnerabilidad | Impacto |
|---|-----------|---------------|---------|
| 1 | `encryption_service.dart:107` | Fallback a texto plano cuando no hay clave privada | Mensajes viajan sin cifrado silenciosamente |
| 2 | `supabase_setup.sql:145-147` | RLS policies `FOR ALL USING (true)` | Cualquier usuario autenticado puede leer/escribir/borrar TODO |
| 3 | `supabase_service.dart:319` | Inyeccion SQL via `ilike` con `%$normalized%` | Extraccion de datos de usuarios |
| 4 | `websocket_service.dart` | Socket.io sin autenticacion | Suplantacion de identidad trivial |
| 5 | `chat_repository_impl.dart:218` | Envio de texto plano al fallar cifrado | Mensajes sin proteccion |
| 6 | `security_repository.dart:41` | PIN almacenado en texto plano | Extraccion de PIN en dispositivo comprometido |
| 7 | `app_unlock_screen.dart:63` | Borrado de datos falso tras 10 fallos | Seguridad ilusoria |

### ALTAS (P1) — Requieren correccion antes de produccion

| # | Ubicacion | Vulnerabilidad | Impacto |
|---|-----------|---------------|---------|
| 8 | `webrtc_service.dart` | Sin servidores TURN | Llamadas fallan detras de NAT simetrico |
| 9 | `webrtc_service.dart` | Sin autenticacion en señalizacion | Cualquiera puede interceptar/ofertar llamadas |
| 10 | `encryption_service.dart` | Sin rotacion de claves | Compromiso de clave = todo el historial expuesto |
| 11 | `database_service.dart` | SQLite sin cifrar | Todos los mensajes locales legibles |
| 12 | `notification_service.dart` | Sin handler de background | Notificaciones muertas cuando app esta cerrada |
| 13 | `android/AndroidManifest.xml` | Permisos SMS (`RECEIVE_SMS`, `READ_SMS`) | Play Store rechazara la app |
| 14 | `ios/Runner/Info.plist` | Sin `NS*UsageDescription` | Crash en runtime al usar camara/mic |
| 15 | `link_preview_service.dart` | SSRF via URLs internas | Acceso a redes internas |

### MEDIAS (P2) — Deben resolverse para calidad profesional

| # | Ubicacion | Vulnerabilidad | Impacto |
|---|-----------|---------------|---------|
| 16 | `supabase_service.dart` | Duplicacion masiva de patron try-fallback | Mantenibilidad destruida |
| 17 | `encryption_service.dart` | Dos APIs de cifrado paralelas | Confusion y bugs |
| 18 | `chat_list_screen.dart:590` | Boton de debug en produccion | Herramientas de desarrollo expuestas |
| 19 | `blocked_contacts_screen.dart` | Lista siempre vacia (sin persistencia) | Feature rota |
| 20 | `settings_provider.dart` | Sin persistencia de configuraciones | Configuraciones pierden al reiniciar |
| 21 | `backup_id_screen.dart` | Todos los botones no funcionan | UX enganosa |
| 22 | `donation_screen.dart` | Botones de donacion vacios | UX enganosa |

---

## 5. MODELO DE SEGURIDAD

### 5.1 Propiedades de Seguridad Objetivo

| Propiedad | Estado Actual | Objetivo |
|-----------|--------------|---------|
| Confidencialidad E2EE | Parcial (fallback a plaintext) | 100% de mensajes cifrados |
| Integridad | MAC en cifrado | MAC + signatures |
| Autenticacion | Anonima (sin identidad real) | Nova ID + clave publica |
| Forward Secrecy | No implementada | Ephemeral DH por sesion |
| Post-Compromise | No implementada | Key rotation periodica |
| Anti-Replay | Nonce aleatorio | Nonce + counter |
| Anti-MITM | Sin verificacion | Verificacion de huella digital |
| Atributo | Sin implementar | Sender keys para grupos |
| Despues-de-ruido | No implementado | Ratcheting (Double Ratchet) |

### 5.2 Modelo de Amenazas

| Attacker | Capacidad | Proteccion Actual |
|----------|-----------|-------------------|
| Observador de red | Ver trafico | WebRTC SRTP + HTTPS |
| Servidor Supabase | Acceso a DB | RLS roto - SIN proteccion |
| Dispositivo perdido | Acceso a storage | PIN/biometria (PIN en texto plano) |
| Contacto malicioso | Enviar mensajes | Sin rate limiting en busqueda |
| Actor avanzado | Comprometer clave | Sin rotacion ni forward secrecy |

### 5.3 Recomendaciones de Seguridad

1. **Inmediato:** Corregir RLS policies, eliminar fallback a plaintext, autenticar sockets
2. **Corto plazo:** Implementar SQLite cifrado, hash de PIN, key rotation
3. **Mediano plazo:** Double Ratchet para mensajes, sender keys para grupos
4. **Largo plazo:** Verificacion de identidad, auditoria externa

---

## 6. MODELO NOVA ID

### 6.1 Estado Actual

- **Formato:** `NOVA-XXXXXXXX` (8 caracteres alfanumericos, excluye I/O/0/1)
- **Generacion:** `Random.secure()` con 32^8 (~11 mil millones) de combinaciones
- **Almacenamiento:** FlutterSecureStorage localmente
- **Registro:** Enviado a Supabase como campo unico en tabla `users`
- **Uso:** Busqueda de contactos, identificacion en chats

### 6.2 Problemas Actuales

| Problema | Severidad | Descripcion |
|----------|-----------|-------------|
| Sin deteccion de colisiones | Media | Si se genera un ID existente, se acepta silenciosamente |
| Sin check digit | Baja | Errores de transcricion no detectados |
| Sin formato estandar | Baja | No sigue estandar como UUID o CUID |
| Uso como clave en contactos | Alta | `user_nova_id` en contactos es TEXT, sin FK a auth.users |

### 6.3 Arquitectura Nova ID Objetivo

```
Nova ID: NVA-XXXX-XXXX-XXXX (12 chars, 3 grupos de 4)
         ├── Prefijo: NVA (identificador de red)
         ├── 12 chars Crockford-base32 (excluye confusos)
         ├── Check digit: ultimo char (Luhn mod 32)
         └── Collision check: upsert con retry

Identidad separada:
  Nova ID (publico, compartible)
  → Account ID (interno, UUID, nunca expuesto)
  → Device ID (por dispositivo)
  → Crypto Identity (par de claves por cuenta)
  → Session Keys (por sesion/dispositivo)
```

---

## 7. MODELO CRIPTOGRAFICO

### 7.1 Estado Actual

**Algoritmos usados:**
- X25519 para intercambio de claves Diffie-Hellman
- ChaCha20-Poly1305 AEAD para cifrado de mensajes
- Claves almacenadas en FlutterSecureStorage

**Implementacion:** `encryption_service.dart` (201 lineas)

### 7.2 Problemas Criticos

| Problema | Linea | Impacto |
|----------|-------|---------|
| Fallback a texto plano | 107-108 | Mensajes viajan sin cifrar |
| Sin forward secrecy | General | DH estatico no provee FS |
| Sin rotacion de claves | General | Compromiso total si clave expuesta |
| Dos APIs paralelas | General | Mantenibilidad destruida |
| Clave publica en secure storage | 25 | Deberia estar solo en servidor |
| Sin verificacion de identidad | General | Sin proteccion MITM |

### 7.3 Arquitectura Criptografica Objetivo

```
Protocolo: Double Ratchet (Signal Protocol)
├── X3DH (Extended Triple Diffie-Hellman) para initial key agreement
├── Double Ratchet para forward secrecy continuo
├── Sender Keys para grupos (TreeKEM)
└── HMAC-SHA256 para key derivation

Identidad por nivel:
├── Identity Key (IK): Ed25519, permanente, una por cuenta
├── Signed Pre-Key (SPK): X25519, rotada periodicamente
├── One-Time Pre-Keys (OPK): X25519, usadas una vez
└── Ratchet Key: X25519, ephemeral por sesion

Almacenamiento:
├── Private keys: FlutterSecureStorage (enclave si disponible)
├── Public keys: Supabase (registration/upload)
└── Session state: SQLite cifrado (local)

Cifrado de archivos:
├── AES-256-GCM para archivos multimedia
├── Clave unica por archivo
├── Clave de archivo cifrada con shared secret
└── Thumbnails cifradas independientemente
```

---

## 8. ARQUITECTURA DE CHAT

### 8.1 Estado Actual

- **Mensajes de texto:** Funcional con E2EE basico (X25519 + ChaCha20)
- **Estados:** Enviando/Enviado/Leido (hardcoded, no real)
- **Offline:** SQLite local-first con sync a Supabase
- **Tiempo real:** Supabase Realtime (WebSockets)
- **Multimedia:** Picking de archivos, sin upload real
- **Notas de voz:** Grabacion con waveform, sin envio cifrado
- **Emojis:** Sin picker, solo texto
- **Reacciones:** No implementadas
- **Respuestas/citas:** No implementadas
- **Edicion:** No implementada
- **Eliminacion:** No implementada
- **Mensajes temporales:** No implementada
- **Mensajes fijados:** No implementada
- **Busqueda:** No implementada
- **Seleccion multiple:** No implementada
- **Link preview:** Implementado pero parsing roto

### 8.2 Arquitectura de Chat Objetivo

```
Chat 1:1
├── Mensajes de texto (E2EE via Double Ratchet)
├── Multimedia (E2EE via clave por archivo)
├── Notas de voz (E2EE + waveform real)
├── Emojis/Stickers/GIFs
├── Respuestas/Citas
├── Reacciones
├── Edicion/Eliminacion
├── Mensajes temporales (TTL configurable)
├── Mensajes fijados
├── Estados (enviando/enviado/entregado/leido/fallido)
├── Indicador de "escribiendo"
├── Busqueda local
├── Seleccion multiple
├── Enlace preview
└── Señal de verificacion de cifrado

Chat Grupal
├── Sender Keys (TreeKEM o similar)
├── Permisos de administrador
├── Mencion (@)
├── Permisos de envio
├── Mensajes fijados grupal
├── Archivos compartidos
├── Lista de participantes
├── Invite links
└── Borrar/salir del grupo
```

---

## 9. ARQUITECTURA DE LLAMADAS

### 9.1 Estado Actual

- **WebRTC:** flutter_webrtc 0.12.0 con signaling via socket.io
- **Audio:** Funcional basico
- **Video:** Funcional basico (sin adaptacion de calidad)
- **Servidores:** Solo STUN publico de Google (sin TURN)
- **Autenticacion:** Sin autenticacion en signaling
- **Historial:** Esquema SQL existe pero sin integracion
- **Reconexion:** No implementada

### 9.2 Problemas

| Problema | Impacto |
|----------|---------|
| Sin servidores TURN | 30-40% de llamadas fallan detras de NAT |
| Sin autenticacion en signaling | Suplantacion trivial |
| toggleSpeaker no funciona | Sin routear audio a altavoz |
| switchCamera crash en audio-only | Crash en llamadas de solo audio |
| Sin adaptacion de calidad | Calidad fija sin adaptar a red |
| Sin reconexion | Llamadas caen sin recuperacion |
| Sin historial real | CallHistory en SQL sin integrar |

### 9.3 Arquitectura de Llamadas Objetivo

```
Llamada de voz
├── WebRTC con servidores STUN + TURN
├── Autenticacion JWT en signaling
├── Adaptacion de bitrate automatica
├── Indicador de calidad en tiempo real
├── Mute/speaker/cambiar auricular
├── Reconexion automatica
├── Historial de llamadas
├── Notificacion de llamada entrante
└── Call waiting

Videollamada 1:1
├── Todo lo anterior mas:
├── Adaptacion de resolucion (480p/720p/1080p)
├── Adaptacion de FPS
├── Cambiar camara frontal/trasera
├── Picture-in-Picture
├── Filtro de calidad segun hardware/red
└── Screen sharing

Videollamada grupal
├── Arquitectura SFU (Selective Forwarding Unit)
├── Mesh para 2-3 participantes
├── SFU para 4+ participantes
├── Cuadricula dinamica
├── Participante activo destacado
├── Minimizar/pantalla completa
├── Control de permisos por participante
└── Limites de participantes (configurable)
```

---

## 10. ARQUITECTURA DE VIDEOLLAMADAS

### 10.1 Decision de Arquitectura

| Opcion | Participantes | Calidad | Latencia | Privacidad | Costo |
|--------|--------------|---------|----------|-----------|-------|
| P2P Mesh | 2-3 | Alta | Baja | Maxima | Gratis |
| SFU | 4+ | Alta | Media | Media | Servidor |
| MCU | 10+ | Media | Alta | Baja | Servidor potente |

**Decision:** Hibrida
- **2-3 participantes:** P2P Mesh (sin servidor)
- **4+ participantes:** SFU (requiere servidor de media)

### 10.2 Stack Recomendado

| Componente | Opcion | Justificacion |
|-----------|--------|---------------|
| SFU Server | LiveKit (open source) o Janus | Probado, escalable, E2EE |
| Signaling | Socket.io autenticado (existente) | Reutilizar infraestructura |
| TURN | coturn self-hosted o Twilio | Confiabilidad |
| Client SDK | flutter_webrtc (existente) | Ya integrado |
| Adaptacion | Simulcast + SVC | Calidad adaptativa |

---

## 11. ARQUITECTURA MULTIMEDIA

### 11.1 Estado Actual

- **Picking:** image_picker, file_picker, photo_manager
- **Compresion:** No implementada
- **Upload:** No implementada (solo picking local)
- **Download:** No implementada
- **Thumbnails:** No implementada
- **Cifrado:** No implementado para archivos
- **Notas de voz:** flutter_sound con waveform (grabacion local)

### 11.2 Arquitectura Multimedia Objetivo

```
Flujo de envio:
1. Seleccionar archivo
2. Validar tipo MIME y tamano
3. Comprimir si es necesario
4. Generar thumbnail
5. Cifrar con clave unica (AES-256-GCM)
6. Subir a Supabase Storage (cifrado)
7. Enviar metadata cifrada al chat
8. Descifrar en destino

Flujo de recepcion:
1. Recibir metadata
2. Descargar cifrado
3. Descifrar
4. Cache local
5. Mostrar preview

Politicas:
├── Max tamano: 100MB (configurable)
├── Tipos permitidos: imagen, video, audio, documento
├── Compresion automatica para imagenes > 2MB
├── Video: recomprimir si > 50MB
├── Thumbnails: 200x200 auto-generados
├── Cache: LRU con limite de 500MB
└── Validacion MIME real (no confiar en extension)
```

---

## 12. ARQUITECTURA MULTIDISPOSITIVO

### 12.1 Estado Actual

- Sin soporte multidispositivo real
- Cada instalacion es independiente
- Sin sincronizacion entre dispositivos
- Sin gestion de sesiones/dispositivos

### 12.2 Arquitectura Multidispositivo Objetivo

```
Account Model:
├── 1 Account → N Devices
├── 1 Device → 1 Crypto Identity
├── Account Key (AK): compartida entre dispositivos (via lincacion)
├── Per-device session keys
└── Sync engine

Device Management:
├── Registrar dispositivo (con aprobacion)
├── Renombrar dispositivo
├── Revocar dispositivo (borra claves de sesion)
├── Ver ultima actividad
├── Ver tipo (Android/iOS/Desktop)
└── Cerrar sesion remota

Sync:
├── Mensajes: sync via Supabase Realtime
├── Contactos: sync via Supabase
├── Configuracion: sync via Supabase
├── Media: download bajo demanda (no sync completa)
├── Offline queue: mensajes pendientes se sincronizan
└── Conflict resolution: timestamp-based (LWW)
```

---

## 13. ARQUITECTURA SUPABASE

### 13.1 Estado Actual de RLS

```sql
-- CRITICO: Estas policies permiten TODO
CREATE POLICY "Permitir todo en mensajes" ON messages FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en contactos" ON contacts FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en llamadas" ON call_history FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en reports" ON reports FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Permitir todo en blocked_users" ON blocked_users FOR ALL USING (true) WITH CHECK (true);
```

**Impacto:** Cualquier usuario autenticado puede:
- Leer TODOS los mensajes de TODOS los usuarios
- Borrar mensajes de otros
- Modificar contactos de otros
- Ver todo el historial de llamadas
- Reportar/bloquear como cualquier usuario
- Acceder a todas las claves publicas

### 13.2 Tablas Existentes

| Tabla | RLS | Politica Real | Riesgo |
|-------|-----|--------------|--------|
| users | Habilitado | Lectura publica, escritura propia | Media |
| messages | Habilitado | TODO permitido | Critico |
| contacts | Habilitado | TODO permitido | Critico |
| call_history | Habilitado | TODO permitido | Critico |
| reports | Habilitado | TODO permitido | Critico |
| blocked_users | Habilitado | TODO permitido | Critico |

### 13.3 Arquitectura Supabase Objetivo

```
Tablas necesarias:
├── accounts              # Cuentas (separado de auth.users)
├── nova_ids              # Nova ID → Account ID mapping
├── devices               # Dispositivos registrados
├── identity_keys         # Claves publicas de identidad
├── signed_pre_keys       # Pre-keys firmadas
├── one_time_pre_keys     # Pre-keys de uso unico
├── sessions              # Sesiones activas
├── contacts              # Relaciones de contacto
├── contact_requests      # Solicitudes pendientes
├── messages              # Metadatos de mensajes (sin contenido cifrado)
├── message_attachments   # Referencias a archivos
├── groups                # Grupos
├── group_members         # Miembros de grupo
├── group_messages        # Mensajes grupales
├── calls                 # Metadatos de llamadas
├── call_participants     # Participantes de llamada
├── blocked_users         # Bloqueos
├── reports               # Reportes
├── user_settings         # Configuracion por usuario
└── notifications_queue   # Cola de notificaciones

RLS policies corregidas:
├── messages: solo participantes del chat
├── contacts: solo propios
├── groups: solo miembros
├── calls: solo participantes
├── blocks: solo propio
├── reports: solo propios (lectura: admin)
└── identity_keys: publicas (solo lectura)
```

---

## 14. MODELO DE DATOS

### 14.1 Esquema Actual

```sql
-- users (identidad basica)
CREATE TABLE users (
  id UUID PRIMARY KEY REFERENCES auth.users(id),
  email TEXT,
  name TEXT,
  nova_id TEXT UNIQUE,
  display_name TEXT,
  avatar_url TEXT,
  public_key TEXT,
  fcm_token TEXT,
  privacy_level TEXT DEFAULT 'anyone',
  is_online BOOLEAN DEFAULT false,
  last_seen TIMESTAMPTZ,
  reports_count INTEGER DEFAULT 0,
  is_shadowbanned BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- messages (mensajes cifrados)
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  chat_id TEXT NOT NULL,
  sender_id TEXT NOT NULL,
  text TEXT,
  media_url TEXT,
  type TEXT DEFAULT 'text',
  timestamp TEXT NOT NULL,
  is_me INTEGER DEFAULT 0,
  status TEXT DEFAULT 'sent',
  poll_data JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- contacts
CREATE TABLE contacts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  contact_name TEXT,
  verification_level TEXT DEFAULT 'level1',
  last_message TEXT,
  last_message_time TIMESTAMPTZ,
  is_archived INTEGER DEFAULT 0,
  is_blocked INTEGER DEFAULT 0,
  is_favorite INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_nova_id, contact_id)
);

-- call_history
CREATE TABLE call_history (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_nova_id TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  contact_name TEXT,
  call_type TEXT NOT NULL,
  direction TEXT NOT NULL,
  duration INTEGER,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  status TEXT DEFAULT 'completed'
);

-- reports
CREATE TABLE reports (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id UUID REFERENCES auth.users(id),
  reported_id UUID REFERENCES auth.users(id),
  reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(reporter_id, reported_id)
);

-- blocked_users
CREATE TABLE blocked_users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  blocker_id UUID REFERENCES auth.users(id),
  blocked_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(blocker_id, blocked_id)
);
```

### 14.2 Problemas del Modelo

| Problema | Severidad | Descripcion |
|----------|-----------|-------------|
| `sender_id` es TEXT | Alta | Deberia ser UUID FK a auth.users |
| `chat_id` es TEXT | Alta | Deberia ser UUID o estructura determinista |
| Sin foreign keys en messages | Alta | Integridad referencial comprometida |
| `is_me` es INTEGER | Baja | Campo derivado, no deberia existir en DB |
| `timestamp` es TEXT | Media | Deberia ser TIMESTAMPTZ |
| `poll_data` sin validacion | Baja | JSONB sin schema validation |
| Sin tabla de grupos | Alta | Grupos no tienen backend real |
| Sin tabla de archivos | Media | Multimedia sin referencia en DB |
| Sin tabla de sesiones | Alta | Sin gestion multidispositivo |
| Sin tabla de dispositivos | Alta | Sin control de dispositivos |
| Sin tabla de claves | Alta | Sin soporte para key rotation |

---

## 15. ROADMAP DE IMPLEMENTACION

### FASE 0: Auditoria y Correccion de Criticos
**Duracion estimada:** 1-2 semanas
**Objetivo:** Eliminar vulnerabilidades P0

- [ ] Corregir RLS policies de Supabase (messages, contacts, call_history, reports, blocked_users)
- [ ] Eliminar fallback a texto plano en encryption_service
- [ ] Eliminar fallback a texto plano en chat_repository_impl
- [ ] Eliminar boton de debug en chat_list_screen
- [ ] Corregir broken join en moderation_service
- [ ] Eliminar permisos SMS de AndroidManifest
- [ ] Agregar NSUsageDescription en Info.plist de iOS
- [ ] Corregir version inconsistente (about/help)
- [ ] Corregir branding "Threema Safe" → "NovaApp Safe"

### FASE 1: Arquitectura Base
**Duracion estimada:** 2-3 semanas
**Objetivo:** Establecer arquitectura limpia

- [ ] Refactorizar supabase_service (extraer patron try-fallback a helper)
- [ ] Consolidar dos APIs de cifrado en una sola
- [ ] Crear capa de repository interfaces (domain/)
- [ ] Implementar logger con niveles y production-safe
- [ ] Eliminar dependencias circular
- [ ] Establecer constantes (no magic strings)
- [ ] Configurar flutter_lints estricto
- [ ] Agregar dart format y analyze al CI

### FASE 2: Nova ID + Identidad Criptografica
**Duracion estimada:** 2-3 semanas
**Objetivo:** Identidad robusta y separada

- [ ] Diseno de Nova ID con check digit (Luhn mod 32)
- [ ] Collision detection en registro
- [ ] Separacion Account ID / Nova ID / Device ID
- [ ] Implementar X3DH key agreement
- [ ] Key rotation periodica
- [ ] Key verification (fingerprint visual)
- [ ] Almacenamiento seguro de claves por nivel
- [ ] Tablas Supabase: accounts, nova_ids, devices, identity_keys, signed_pre_keys, one_time_pre_keys

### FASE 3: Autenticacion y Dispositivos
**Duracion estimada:** 2 semanas
**Objetivo:** Auth segura y multidispositivo

- [ ] Auth basada en Nova ID + PIN (sin dependencia de telefono)
- [ ] Challenge-response para login
- [ ] Passkeys/WebAuthn (si hardware soporta)
- [ ] Biometria local (no enviada al servidor)
- [ ] Hash de PIN en servidor (no texto plano)
- [ ] Registro de dispositivos con aprobacion
- [ ] Revocacion de dispositivos
- [ ] Gestion de sesiones
- [ ] Tablas: accounts, devices, sessions

### FASE 4: Chat 1:1
**Duracion estimada:** 3-4 semanas
**Objetivo:** Chat completo y seguro

- [ ] Double Ratchet para forward secrecy
- [ ] Estados de mensaje reales (enviando/enviado/entregado/leido)
- [ ] Indicador de "escribiendo"
- [ ] Edicion de mensajes
- [ ] Eliminacion de mensajes
- [ ] Respuestas/citas
- [ ] Reacciones
- [ ] Emojis picker
- [ ] Mensajes temporales (TTL configurable)
- [ ] Mensajes fijados
- [ ] Busqueda local de mensajes
- [ ] Seleccion multiple
- [ ] Link preview funcional (corregir parsing OG)
- [ ] Typing indicators via Supabase Realtime

### FASE 5: Sincronizacion Offline
**Duracion estimada:** 2 semanas
**Objetivo:** Funcionamiento completo sin conexion

- [ ] Cola de mensajes pendientes
- [ ] Resolucion de conflictos (LWW)
- [ ] Mensajes fuera de orden
- [ ] Mensajes duplicados (dedup por ID)
- [ ] Sincronizacion incremental
- [ ] Reconexion automatica con retry
- [ ] Cambio WiFi/datos sin perdida
- [ ] Estado de sincronizacion visible

### FASE 6: Multimedia
**Duracion estimada:** 3 semanas
**Objetivo:** Envio/recepcion completo de archivos

- [ ] Compresion automatica de imagenes
- [ ] Compresion de video
- [ ] Thumbnails auto-generados
- [ ] Upload progresivo con cancelacion
- [ ] Download progresivo con reanudacion
- [ ] Cifrado de archivos (AES-256-GCM)
- [ ] Validacion MIME real
- [ ] Cache LRU local
- [ ] Lmites de tamano configurables
- [ ] Proteccion contra archivos maliciosos

### FASE 7: Notas de Voz
**Duracion estimada:** 1-2 semanas
**Objetivo:** Experiencia premium de audio

- [ ] Grabar/pausar/reanudar/cancelar
- [ ] Waveform real (no fake)
- [ ] Duracion real del audio
- [ ] Reproduccion 1x/1.5x/2x
- [ ] Barra de progreso con seek
- [ ] Cifrado de audio
- [ ] Descarga eficiente
- [ ] Visualizacion de estado de carga

### FASE 8: Grupos
**Duracion estimada:** 4-5 semanas
**Objetivo:** Sistema completo de grupos

- [ ] Crear/eliminar grupos
- [ ] Agregar/expulsar miembros
- [ ] Multiples administradores
- [ ] Permisos granulares
- [ ] Enlace de invitacion
- [ ] Menciones (@)
- [ ] Mensajes fijados grupal
- [ ] Archivos compartidos
- [ ] Silenciar grupo
- [ ] Cifrado grupal (Sender Keys / TreeKEM)
- [ ] Tablas: groups, group_members, group_messages
- [ ] Gestion de permisos de envio

### FASE 9: Llamadas de Voz
**Duracion estimada:** 2-3 semanas
**Objetivo:** Llamadas confiables

- [ ] Servidores TURN (coturn o Twilio)
- [ ] Autenticacion JWT en signaling
- [ ] Adaptacion de bitrate automatica
- [ ] Mute/speaker/cambiar auricular
- [ ] Reconexion automatica
- [ ] Historial de llamadas real
- [ ] Notificacion de llamada entrante
- [ ] Call waiting
- [ ] Indicador de calidad
- [ ] Bluetooth support

### FASE 10: Videollamadas
**Duracion estimada:** 2-3 semanas
**Objetivo:** Video HD adaptativo

- [ ] Adaptacion de resolucion (480p/720p/1080p)
- [ ] Adaptacion de FPS
- [ ] Cambiar camara
- [ ] Picture-in-Picture
- [ ] Adaptacion segun CPU/temperatura/bateria
- [ ] Indicador de calidad en tiempo real
- [ ] Pantalla completa
- [ ] Minimizar

### FASE 11: Videollamadas Grupales
**Duracion estimada:** 3-4 semanas
**Objetivo:** Video grupal escalable

- [ ] Evaluar LiveKit/Janus como SFU
- [ ] Mesh para 2-3 participantes
- [ ] SFU para 4+ participantes
- [ ] Cuadricula dinamica
- [ ] Participante activo destacado
- [ ] Control de permisos
- [ ] Minimizar/pantalla completa
- [ ] Limites de participantes

### FASE 12: Multidispositivo
**Duracion estimada:** 2-3 semanas
**Objetivo:** Sync entre dispositivos

- [ ] Device registration flow
- [ ] Aprobacion de nuevos dispositivos
- [ ] Sync de mensajes
- [ ] Sync de contactos
- [ ] Sync de configuracion
- [ ] Revocacion de dispositivos
- [ ] Cierre de sesion remoto
- [ ] Tabla de sesiones

### FASE 13: Privacidad
**Duracion estimada:** 2 semanas
**Objetivo:** Controles granulares

- [ ] Panel de privacidad completo
- [ ] Quien puede encontrarme
- [ ] Quien puede escribirme
- [ ] Quien puede llamarme
- [ ] Quien puede agregarme a grupos
- [ ] Control de presencia
- [ ] Ultima conexion
- [ ] Confirmaciones de lectura
- [ ] Indicador de escritura
- [ ] Mensajes temporales globales

### FASE 14: Anti-Spam
**Duracion estimada:** 1-2 semanas
**Objetivo:** Proteccion contra abuso

- [ ] Rate limiting server-side
- [ ] Anti-enumeracion en busqueda
- [ ] Anti-scraping en perfiles
- [ ] Proteccion contra flooding
- [ ] Deteccion de bots
- [ ] Proteccion contra creacion masiva
- [ ] Abuse de llamadas

### FASE 15: Optimizacion
**Duracion estimada:** 2 semanas
**Objetivo:** Rendimiento optimo

- [ ] Lazy loading en listas
- [ ] Cache de imagenes con limits
- [ ] Reduccion de rebuilds innecesarios
- [ ] Eliminacion de memory leaks
- [ ] Optimizacion de queries SQLite
- [ ] Compresion de payloads de red
- [ ] Adaptive quality para gama baja
- [ ] Profiling y benchmarks

### FASE 16: Testing
**Duracion estimada:** 3-4 semanas
**Objetivo:** Cobertura completa

- [ ] Unit tests para domain logic
- [ ] Unit tests para crypto
- [ ] Widget tests para UI critica
- [ ] Integration tests para flows
- [ ] Security tests
- [ ] Database tests
- [ ] Synchronization tests
- [ ] WebRTC tests
- [ ] Offline tests
- [ ] Simular: servidor caido, WiFi perdido, latencia, jitter, duplicacion

### FASE 17: Security Audit
**Duracion estimada:** 2 semanas
**Objetivo:** Validacion de seguridad

- [ ] Auditoria de RLS policies
- [ ] Penetration testing
- [ ] Code review de crypto
- [ ] Análisis de permisos Android/iOS
- [ ] Verificacion de secure storage
- [ ] Test de rate limiting
- [ ] Test de anti-spam
- [ ] Documentacion de limitaciones conocidas

### FASE 18: Open Source Release
**Duracion estimada:** 2 semanas
**Objetivo:** Preparacion para publicacion

- [ ] README.md completo
- [ ] ARCHITECTURE.md
- [ ] SECURITY.md
- [ ] PRIVACY.md
- [ ] CONTRIBUTING.md
- [ ] CODE_OF_CONDUCT.md
- [ ] LICENSE (MIT o Apache 2.0)
- [ ] CI/CD con GitHub Actions
- [ ] dart analyze + flutter test en CI
- [ ] Secret scanning en CI
- [ ] Build validation Android/iOS
- [ ] Eliminar todos los secrets del repo
- [ ] Generar .env.example

---

## 16. DEPENDENCIAS

### Dependencias Actuales

| Paquete | Version | Uso | Estado |
|---------|---------|-----|--------|
| flutter_riverpod | 2.5.1 | State management | OK |
| supabase_flutter | 2.12.4 | Backend | OK |
| cryptography | 2.9.0 | E2EE | Parcial |
| flutter_secure_storage | 9.2.2 | Key storage | OK |
| flutter_webrtc | 0.12.0 | Calls | Sin TURN |
| socket_io_client | 2.0.3+1 | Signaling | Sin auth |
| firebase_messaging | 15.1.4 | Push | Sin BG |
| flutter_local_notifications | 18.0.1 | Local notif | OK |
| sqflite | 2.3.3+1 | Local DB | Sin cifrar |
| flutter_sound | 9.15.2 | Audio | OK |
| image_picker | 1.1.2 | Images | OK |
| file_picker | 8.0.3 | Files | OK |
| geolocator | 12.0.0 | Location | OK |
| flutter_contacts | 1.1.9+2 | Contacts | OK |
| mobile_scanner | 5.1.0 | QR | OK |
| qr_flutter | 4.1.0 | QR display | OK |
| flutter_map | 8.3.0 | Maps | OK |
| latlong2 | 0.9.1 | Coordinates | OK |
| cached_network_image | 3.4.1 | Image cache | OK |
| photo_manager | 3.9.0 | Gallery | OK |
| photo_view | 0.15.0 | Zoom | OK |
| local_auth | 3.0.1 | Biometric | OK |
| secure_application | 4.1.0 | App lock | OK |
| permission_handler | 11.3.1 | Permissions | OK |
| device_info_plus | 11.1.1 | Device info | OK |
| share_plus | 10.1.3 | Share | OK |
| path_provider | 2.1.3 | File paths | OK |
| shared_preferences | 2.2.3 | KV storage | OK |
| flutter_dotenv | 5.1.0 | Env vars | OK |
| uuid | 4.4.0 | UUIDs | OK |
| intl | 0.19.0 | Formatting | OK |
| pinput | 5.0.0 | PIN input | OK |
| intl_phone_field | 3.2.0 | Phone (remover) | Temporal |
| path | 1.9.0 | Path utils | OK |
| google_fonts | 6.2.1 | Fonts | OK |
| cupertino_icons | 1.0.8 | Icons | OK |
| crypto | 3.0.6 | Hashing | OK |

### Dependencias a Agregar

| Paquete | Uso | Prioridad |
|---------|-----|-----------|
| sqlcipher_flutter | SQLite cifrado | Alta |
| flutter_image_compress | Compresion de imagenes | Media |
| video_player / chewie | Reproduccion de video | Media |
| gif_view | GIFs | Baja |
| flutter_html | Rendering HTML (noticias) | Baja |
| permission_handler (mejorado) | Permisos mejorados | Media |

### Dependencias a Eliminar

| Paquete | Razon |
|---------|-------|
| intl_phone_field | Nova ID reemplaza telefono |

---

## 17. RIESGOS

### Riesgos Tecnicos

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|-----------|
| RLS roto permite acceso masivo | Alta | Critico | FASE 0 inmediata |
| SQLite sin cifrar en device comprometido | Alta | Alto | sqlcipher en FASE 1 |
| WebRTC sin TURN falla para muchos usuarios | Alta | Alto | coturn en FASE 9 |
| Socket.io sin auth permite suplantacion | Alta | Critico | JWT auth en FASE 1 |
| Double Ratchet complejidad de implementacion | Media | Alto | Usar libreria existente o protocolo Signal |
| Play Store rechaza por permisos SMS | Alta | Medio | Eliminar permisos en FASE 0 |
| iOS crash por permisos faltantes | Alta | Medio | Agregar NSUsageDescription en FASE 0 |
| Memory leaks en listas grandes | Media | Medio | Lazy loading en FASE 15 |

### Riesgos de Negocio

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|-----------|
| Exceso de funcionalidad → nunca lanzar | Alta | Critico | Priorizar MVP, lanzar temprano |
| Auditoria externa revela problemas | Media | Alto | Hacer auditoria interna primero |
| Open source sin preparation → mala reputacion | Media | Alto | FASE 18 completa antes de公开 |
| Competencia con Signal/WhatsApp | Alta | Medio | Diferenciacion en Nova ID y UX |

---

## 18. PRUEBAS NECESARIAS

### Unit Tests

| Modulo | Pruebas | Prioridad |
|--------|---------|-----------|
| encryption_service | Encrypt/decrypt roundtrip, key generation, fallback error | Alta |
| identity_utils | Format validation, uniqueness, collision detection | Alta |
| chat_repository | Message CRUD, sync, offline queue | Alta |
| database_service | Schema migrations, CRUD, indexes | Alta |
| moderation_service | Report, block, unblock, shadowban | Media |
| attachment_service | Pick, validate, compress | Media |
| link_preview_service | URL extraction, OG parsing | Baja |

### Widget Tests

| Widget | Pruebas | Prioridad |
|--------|---------|-----------|
| chat_bubble | Render all message types, status icons | Alta |
| chat_screen | Send message, record voice, attach file | Alta |
| chat_list_screen | Display contacts, search, filter | Alta |
| onboarding_screen | Navigation flow, entropy collection | Media |
| app_unlock_screen | PIN entry, biometric, wipe | Media |

### Integration Tests

| Flow | Pruebas | Prioridad |
|------|---------|-----------|
| Register → Profile → Chat List | Full onboarding flow | Alta |
| Send message → Receive → Decrypt | Full message flow | Alta |
| Add contact → Verify → Chat | Contact flow | Alta |
| Call start → Accept → End | Call flow | Alta |
| Offline → Online → Sync | Sync flow | Alta |

### Security Tests

| Area | Pruebas | Prioridad |
|------|---------|-----------|
| RLS | Attempt cross-user data access | Critica |
| Crypto | Known-answer tests, edge cases | Critica |
| Auth | Brute force PIN, session hijacking | Alta |
| Input | SQL injection, XSS, path traversal | Alta |
| Storage | Secure storage integrity | Media |

### Database Tests

| Area | Pruebas | Prioridad |
|------|---------|-----------|
| Schema | Migration integrity | Alta |
| RLS | Policy enforcement | Critica |
| Concurrency | Race conditions | Media |
| Performance | Query optimization | Media |

---

## RESUMEN EJECUTIVO

### Estado: PROTOTIPO FUNCIONAL CON VULNERABILIDADES CRITICAS

NovaApp tiene una base arquitectonica razonable con Riverpod, Supabase y una estructura de directorios limpia. Sin embargo, presenta **7 vulnerabilidades criticicas de seguridad** que impiden cualquier despliegue en produccion.

### Prioridad Inmediata:

1. **Corregir RLS policies** — Sin esto, cualquier usuario puede acceder a todos los datos
2. **Eliminar fallback a texto plano** — Los mensajes viajan sin cifrar silenciosamente
3. **Autenticar socket.io** — Sin esto, la suplantacion es trivial
4. **Eliminar permisos SMS** — Play Store rechazara la app
5. **Agregar permisos iOS** — La app crashea en runtime

### Path to Production:

- **Sprint 1-2:** FASE 0 (corregir criticos)
- **Sprint 3-5:** FASE 1-2 (arquitectura + identidad)
- **Sprint 6-7:** FASE 3-4 (auth + chat 1:1)
- **Sprint 8-9:** FASE 5-6 (offline + multimedia)
- **Sprint 10-11:** FASE 7-8 (voice notes + groups)
- **Sprint 12-14:** FASE 9-11 (calls + video)
- **Sprint 15-16:** FASE 12-13 (multidevice + privacy)
- **Sprint 17-18:** FASE 14-16 (spam + optimization + testing)
- **Sprint 19-20:** FASE 17-18 (security audit + open source)

### Total Estimado: ~20 sprints (40-50 semanas)

### Criterios de Exito por Fase:

- [ ] FASE 0: 0 vulnerabilidades P0
- [ ] FASE 4: Mensajes 1:1 E2EE completo sin fallback
- [ ] FASE 8: Grupos con cifrado funcional
- [ ] FASE 10: Videollamadas HD adaptativas
- [ ] FASE 16: >80% test coverage
- [ ] FASE 18: Publicacion open source exitosa

---

## Anexo: progreso FASE 0.5 (capa realtime)

- **PASO 4** — Hardening del cliente Socket.IO/WebSocket + especificación
  ejecutable del protocolo (`lib/core/socket/`, docs/SOCKET_*.md).
- **PASO 5** — **Servidor Socket.IO real** (Node 20/TS) en `server/`:
  handshake Ed25519, sesiones/revocación, `message.*` idempotentes con
  `server_seq`, sync, presencia privada, signaling, rate limits,
  `/healthz` + admin API, Docker. **E2E 40/40** (`cd server && npm test`).
  Pendiente (PASO 6): adapter Redis multi-nodo + validación contra el app
  real.

---

**Documento generado durante la FASE 0 de auditoria.**
**Proximo paso: Corregir las 7 vulnerabilidades criticas antes de continuar.**
