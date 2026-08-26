/// Canonical Additional Authenticated Data for NovaApp messages (§9).
///
/// ## The problem this fixes
///
/// The Double Ratchet AAD in `double_ratchet_service.dart` authenticates
/// only the ratchet header:
///
///     ratchet_public_key || message_number || previous_chain_length
///
/// It does NOT authenticate the conversation, the sender, the message id
/// or the protocol version. A malicious (or compromised) server can
/// therefore take a genuine envelope from conversation X and re-route it
/// as conversation Y, or re-attribute it to a different sender. The AEAD
/// tag still verifies — those fields were never covered — so the
/// recipient decrypts an authentic message in a forged context.
///
/// ## The fix
///
/// Every message the engine encrypts binds its full routing context into
/// the AEAD as AAD. Changing ANY bound field makes decryption fail with an
/// authentication error rather than silently succeeding.
///
/// Canonical form (v1), NUL-separated so no field can be smuggled into
/// its neighbour:
///
///     NOVA_MSG_AAD_v1 \0 conversation_id \0 sender_account_id
///                     \0 sender_device_id \0 recipient_device_id
///                     \0 message_id \0 message_type \0 envelope_version
///
/// ## Why NUL and not '|'
///
/// With a printable separator, a field containing that character could
/// shift the boundary between two fields and produce the same byte string
/// from different inputs (canonicalization ambiguity). Ids are UUIDs and
/// cannot contain NUL, and [MessageAad.build] rejects any field that does,
/// so the encoding is injective.
///
/// The AAD is authenticated, NOT encrypted: the server already sees this
/// routing metadata. Binding it costs nothing in privacy and removes the
/// server's ability to lie about it.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Version tag of the canonical AAD. Bump only with a protocol change.
const String kMessageAadVersion = 'NOVA_MSG_AAD_v1';

/// Field separator: a byte that cannot appear inside any bound field.
const int _kSeparator = 0x00;

/// Thrown when a field cannot be canonically encoded.
class MessageAadError implements Exception {
  const MessageAadError(this.message);
  final String message;
  @override
  String toString() => 'MessageAadError: $message';
}

/// Builds the canonical AAD for one message.
abstract final class MessageAad {
  /// Returns the AAD bytes binding the full routing context.
  ///
  /// [recipientDeviceId] is part of the context because the engine
  /// fans out one envelope PER DEVICE (§15): binding it stops a server
  /// from replaying device B1's copy to device B2, which would otherwise
  /// be a valid ciphertext for a session that device does not own.
  ///
  /// Throws [MessageAadError] if any field is empty or contains NUL —
  /// failing closed is mandatory, since a silently malformed AAD would
  /// weaken the binding it exists to provide.
  static Uint8List build({
    required String conversationId,
    required String senderAccountId,
    required String senderDeviceId,
    required String recipientDeviceId,
    required String messageId,
    required String messageType,
    required int envelopeVersion,
  }) {
    final fields = <String>[
      kMessageAadVersion,
      conversationId,
      senderAccountId,
      senderDeviceId,
      recipientDeviceId,
      messageId,
      messageType,
      envelopeVersion.toString(),
    ];

    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      if (field.isEmpty) {
        throw const MessageAadError('AAD field must not be empty');
      }
      final bytes = utf8.encode(field);
      if (bytes.contains(_kSeparator)) {
        // Would make the encoding ambiguous — refuse rather than weaken.
        throw const MessageAadError('AAD field must not contain NUL');
      }
      if (i > 0) builder.addByte(_kSeparator);
      builder.add(bytes);
    }
    return builder.toBytes();
  }

  /// Human-readable rendering of an AAD. Debugging only.
  ///
  /// Safe to log: the AAD holds routing metadata the server already sees.
  /// It contains no key material, no ciphertext and no plaintext.
  static String debugFormat(Uint8List aad) =>
      utf8.decode(aad).replaceAll('\u0000', ' | ');
}
