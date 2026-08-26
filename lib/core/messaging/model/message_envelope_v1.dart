/// Versioned message envelope (§8).
///
/// The envelope is the ONLY thing that crosses the wire. It separates two
/// worlds that must never be confused:
///
///   ROUTING METADATA  (cleartext) — what the server legitimately needs
///                     to store and deliver the message: ids, sequence,
///                     type tag, timestamps. Every field here is bound
///                     into the AAD (§9), so the server can read it but
///                     cannot alter it undetected.
///
///   ENCRYPTED PAYLOAD (opaque)   — the body. Only the recipient device
///                     can open it. It carries the actual content plus
///                     anything the recipient needs to render it (§8:
///                     "the ciphertext must contain only what the
///                     recipient needs to decrypt").
///
/// Version 1 is explicit in `envelopeVersion` and inside the AAD, so a
/// future v2 cannot be downgraded to v1 by a server that strips a field.
library;

import 'message_ids.dart';
import 'message_type.dart';

/// Current envelope version.
const int kEnvelopeVersionV1 = 1;

/// Wire tag for the ratchet ciphertext format produced by the engine.
const String kCiphertextHeaderDrV1 = 'dr.v1';

/// An outgoing/incoming envelope targeted at ONE recipient device.
///
/// One logical message fans out to N envelopes (one per active device of
/// the recipient account, plus the sender's other devices — §15). They
/// all share `messageId`; each has its own ciphertext because each device
/// has its own Double Ratchet session.
class MessageEnvelopeV1 {
  const MessageEnvelopeV1({
    required this.messageId,
    required this.conversationId,
    required this.senderAccountId,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.messageType,
    required this.ciphertextBase64,
    this.ciphertextHeaderType = kCiphertextHeaderDrV1,
    this.envelopeVersion = kEnvelopeVersionV1,
    this.clientTimestampMs,
    this.serverSeq,
    this.logSeq,
    this.expiresAtMs,
  });

  // ---- routing metadata (cleartext, AAD-bound) ----

  /// Stable across every retry AND across the per-device fan-out.
  final MessageId messageId;
  final ConversationId conversationId;
  final AccountId senderAccountId;
  final DeviceId senderDeviceId;

  /// Target device of THIS copy. Bound into the AAD so a server cannot
  /// replay one device's copy to another device (§9, §15).
  final DeviceId recipientDeviceId;

  final MessageType messageType;
  final int envelopeVersion;

  /// Format tag of the ciphertext so the recipient knows how to open it.
  /// Reveals nothing about the content.
  final String ciphertextHeaderType;

  // ---- encrypted payload ----

  /// Opaque AEAD output, base64. NEVER plaintext.
  final String ciphertextBase64;

  // ---- server-assigned / advisory ----

  /// UI hint only. Never an ordering authority — the server sequence is
  /// (FASE 0.5 §8). A lying client cannot reorder anything with this.
  final int? clientTimestampMs;

  /// Per-conversation message order, assigned by the server.
  final int? serverSeq;

  /// Event-log cursor for sync, assigned by the server.
  final int? logSeq;

  /// Disappearing-message deadline (§22), advisory for the server and
  /// enforced locally by the recipient.
  final int? expiresAtMs;

  /// Serializes to the `message.send` wire shape.
  ///
  /// Only routing metadata plus opaque ciphertext. There is deliberately
  /// no `text` / `body` / `content` field: the server-side guard rejects
  /// any envelope carrying one (FASE 0.5).
  Map<String, dynamic> toWire() => <String, dynamic>{
        'message_id': messageId.value,
        'conversation_id': conversationId.value,
        'sender_device_id': senderDeviceId.value,
        'recipient_device_id': recipientDeviceId.value,
        'message_type': messageType.wireTag,
        'envelope_version': envelopeVersion,
        'ciphertext': ciphertextBase64,
        'header_type': ciphertextHeaderType,
        if (clientTimestampMs != null) 'client_ts_ms': clientTimestampMs,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
      };

  /// Parses an inbound `message.new` / `sync.response` entry.
  ///
  /// `sender_account_id` is taken from the SERVER-STAMPED field: the
  /// server overwrites any client claim (FASE 0.5 anti-spoof), and the
  /// AAD check on decrypt is what ultimately proves it.
  static MessageEnvelopeV1? tryParseInbound(Map<String, dynamic> data) {
    final messageId = MessageId.tryParse(data['message_id'] as String?);
    final conversationId = ConversationId.tryParse(data['conversation_id'] as String?);
    final senderAccountId = AccountId.tryParse(data['sender_account_id'] as String?);
    final senderDeviceId = DeviceId.tryParse(data['sender_device_id'] as String?);
    final ciphertext = data['ciphertext'] as String?;

    if (messageId == null ||
        conversationId == null ||
        senderAccountId == null ||
        senderDeviceId == null ||
        ciphertext == null ||
        ciphertext.isEmpty) {
      return null;
    }

    // An unknown/absent type must not crash an older client; it lands as
    // `system` and the UI can show "unsupported message".
    final messageType =
        MessageType.fromWireTag(data['message_type'] as String?) ?? MessageType.system;

    // Missing recipient_device_id means a legacy/broadcast envelope; the
    // AAD check will reject it if it was not meant for this device.
    final recipientDeviceId =
        DeviceId.tryParse(data['recipient_device_id'] as String?) ?? senderDeviceId;

    return MessageEnvelopeV1(
      messageId: messageId,
      conversationId: conversationId,
      senderAccountId: senderAccountId,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      messageType: messageType,
      ciphertextBase64: ciphertext,
      ciphertextHeaderType: data['header_type'] as String? ?? kCiphertextHeaderDrV1,
      envelopeVersion: data['envelope_version'] as int? ?? kEnvelopeVersionV1,
      clientTimestampMs: data['client_ts_ms'] as int?,
      serverSeq: data['server_seq'] as int?,
      logSeq: data['log_seq'] as int?,
      expiresAtMs: data['expires_at_ms'] as int?,
    );
  }

  MessageEnvelopeV1 copyWith({int? serverSeq, int? logSeq}) => MessageEnvelopeV1(
        messageId: messageId,
        conversationId: conversationId,
        senderAccountId: senderAccountId,
        senderDeviceId: senderDeviceId,
        recipientDeviceId: recipientDeviceId,
        messageType: messageType,
        ciphertextBase64: ciphertextBase64,
        ciphertextHeaderType: ciphertextHeaderType,
        envelopeVersion: envelopeVersion,
        clientTimestampMs: clientTimestampMs,
        serverSeq: serverSeq ?? this.serverSeq,
        logSeq: logSeq ?? this.logSeq,
        expiresAtMs: expiresAtMs,
      );

  /// Validation before emitting. Returns null when valid, or a generic
  /// reason safe to log (no content, no ids).
  static String? validateOutgoing(MessageEnvelopeV1 envelope) {
    if (!envelope.messageId.isValid) return 'PAYLOAD_INVALID';
    if (!envelope.conversationId.isValid) return 'PAYLOAD_INVALID';
    if (!envelope.senderDeviceId.isValid) return 'PAYLOAD_INVALID';
    if (!envelope.recipientDeviceId.isValid) return 'PAYLOAD_INVALID';
    if (envelope.ciphertextBase64.isEmpty) return 'PAYLOAD_INVALID';
    if (envelope.ciphertextHeaderType.isEmpty) return 'PAYLOAD_INVALID';
    if (envelope.envelopeVersion <= 0) return 'PAYLOAD_INVALID';
    return null;
  }
}
