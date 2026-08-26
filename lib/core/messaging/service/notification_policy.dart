/// Privacy-preserving push notification content (§27, §28).
///
/// §27 is explicit: a notification must NEVER reveal plaintext.
///
///   Wrong:  "Juan: Hola, ¿cómo estás?"
///   Right:  "Nuevo mensaje en NovaApp"
///
/// This matters more than it looks. Push notifications travel through
/// FCM/APNs — third-party infrastructure outside the E2EE boundary — and
/// render on a LOCKED screen. Putting decrypted text there would undo the
/// end-to-end guarantee at the last step, in the most publicly visible
/// place.
///
/// The server cannot leak content even if it wanted to: it only ever
/// holds ciphertext, so a push it originates carries no body. The risk is
/// entirely client-side, when the app decrypts and then raises a LOCAL
/// notification — which is exactly what `notification_service.dart` does
/// today (it passes the decrypted text as `body`). This policy is the
/// guard that must sit in front of it.
library;

/// How much a notification may reveal. User-configurable (§28), defaulting
/// to the most private option that is still useful.
enum NotificationPreviewLevel {
  /// "Nuevo mensaje" — no sender, no content. Safest.
  none,

  /// "Mensaje de Ana" — sender only, still no content. DEFAULT.
  senderOnly,

  /// Sender plus content. Opt-in only, and never on a locked screen.
  senderAndContent,
}

/// The rendered, privacy-filtered notification.
class NotificationContent {
  const NotificationContent({
    required this.title,
    required this.body,
    this.conversationId,
  });

  final String title;
  final String body;

  /// Deep-link target. An opaque id — safe, it reveals no content.
  final String? conversationId;
}

abstract final class NotificationPolicy {
  static const String appName = 'NovaApp';

  /// Builds notification content honouring [level] and the lock state.
  ///
  /// [messagePreview] is accepted but is only ever used at
  /// `senderAndContent` AND while unlocked. Passing decrypted text here
  /// is safe by construction: the function decides what escapes.
  static NotificationContent build({
    required NotificationPreviewLevel level,
    String? senderDisplayName,
    String? messagePreview,
    String? conversationId,
    bool deviceLocked = false,
  }) {
    // On a locked screen the preview is forced down a level: content on
    // a lock screen is visible to anyone holding the phone.
    final effective = deviceLocked && level == NotificationPreviewLevel.senderAndContent
        ? NotificationPreviewLevel.senderOnly
        : level;

    switch (effective) {
      case NotificationPreviewLevel.none:
        return NotificationContent(
          title: appName,
          body: 'Nuevo mensaje',
          conversationId: conversationId,
        );

      case NotificationPreviewLevel.senderOnly:
        final sender = _sanitize(senderDisplayName);
        return NotificationContent(
          title: appName,
          body: sender == null ? 'Nuevo mensaje' : 'Mensaje de $sender',
          conversationId: conversationId,
        );

      case NotificationPreviewLevel.senderAndContent:
        final sender = _sanitize(senderDisplayName) ?? appName;
        final preview = _truncate(_sanitize(messagePreview));
        return NotificationContent(
          title: sender,
          body: preview ?? 'Nuevo mensaje',
          conversationId: conversationId,
        );
    }
  }

  /// Content for a notification raised from a push the SERVER sent.
  ///
  /// The server holds only ciphertext, so this can never contain content.
  /// Kept as a separate entry point so no future refactor can accidentally
  /// route decrypted text through the server-side path.
  static NotificationContent serverPush({String? conversationId}) =>
      NotificationContent(
        title: appName,
        body: 'Nuevo mensaje',
        conversationId: conversationId,
      );

  static String? _sanitize(String? value) {
    if (value == null) return null;
    // Strip newlines/control characters: a crafted display name could
    // otherwise forge extra lines in the notification shade.
    final cleaned = value.replaceAll(RegExp(r'[\r\n\t\u0000-\u001F]'), ' ').trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  static String? _truncate(String? value, {int maxLength = 120}) {
    if (value == null) return null;
    if (value.length <= maxLength) return value;
    return '${value.substring(0, maxLength - 1)}…';
  }
}
