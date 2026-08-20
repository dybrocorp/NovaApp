# NovaApp Architecture

## Overview

NovaApp is a Flutter-based end-to-end encrypted messaging platform. The architecture follows a clean separation of concerns with feature-based organization and service-oriented business logic.

## Design Principles

1. **Security First** — All crypto operations use well-established protocols (X3DH, Double Ratchet, AES-256-GCM)
2. **Offline-First** — Local SQLite database with sync to Supabase
3. **E2EE** — Server never sees plaintext content or encryption keys
4. **Modularity** — Features are independent; services are injectable via Riverpod
5. **Defense in Depth** — Multiple layers of security (RLS, encryption, input validation)

## High-Level Architecture

```
┌─────────────────────────────────────────────┐
│                 Flutter App                  │
├──────────┬──────────┬──────────┬────────────┤
│  Auth    │  Chat    │  Calls   │  Groups    │
│  Feature │  Feature │  Feature │  Feature   │
├──────────┴──────────┴──────────┴────────────┤
│              Core Services                   │
│  ┌─────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ Crypto  │ │ Sync     │ │ Anti-Spam    │ │
│  │ Service │ │ Service  │ │ Service      │ │
│  └─────────┘ └──────────┘ └──────────────┘ │
├─────────────────────────────────────────────┤
│            Data Layer                        │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ Supabase │ │ SQLite   │ │ Secure     │  │
│  │ Client   │ │ Database │ │ Storage    │  │
│  └──────────┘ └──────────┘ └────────────┘  │
└─────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
┌─────────────────┐  ┌─────────────────┐
│    Supabase     │  │   Device Secure │
│    (Cloud)      │  │   Enclave       │
└─────────────────┘  └─────────────────┘
```

## Cryptographic Architecture

### Key Hierarchy

```
Account
├── Identity Key (IK)         Ed25519, long-lived
│   └── Signs SPK
├── Signed Pre-Key (SPK)      X25519, rotated every 7 days
├── One-Time Pre-Keys (OPK)   X25519, consumed once
│
├── Per-Conversation
│   └── Double Ratchet State
│       ├── Root Key
│       ├── Sending Chain Key
│       └── Receiving Chain Key
│
└── Per-Group
    └── Sender Key (SK)       AES-256, rotated on membership changes
```

### Protocol Flow

**1:1 Message (Alice → Bob):**

```
1. Alice fetches Bob's key bundle: {IK_B, SPK_B, OPK_B}
2. X3DH key agreement → Shared Secret (SS)
3. Double Ratchet initialized with SS
4. Each message encrypted with unique key from ratchet
5. Forward secrecy: compromising one key doesn't expose past messages
```

**Group Message:**

```
1. Group creator generates Sender Key (SK)
2. SK distributed to members via X3DH + member's identity key
3. Messages encrypted with SK (efficient: one encrypt per message)
4. On member removal: SK rotated, new SK distributed
```

## Service Layer

### Core Services

| Service | Responsibility |
|---------|---------------|
| `AuthService` | Challenge-response authentication, PIN hashing |
| `EncryptionService` | X25519 key pairs, ChaCha20 encryption |
| `X3DHService` | Key agreement protocol |
| `DoubleRatchetService` | Ongoing forward secrecy |
| `IdentityService` | Account ID / Device ID management |
| `DeviceService` | Device registration and revocation |
| `SessionService` | JWT session tracking |
| `BiometricService` | Local biometric authentication |
| `MessageStatusService` | Sending/sent/delivered/read states |
| `TypingIndicatorService` | Real-time typing indicators |
| `MessageEditService` | Edit/delete messages |
| `ReactionService` | Emoji reactions |
| `EphemeralMessageService` | Self-destructing messages |
| `GroupService` | Group CRUD, members, permissions |
| `GroupEncryptionService` | Sender Keys for groups |
| `VoiceCallService` | WebRTC voice calls |
| `VideoCallService` | Video call management |
| `GroupVideoCallService` | Multi-party video calls |
| `CallHistoryService` | Call log management |
| `MediaService` | File compression, encryption, cache |
| `VoiceNoteService` | Audio recording and playback |
| `OfflineSyncService` | Message queue and sync |
| `ConnectivityService` | Network state monitoring |
| `MultiDeviceService` | Cross-device sync |
| `PrivacyService` | User privacy settings |
| `AntiSpamService` | Abuse prevention |
| `OptimizationService` | Performance utilities |
| `SupabaseService` | Supabase CRUD operations |
| `DatabaseService` | SQLite operations |
| `NotificationService` | Push notifications |
| `LoggerService` | Application logging |

### Dependency Injection

All services use Riverpod providers for dependency injection:

```dart
final authServiceProvider = Provider<AuthService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AuthService(client);
});
```

## Data Layer

### Supabase (Cloud)

- **Real-time sync** via Supabase Realtime
- **Row Level Security** enforces per-user access
- **Edge Functions** for server-side operations (PIN verification, challenge generation)
- **Storage** for encrypted media files

### SQLite (Local)

- **Offline-first** data persistence
- **Message queue** for pending sends
- **Contact cache** for fast lookup
- **Encryption keys** (via flutter_secure_storage)

### Secure Storage

- Private keys never leave the device
- Biometric-gated access
- Platform-specific secure enclave (Android Keystore, iOS Keychain)

## Feature Modules

Each feature follows this structure:

```
features/
└── feature_name/
    ├── data/
    │   └── *_repository.dart     # Data access
    ├── domain/
    │   └── *_model.dart          # Data models
    └── presentation/
        ├── *_screen.dart         # UI screens
        ├── *_widget.dart         # Reusable widgets
        └── *_provider.dart       # Riverpod providers
```

## Security Layers

```
Layer 1: Input Validation
  └── Sanitize all user inputs (search, messages, names)

Layer 2: Row Level Security (Supabase)
  └── Database policies enforce per-user access

Layer 3: End-to-End Encryption
  └── X3DH + Double Ratchet for messages
  └── AES-256-GCM for files

Layer 4: Authentication
  └── Challenge-response (no password transmission)
  └── Rate limiting on attempts

Layer 5: Device Security
  └── Secure storage for keys
  └── Biometric-gated access
  └── Device registration with approval
```

## Offline Architecture

```
Online Flow:
  User → Local DB → Queue → Supabase → Recipient

Offline Flow:
  User → Local DB → Queue (pending)

Reconnection:
  Queue → Retry (exponential backoff) → Supabase
  Supabase → Sync → Local DB
```

## Performance Considerations

- **Lazy loading** for lists (pagination)
- **Image caching** with 100MB LRU limit
- **Debounced search** to prevent API spam
- **Efficient re-renders** via Riverpod selective rebuilds
- **Background sync** for message queue

## Testing Strategy

- **Unit tests** for crypto, identity, auth logic
- **Widget tests** for critical UI components
- **Integration tests** for end-to-end flows
- **Security tests** for crypto and auth

## Deployment

- **Android:** APK/AAB via `flutter build`
- **iOS:** Archive via Xcode
- **Web:** Static build via `flutter build web`
- **Backend:** Supabase (managed cloud or self-hosted)
