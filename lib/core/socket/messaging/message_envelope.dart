/// Message envelope transported over Socket.IO.
///
/// HARD RULE: the realtime server only ever sees CIPHERTEXT. Encryption
/// happens on-device (E2EE — Double Ratchet, see double_ratchet_service.dart);
/// the server relays opaque bytes and attaches server-side metadata
/// (server_seq, received_at). The server MUST NOT be able to decrypt
/// content, and the client MUST refuse to emit envelopes containing
/// plaintext fields.
import 'package:uuid/uuid.dart';

class MessageEnvelope {
  const MessageEnvelope({
    required this.messageId,
    required this.conversationId,
    required this.senderDeviceId,
    required this.ciphertextBase64,
    required this.ciphertextHeaderType,
    this.clientTimestampMs,
  });

  /// Generates a fresh envelope with a random message_id (UUID v4).
  /// The id is stable across retries — this is what makes sends idempotent
  /// when the client re-emits after a reconnection.
  factory MessageEnvelope.create({
    required String conversationId,
    required String senderDeviceId,
    required String ciphertextBase64,
    required String ciphertextHeaderType,
    required DateTime now,
  }) =>
      MessageEnvelope(
        messageId: const Uuid().v4(),
        conversationId: conversationId,
        senderDeviceId: senderDeviceId,
        ciphertextBase64: ciphertextBase64,
        ciphertextHeaderType: ciphertextHeaderType,
        clientTimestampMs: now.millisecondsSinceEpoch,
      );

  final String messageId;
  final String conversationId;
  final String senderDeviceId;

  /// Opaque E2EE ciphertext (base64). NEVER plaintext.
  final String ciphertextBase64;

  /// E2EE header type tag (e.g. 'dr.v1') so the receiving device knows how
  /// to decrypt. Still reveals nothing about content.
  final String ciphertextHeaderType;

  /// Client timestamp — a HINT for UI ordering only. Ordering authority is
  /// the server-assigned sequence (see SequenceGapDetector); client
  /// timestamps are never trusted for canonical ordering.
  final int? clientTimestampMs;

  Map<String, dynamic> toWire() => <String, dynamic>{
        'message_id': messageId,
        'conversation_id': conversationId,
        'sender_device_id': senderDeviceId,
        'ciphertext': ciphertextBase64,
        'header_type': ciphertextHeaderType,
        if (clientTimestampMs != null) 'client_ts_ms': clientTimestampMs,
      };

  /// Validates the envelope before emitting. Returns null when valid, or a
  /// rejection reason (generic — safe to log).
  static String? validateOutgoing(MessageEnvelope envelope) {
    if (envelope.messageId.isEmpty) return 'PAYLOAD_INVALID';
    if (envelope.conversationId.isEmpty) return 'PAYLOAD_INVALID';
    if (envelope.ciphertextBase64.isEmpty) return 'PAYLOAD_INVALID';
    if (envelope.ciphertextHeaderType.isEmpty) return 'PAYLOAD_INVALID';
    return null;
  }

  /// Parses an inbound envelope (from message fan-out or sync.response).
  /// Server-assigned fields are read here, client fields are NOT trusted.
  static InboundMessage? tryParseInbound(dynamic data, {required int serverSeq}) {
    if (data is! Map) return null;
    final messageId = data['message_id'];
    final conversationId = data['conversation_id'];
    final ciphertext = data['ciphertext'];
    final headerType = data['header_type'];
    if (messageId is! String ||
        messageId.isEmpty ||
        conversationId is! String ||
        ciphertext is! String ||
        ciphertext.isEmpty ||
        headerType is! String) {
      return null;
    }
    return InboundMessage(
      messageId: messageId,
      conversationId: conversationId,
      ciphertextBase64: ciphertext,
      ciphertextHeaderType: headerType,
      serverSeq: serverSeq,
    );
  }
}

/// Inbound message with server-assigned ordering.
class InboundMessage {
  const InboundMessage({
    required this.messageId,
    required this.conversationId,
    required this.ciphertextBase64,
    required this.ciphertextHeaderType,
    required this.serverSeq,
  });

  final String messageId;
  final String conversationId;
  final String ciphertextBase64;
  final String ciphertextHeaderType;

  /// Monotonic per-conversation sequence assigned by the server. This is
  /// the ONLY ordering authority; client timestamps are hints.
  final int serverSeq;
}

/// Guard used on the send path: rejects any map that carries plaintext-ish
/// keys. Defense in depth so a future bug can never leak unencrypted text
/// into the socket layer.
const Set<String> forbiddenPlaintextKeys = <String>{
  'plaintext',
  'plain_text',
  'text',
  'content',
  'body',
  'message',
  'decrypted',
};

/// Returns true when [map] contains a forbidden plaintext key with a
/// non-empty value (the send path must refuse to emit it).
bool containsPlaintextPayload(Map<String, dynamic> map) {
  for (final key in forbiddenPlaintextKeys) {
    final value = map[key];
    if (value != null && value.toString().isNotEmpty) return true;
  }
  return false;
}
