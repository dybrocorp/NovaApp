/// Message content types (§6).
///
/// The engine is extensible BY DESIGN: the transport, the envelope and the
/// crypto never branch on the type. A new type is a new wire tag plus a
/// client-side body parser — `Message` itself is never rewritten (§6).
///
/// The type travels in two places:
///   * inside the AAD, so the server cannot rewrite it silently (§9);
///   * inside the encrypted body, which is where the recipient reads it.
/// The server sees only the opaque ciphertext plus routing metadata.
library;

enum MessageType {
  text('text'),
  image('image'),
  video('video'),
  audio('audio'),
  voiceNote('voice_note'),
  document('document'),
  file('file'),
  contact('contact'),
  location('location'),

  /// Server/protocol notice rendered in-line (e.g. "device added").
  system('system'),

  /// A reply is a normal message carrying `reply_to_message_id` (§20);
  /// this tag exists for payloads that are ONLY a quote.
  reply('reply'),

  /// Reaction add/remove travels as its own event type (§21).
  reaction('reaction'),

  /// Edit of an earlier message (§18) — never mutates the original.
  edit('edit'),

  /// Tombstone for "delete for everyone" (§19).
  deletion('deletion');

  const MessageType(this.wireTag);

  /// Stable string used on the wire and inside the AAD. Never rename:
  /// a rename would break AAD verification for messages already sent.
  final String wireTag;

  static MessageType? fromWireTag(String? tag) {
    if (tag == null) return null;
    for (final type in MessageType.values) {
      if (type.wireTag == tag) return type;
    }
    // Unknown type: an older client meeting a newer one. The caller
    // decides (usually: show "unsupported message"), never crash.
    return null;
  }

  /// True when the body references an encrypted object in storage (§23).
  bool get isMedia => const {
        MessageType.image,
        MessageType.video,
        MessageType.audio,
        MessageType.voiceNote,
        MessageType.document,
        MessageType.file,
      }.contains(this);

  /// True when this type mutates the state of an earlier message rather
  /// than adding a new item to the timeline.
  bool get isMutation => const {
        MessageType.edit,
        MessageType.deletion,
        MessageType.reaction,
      }.contains(this);
}
