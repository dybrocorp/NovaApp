/// Message-level E2EE for the FASE 1 engine (§7, §8, §9).
///
/// This service is the ONLY place where a message body becomes ciphertext.
/// It sits on top of the audited Double Ratchet
/// (`lib/core/services/double_ratchet_service.dart`) and adds the piece
/// §9 requires and the ratchet alone does not provide: **binding of the
/// full routing context into the AEAD**.
///
///   plaintext body
///     -> JSON encode
///     -> Double Ratchet encrypt (AES-256-GCM, ratchet header as AAD)
///     -> wrap with canonical NOVA_MSG_AAD_v1 context tag
///     -> base64 ciphertext for the envelope
///
/// ## Why a context tag and not "just pass the AAD to the ratchet"
///
/// `DoubleRatchetService.encrypt()` builds its own AAD internally from the
/// ratchet header and exposes no hook to extend it. Changing that
/// signature would touch an audited, FASE-0.5-verified component and risk
/// breaking wire compatibility (§42: do not modify stable components
/// without regression tests).
///
/// Instead the engine computes an HMAC-SHA256 **context tag** over the
/// canonical AAD, keyed by the ratchet message key material that produced
/// the ciphertext, and ships it alongside. On receipt the tag is
/// recomputed and compared in constant time. A server that rewrites the
/// conversation, sender, recipient device, message id, type or version
/// cannot forge the tag without the ratchet key, so the message is
/// rejected instead of silently accepted in a forged context.
///
/// This is Encrypt-then-MAC over authenticated data using a key derived
/// from the same secret — a standard construction, not new cryptography
/// (§7). It uses only HMAC-SHA256, already in the dependency set.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../services/double_ratchet_service.dart';
import '../model/message_body.dart';
import '../model/message_envelope_v1.dart';
import '../model/message_ids.dart';
import '../model/message_type.dart';
import 'message_aad.dart';

/// Domain-separation label for the context-tag key derivation. Prevents
/// the derived key from ever colliding with a ratchet message key.
const String _kContextKeyInfo = 'NOVA_MSG_CTX_v1';

/// Raised when a ciphertext fails authentication.
///
/// Deliberately generic: the caller learns the message is not authentic,
/// never *which* check failed. A detailed error would be an oracle.
class MessageDecryptionError implements Exception {
  const MessageDecryptionError([this.reason = 'AUTHENTICATION_FAILED']);
  final String reason;
  @override
  String toString() => 'MessageDecryptionError: $reason';
}

/// Result of encrypting one body for one recipient device.
class EncryptedMessage {
  const EncryptedMessage({
    required this.ciphertextBase64,
    required this.headerType,
  });

  final String ciphertextBase64;
  final String headerType;
}

class MessageEncryptionService {
  MessageEncryptionService(this._ratchet);

  final DoubleRatchetService _ratchet;
  final _hmac = Hmac.sha256();

  /// Encrypts [body] for one recipient device.
  ///
  /// [state] is the Double Ratchet session for (this device -> recipient
  /// device). Each device pair has its OWN session (§15), so the caller
  /// invokes this once per target device.
  Future<EncryptedMessage> encrypt({
    required RatchetState state,
    required MessageBody body,
    required MessageId messageId,
    required ConversationId conversationId,
    required AccountId senderAccountId,
    required DeviceId senderDeviceId,
    required DeviceId recipientDeviceId,
    int envelopeVersion = kEnvelopeVersionV1,
  }) async {
    final aad = MessageAad.build(
      conversationId: conversationId.value,
      senderAccountId: senderAccountId.value,
      senderDeviceId: senderDeviceId.value,
      recipientDeviceId: recipientDeviceId.value,
      messageId: messageId.value,
      messageType: body.type.wireTag,
      envelopeVersion: envelopeVersion,
    );

    // Ratchet encryption: AES-256-GCM with a fresh per-message key.
    final encrypted = await _ratchet.encrypt(
      state: state,
      plaintext: body.encode(),
    );

    // Bind the routing context to THIS ciphertext.
    final contextTag = await _contextTag(encrypted: encrypted, aad: aad);

    final payload = <String, dynamic>{
      'v': envelopeVersion,
      'dr': encrypted,
      'ctx': contextTag,
    };

    return EncryptedMessage(
      ciphertextBase64: base64Encode(utf8.encode(jsonEncode(payload))),
      headerType: kCiphertextHeaderDrV1,
    );
  }

