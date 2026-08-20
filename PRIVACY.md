# NovaApp Privacy Policy

**Last Updated:** 2026-08-18

## Overview

NovaApp is designed with privacy as a core principle. This policy explains what data we collect, how we use it, and your rights.

## Data We Collect

### Data You Provide
- **Nova ID** — Generated on your device (not linked to phone/email)
- **Display Name** — Chosen by you
- **Profile Avatar** — Optional, stored encrypted
- **PIN** — Hashed server-side, never transmitted in plaintext

### Data Generated During Use
- **Messages** — Encrypted end-to-end (server stores ciphertext only)
- **Media Files** — Encrypted before upload
- **Call Metadata** — Duration, participants (content is encrypted)
- **Device Information** — Device name, OS version, app version

### Data We Do NOT Collect
- Phone number (optional, for recovery only)
- Email address
- Location (unless explicitly shared in chat)
- Contact list (stored locally on device)
- Biometric data (stays on device secure enclave)
- Encryption keys (private keys never leave device)

## How We Use Data

### Authentication
- Verify your identity via Nova ID + PIN
- Manage device sessions
- Prevent unauthorized access

### Message Delivery
- Route encrypted messages between devices
- Sync message status (sent/delivered/read)
- Manage group membership

### Security
- Rate limiting to prevent abuse
- Detect and block spam accounts
- Protect against unauthorized access

### Improvement
- Anonymous usage analytics (opt-in)
- Crash reports (no personal data included)

## Data Storage

### On Our Servers (Supabase)
- Encrypted message content (ciphertext only)
- User profiles (name, Nova ID, avatar URL)
- Device registration records
- Encrypted encryption keys (public components only)

### On Your Device
- Private encryption keys (secure enclave)
- Local message cache (SQLite)
- Contact list
- Settings and preferences
- Biometric data

## Data Sharing

We do NOT sell, trade, or share your personal data with third parties.

### Limited Exceptions
- **Legal Requirements:** If required by law, we may disclose encrypted data (which is unreadable without your keys)
- **Service Providers:** Supabase infrastructure (encrypted data only)
- **Safety:** If required to prevent imminent harm (encrypted content only)

## Your Rights

### Access
- View all data we hold about you via the app settings
- Export your data in standard formats

### Deletion
- Delete your account and all associated data
- Request data deletion via support
- Local data deleted on app uninstall

### Portability
- Export messages and contacts
- Transfer account to new device

### Control
- Granular privacy settings (who can find/message/call you)
- Enable/disable read receipts, typing indicators
- Set default message expiration
- Revoke device access remotely

## Encryption Details

- **Messages:** X3DH + Double Ratchet (AES-256-GCM)
- **Files:** AES-256-GCM
- **Keys:** Stored in device secure enclave
- **Server Access:** Ciphertext only (cannot decrypt)

## Children's Privacy

NovaApp is not intended for users under 13 years of age. We do not knowingly collect data from children.

## Changes to This Policy

We will notify you of significant changes via in-app notification. Continued use constitutes acceptance.

## Contact

For privacy-related questions:
- Email: privacy@novaapp.chat (placeholder)
- GitHub: Open an issue (for non-sensitive matters)
