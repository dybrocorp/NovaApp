# NovaApp Security Policy

## Overview

NovaApp is an end-to-end encrypted messaging platform. This document describes the security model, known limitations, and reporting process.

## Encryption Model

### End-to-End Encryption (E2EE)

- **Key Agreement:** X3DH (Extended Triple Diffie-Hellman)
- **Message Encryption:** Double Ratchet Protocol
- **Group Encryption:** Sender Keys with key rotation
- **File Encryption:** AES-256-GCM
- **PIN Hashing:** PBKDF2-HMAC-SHA256 (310,000 iterations)

### Key Hierarchy

```
Identity Key (IK)     → Ed25519, long-lived, one per account
Signed Pre-Key (SPK)  → X25519, rotated every 7 days
One-Time Pre-Key (OPK)→ X25519, consumed once during key exchange
Sender Key (SK)       → AES-256, per-group, rotated on membership changes
```

### What the Server Never Sees

- Message content (encrypted end-to-end)
- PIN (hashed with PBKDF2, never transmitted)
- Biometric data (stays on device secure enclave)
- Encryption keys (private keys never leave device)

## Authentication

- Nova ID + PIN via challenge-response protocol
- PIN is hashed server-side using PBKDF2-HMAC-SHA256
- Challenge expires after 60 seconds
- Account lockout after 5 failed attempts

## Device Security

- Device registration requires approval from existing devices
- Remote device revocation supported
- Session management with automatic expiry
- Push tokens encrypted at rest

## Known Limitations

1. **Metadata Visibility:** Server can see who messages whom and when
2. **No Post-Quantum Resistance:** Current crypto is vulnerable to quantum attacks
3. **Group Encryption:** Sender Keys provide forward secrecy on member changes but not on every message
4. **No Visual Verification:** Key fingerprints not yet implemented in UI
5. **Client-Side Trust:** App integrity depends on device security

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

- **Email:** security@novaapp.chat (placeholder)
- **GitHub:** Private security advisory
- **Do NOT:** Open public issues for security vulnerabilities

We aim to respond within 48 hours and provide a fix within 7 days for critical issues.

## Security Audit Checklist

- [x] RLS policies enforce per-user access control
- [x] No plaintext fallback in encryption
- [x] No debug buttons in production
- [x] PIN hashed with strong KDF (PBKDF2 310k iterations)
- [x] Challenge-response authentication (no password transmission)
- [x] Device registration with approval flow
- [x] Rate limiting on authentication attempts
- [x] Anti-enumeration in user search
- [x] No sensitive data in logs (production mode)
- [x] Input sanitization on all user inputs
- [ ] Third-party security audit (pending)
- [ ] Penetration testing (pending)

## Cryptographic Dependencies

| Library | Version | Purpose |
|---------|---------|---------|
| cryptography | 2.9.0 | X25519, Ed25519, AES-GCM |
| crypto | 3.0.6 | HMAC-SHA256, PBKDF2 |
| flutter_secure_storage | 9.2.2 | Key storage on device |
| supabase_flutter | 2.12.4 | Auth, database, realtime |

## Compliance

- GDPR: Data export and deletion supported
- No phone number required for registration
- No location tracking without explicit consent
- Biometric data never leaves device