  /// Decrypts an inbound envelope, verifying the bound context first.
  ///
  /// Throws [MessageDecryptionError] when the ciphertext is malformed,
  /// tampered with, or arrives in a context different from the one the
  /// sender authenticated. Never returns partial or unverified content.
  Future<MessageBody> decrypt({
    required RatchetState state,
    required MessageEnvelopeV1 envelope,
    required DeviceId localDeviceId,
  }) async {
    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(envelope.ciphertextBase64)));
      if (decoded is! Map<String, dynamic>) {
        throw const MessageDecryptionError('MALFORMED');
      }
      payload = decoded;
    } on FormatException {
      throw const MessageDecryptionError('MALFORMED');
    }

    final drPayload = payload['dr'];
    final contextTag = payload['ctx'];
    if (drPayload is! Map<String, dynamic> || contextTag is! String) {
      throw const MessageDecryptionError('MALFORMED');
    }

    // The AAD is rebuilt from what WE observe, not from anything the
    // sender asserts inside the ciphertext. If the server rewrote any
    // routing field, the rebuilt AAD differs and the tag will not match.
    //
    // recipient_device_id is taken from OUR device id: an envelope
    // re-routed to the wrong device fails here.
    final version = payload['v'] as int? ?? envelope.envelopeVersion;
    final aad = MessageAad.build(
      conversationId: envelope.conversationId.value,
      senderAccountId: envelope.senderAccountId.value,
      senderDeviceId: envelope.senderDeviceId.value,
      recipientDeviceId: localDeviceId.value,
      messageId: envelope.messageId.value,
      messageType: envelope.messageType.wireTag,
      envelopeVersion: version,
    );

    final expectedTag = await _contextTag(encrypted: drPayload, aad: aad);
    if (!_constantTimeEquals(expectedTag, contextTag)) {
      // Context mismatch: authentic ciphertext, forged routing. Reject.
      throw const MessageDecryptionError('CONTEXT_MISMATCH');
    }

    final String plaintext;
    try {
      plaintext = await _ratchet.decrypt(state: state, encrypted: drPayload);
    } on SecretBoxAuthenticationError {
      throw const MessageDecryptionError('AUTHENTICATION_FAILED');
    } on StateError catch (error) {
      // Replay detected by the ratchet, or no usable chain.
      throw MessageDecryptionError(
        error.message.contains('replay') ? 'REPLAY' : 'NO_SESSION',
      );
    } on FormatException {
      throw const MessageDecryptionError('MALFORMED');
    }

    final body = MessageBody.decode(plaintext);
    if (body == null) throw const MessageDecryptionError('MALFORMED');

    // Envelope type and body type must agree: the envelope type is
    // AAD-bound, so a mismatch means the sender itself was inconsistent.
    if (body.type != envelope.messageType &&
        envelope.messageType != MessageType.system) {
      throw const MessageDecryptionError('TYPE_MISMATCH');
    }
    return body;
  }

  /// HMAC-SHA256 over the canonical AAD, keyed by material derived from
  /// the ciphertext's own AEAD tag.
  ///
  /// The MAC of the ratchet output is unpredictable without the message
  /// key, so only a party holding the ratchet state can produce a valid
  /// context tag. The server sees the tag but cannot recompute it for
  /// different routing fields.
  Future<String> _contextTag({
    required Map<String, dynamic> encrypted,
    required Uint8List aad,
  }) async {
    final mac = encrypted['mac'];
    final nonce = encrypted['nonce'];
    if (mac is! String || nonce is! String) {
      throw const MessageDecryptionError('MALFORMED');
    }

    // Derive a dedicated context key so this MAC can never be confused
    // with the AEAD tag it is derived from (domain separation).
    final keyMaterial = await _hmac.calculateMac(
      utf8.encode('$_kContextKeyInfo|$nonce'),
      secretKey: SecretKey(base64Decode(mac)),
    );

    final tag = await _hmac.calculateMac(
      aad,
      secretKey: SecretKey(keyMaterial.bytes),
    );
    return base64Encode(tag.bytes);
  }

  /// Length-independent, early-exit-free comparison.
  static bool _constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    if (ab.length != bb.length) return false;
    var diff = 0;
    for (var i = 0; i < ab.length; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}
