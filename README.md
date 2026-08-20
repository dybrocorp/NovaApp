# NovaApp

End-to-end encrypted messaging platform built with Flutter and Supabase.

![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![Dart](https://img.shields.io/badge/Dart-3.x-blue)

## Features

- **End-to-End Encryption** — X3DH key agreement + Double Ratchet protocol
- **Nova ID** — Unique identity with check digit (Luhn mod 32)
- **Secure Authentication** — Challenge-response with PIN hashing (PBKDF2)
- **1:1 and Group Messaging** — Text, voice notes, images, videos, files
- **Voice and Video Calls** — WebRTC with TURN server support
- **Group Video Calls** — Mesh (2-3) and SFU (4+) topologies
- **Offline-First** — Message queue with automatic sync
- **Multi-Device** — Device registration with approval flow
- **Privacy Controls** — Granular settings for visibility and messaging
- **Anti-Spam** — Rate limiting, flood detection, bot protection
- **Ephemeral Messages** — Configurable TTL (5s to 7 days)

## Security Model

| Layer | Protocol |
|-------|----------|
| Key Agreement | X3DH (Extended Triple Diffie-Hellman) |
| Message Encryption | Double Ratchet |
| Group Encryption | Sender Keys with rotation |
| File Encryption | AES-256-GCM |
| PIN Hashing | PBKDF2-HMAC-SHA256 (310k iterations) |
| Auth | Challenge-Response (no password transmission) |

See [SECURITY.md](SECURITY.md) for detailed security information.

## Architecture

```
lib/
├── core/
│   ├── constants.dart              # App-wide constants
│   ├── theme/                      # Colors, typography
│   ├── utils/                      # Identity utils, helpers
│   └── services/                   # Business logic services
│       ├── auth_service.dart       # Challenge-response auth
│       ├── encryption_service.dart # X25519 + ChaCha20
│       ├── double_ratchet_service.dart
│       ├── x3dh_service.dart       # Key agreement
│       ├── identity_service.dart   # Account/Device ID
│       ├── device_service.dart     # Device management
│       ├── session_service.dart    # Session tracking
│       ├── biometric_service.dart  # Local biometrics
│       ├── message_status_service.dart
│       ├── typing_indicator_service.dart
│       ├── message_edit_service.dart
│       ├── reaction_service.dart
│       ├── ephemeral_message_service.dart
│       ├── group_service.dart      # Group management
│       ├── group_encryption_service.dart
│       ├── voice_call_service.dart
│       ├── video_call_service.dart
│       ├── group_video_call_service.dart
│       ├── call_history_service.dart
│       ├── media_service.dart      # File handling
│       ├── voice_note_service.dart
│       ├── offline_sync_service.dart
│       ├── connectivity_service.dart
│       ├── multi_device_service.dart
│       ├── privacy_service.dart
│       ├── anti_spam_service.dart
│       ├── optimization_service.dart
│       ├── supabase_service.dart
│       ├── database_service.dart   # SQLite
│       ├── notification_service.dart
│       └── logger_service.dart
├── features/                       # Feature modules
│   ├── auth/                       # Authentication
│   ├── chat/                       # Messaging
│   ├── contacts/                   # Contact management
│   ├── calls/                      # Voice/video calls
│   ├── groups/                     # Group management
│   ├── settings/                   # App settings
│   └── profile/                    # User profile
└── shared/                         # Shared widgets
    └── widgets/
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed architecture documentation.

## Getting Started

### Prerequisites

- Flutter SDK ^3.10.8
- Dart SDK ^3.10.8
- Supabase account (free tier works)
- Firebase project (for push notifications)

### Installation

```bash
# Clone the repository
git clone https://github.com/dybrocorp/NovaApp.git
cd NovaApp

# Install dependencies
flutter pub get

# Configure environment
cp .env.example .env
# Edit .env with your Supabase credentials

# Run the app
flutter run
```

### Environment Variables

```env
SUPABASE_URL=your_supabase_url
SUPABASE_ANON_KEY=your_supabase_anon_key
FIREBASE_PROJECT_ID=your_firebase_project_id
```

### Database Setup

1. Create a Supabase project
2. Run the SQL migrations in order:
   - `supabase_setup.sql` — Base schema + RLS
   - `supabase_x3dh_migration.sql` — Crypto key tables
   - `supabase_auth_migration.sql` — Auth, devices, sessions
   - `supabase_chat_enhancement_migration.sql` — Message enhancements
   - `supabase_groups_migration.sql` — Groups system

## Testing

```bash
# Run all tests
flutter test

# Run with coverage
flutter test --coverage

# Run specific test file
flutter test test/widget_test.dart
```

## Building

```bash
# Android APK
flutter build apk --release

# Android App Bundle
flutter build appbundle --release

# iOS
flutter build ios --release

# Web
flutter build web --release
```

## Project Structure

- **core/** — Services, utilities, and constants shared across features
- **features/** — Feature-specific code (auth, chat, calls, etc.)
- **shared/** — Widgets and components used across multiple features
- **test/** — Unit and widget tests

## Dependencies

| Package | Purpose |
|---------|---------|
| flutter_riverpod | State management |
| supabase_flutter | Backend (auth, DB, realtime, storage) |
| cryptography | X25519, Ed25519, AES-GCM |
| flutter_webrtc | Voice/video calls |
| flutter_sound | Audio recording |
| cached_network_image | Image caching |
| flutter_secure_storage | Secure key storage |
| local_auth | Biometric authentication |

See [pubspec.yaml](pubspec.yaml) for the complete list.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Privacy

See [PRIVACY.md](PRIVACY.md) for privacy information.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.
