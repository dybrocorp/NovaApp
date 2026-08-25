/// The ENCRYPTED payload of a message (§5, §6, §8).
///
/// Everything in this file lives INSIDE the ciphertext. The server never
/// sees any of it. That is exactly why fields the server must not learn
/// live here and not in the envelope:
///
///   * the text itself;
///   * which message a reply quotes (§20) — the reply graph is content;
///   * which message a reaction targets and with what emoji (§21);
///   * the decryption key of a media object (§23).
///
/// §5 forbids storing plaintext in the persisted message model: this type
/// is the in-memory/decrypted form, produced on decrypt and consumed by
/// the UI. The stores persist ciphertext only.
library;

import 'dart:convert';

import 'media_reference.dart';
import 'message_ids.dart';
import 'message_type.dart';

/// Decrypted body of a message.
///
/// Extensible by construction (§6): a new message type adds a field or a
/// new body variant; the envelope, transport and crypto are untouched.
class MessageBody {
  const MessageBody({
    required this.type,
    this.text,
    this.media,
    this.replyToMessageId,
    this.reactionEmoji,
    this.reactionTargetMessageId,
    this.editTargetMessageId,
    this.deletionTargetMessageId,
    this.locationLat,
    this.locationLon,
    this.contactCard,
    this.extra,
  });

  final MessageType type;

  /// Text content, when the type carries text (or a media caption).
  final String? text;

  /// Encrypted-object reference for media types (§23).
  final MediaReference? media;

  /// Quoted message (§20). The recipient MUST verify the quoted message
  /// belongs to the same conversation before rendering it — client
  /// metadata is not trusted.
  final MessageId? replyToMessageId;

  /// Reaction payload (§21).
  final String? reactionEmoji;
  final MessageId? reactionTargetMessageId;

  /// Edit payload (§18): the new text plus the message being replaced.
  final MessageId? editTargetMessageId;

  /// Tombstone target for "delete for everyone" (§19).
  final MessageId? deletionTargetMessageId;

  final double? locationLat;
  final double? locationLon;

  /// Shared contact card (name/handle), opaque to the engine.
  final Map<String, dynamic>? contactCard;

  /// Forward-compatibility bucket: fields a NEWER client added that this
  /// build does not know. Preserved verbatim so re-encoding never loses
  /// data.
  final Map<String, dynamic>? extra;

  factory MessageBody.text(String value) =>
      MessageBody(type: MessageType.text, text: value);

  factory MessageBody.reply({required MessageId quoted, required String value}) =>
      MessageBody(type: MessageType.text, text: value, replyToMessageId: quoted);

  factory MessageBody.reaction({required MessageId target, required String emoji}) =>
      MessageBody(
        type: MessageType.reaction,
        reactionTargetMessageId: target,
        reactionEmoji: emoji,
      );

  /// An empty emoji means "remove my reaction" (§21: add/remove).
  factory MessageBody.reactionRemoval({required MessageId target}) =>
      MessageBody(
        type: MessageType.reaction,
        reactionTargetMessageId: target,
        reactionEmoji: '',
      );

  factory MessageBody.edit({required MessageId target, required String value}) =>
      MessageBody(type: MessageType.edit, editTargetMessageId: target, text: value);

  factory MessageBody.deletion({required MessageId target}) =>
      MessageBody(type: MessageType.deletion, deletionTargetMessageId: target);

  factory MessageBody.media({
    required MessageType type,
    required MediaReference reference,
    String? caption,
  }) =>
      MessageBody(type: type, media: reference, text: caption);

  bool get isReactionRemoval =>
      type == MessageType.reaction && (reactionEmoji == null || reactionEmoji!.isEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (extra != null) ...extra!,
        'type': type.wireTag,
        if (text != null) 'text': text,
        if (media != null) 'media': media!.toJson(),
        if (replyToMessageId != null) 'reply_to': replyToMessageId!.value,
        if (reactionEmoji != null) 'reaction_emoji': reactionEmoji,
        if (reactionTargetMessageId != null)
          'reaction_target': reactionTargetMessageId!.value,
        if (editTargetMessageId != null) 'edit_target': editTargetMessageId!.value,
        if (deletionTargetMessageId != null)
          'deletion_target': deletionTargetMessageId!.value,
        if (locationLat != null) 'lat': locationLat,
        if (locationLon != null) 'lon': locationLon,
        if (contactCard != null) 'contact': contactCard,
      };

  String encode() => jsonEncode(toJson());

  /// Parses a decrypted body. Returns null on malformed JSON: a peer
  /// must never be able to crash the client with a bad payload.
  static MessageBody? decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  static MessageBody fromJson(Map<String, dynamic> json) {
    const known = <String>{
      'type', 'text', 'media', 'reply_to', 'reaction_emoji', 'reaction_target',
      'edit_target', 'deletion_target', 'lat', 'lon', 'contact',
    };
    final extra = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!known.contains(entry.key)) extra[entry.key] = entry.value;
    }

    final mediaJson = json['media'];
    return MessageBody(
      type: MessageType.fromWireTag(json['type'] as String?) ?? MessageType.system,
      text: json['text'] as String?,
      media: mediaJson is Map<String, dynamic>
          ? MediaReference.fromJson(mediaJson)
          : null,
      replyToMessageId: MessageId.tryParse(json['reply_to'] as String?),
      reactionEmoji: json['reaction_emoji'] as String?,
      reactionTargetMessageId: MessageId.tryParse(json['reaction_target'] as String?),
      editTargetMessageId: MessageId.tryParse(json['edit_target'] as String?),
      deletionTargetMessageId: MessageId.tryParse(json['deletion_target'] as String?),
      locationLat: (json['lat'] as num?)?.toDouble(),
      locationLon: (json['lon'] as num?)?.toDouble(),
      contactCard: json['contact'] as Map<String, dynamic>?,
      extra: extra.isEmpty ? null : extra,
    );
  }
}
