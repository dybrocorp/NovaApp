/// Reference to an encrypted media object (§23, §24, §25, §26).
///
/// Large files never travel through Socket.IO (§23). Instead:
///
///   plaintext file
///     -> AES-256-GCM with a FRESH random key, per object
///     -> encrypted blob uploaded to object storage
///     -> this reference travels INSIDE the encrypted message body
///     -> recipient downloads the blob, verifies the digest, decrypts
///
/// The critical property: the decryption key lives in this reference,
/// which is itself inside the message ciphertext. The server stores the
/// blob and never holds the key, so it cannot read the media (§23:
/// "never plaintext file -> server").
///
/// A per-object key (not the ratchet message key) means a leaked media
/// key exposes exactly one object and never the conversation.
library;

import 'dart:convert';

/// Cipher used for media objects. AES-256-GCM matches the primitive
/// already used by the Double Ratchet (§7: do not invent crypto).
const String kMediaCipherAesGcm = 'aes-256-gcm';

class MediaReference {
  const MediaReference({
    required this.objectId,
    required this.keyBase64,
    required this.nonceBase64,
    required this.sha256Base64,
    required this.sizeBytes,
    required this.mimeType,
    this.cipher = kMediaCipherAesGcm,
    this.fileName,
    this.durationMs,
    this.width,
    this.height,
    this.thumbnailBase64,
    this.waveform,
  });

  /// Random storage id. Unrelated to the conversation or the sender, so
  /// the object path leaks nothing (§24).
  final String objectId;

  /// Per-object AES-256-GCM key, base64. Secret: only ever inside the
  /// encrypted body — never in envelope metadata, never logged.
  final String keyBase64;

  final String nonceBase64;

  /// Digest of the CIPHERTEXT. Lets the recipient detect a tampered or
  /// truncated download before spending CPU on decryption.
  final String sha256Base64;

  final int sizeBytes;
  final String mimeType;
  final String cipher;
  final String? fileName;

  /// Duration for audio/video and voice notes (§26).
  final int? durationMs;

  final int? width;
  final int? height;

  /// Thumbnail generated LOCALLY before encryption (§25). The server
  /// cannot produce one: it never sees the plaintext image.
  final String? thumbnailBase64;

  /// Amplitude samples for a voice-note waveform, computed on-device
  /// before encryption (§26) so no server-side audio processing is
  /// needed.
  final List<int>? waveform;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'object_id': objectId,
        'key': keyBase64,
        'nonce': nonceBase64,
        'sha256': sha256Base64,
        'size': sizeBytes,
        'mime': mimeType,
        'cipher': cipher,
        if (fileName != null) 'name': fileName,
        if (durationMs != null) 'duration_ms': durationMs,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (thumbnailBase64 != null) 'thumb': thumbnailBase64,
        if (waveform != null) 'waveform': waveform,
      };

  static MediaReference? fromJson(Map<String, dynamic> json) {
    final objectId = json['object_id'] as String?;
    final key = json['key'] as String?;
    final nonce = json['nonce'] as String?;
    final digest = json['sha256'] as String?;
    if (objectId == null || key == null || nonce == null || digest == null) {
      return null;
    }
    return MediaReference(
      objectId: objectId,
      keyBase64: key,
      nonceBase64: nonce,
      sha256Base64: digest,
      sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: json['mime'] as String? ?? 'application/octet-stream',
      cipher: json['cipher'] as String? ?? kMediaCipherAesGcm,
      fileName: json['name'] as String?,
      durationMs: (json['duration_ms'] as num?)?.toInt(),
      width: (json['w'] as num?)?.toInt(),
      height: (json['h'] as num?)?.toInt(),
      thumbnailBase64: json['thumb'] as String?,
      waveform: (json['waveform'] as List?)?.map((e) => (e as num).toInt()).toList(),
    );
  }

  /// Redacted rendering. `toString` must never expose the key, because a
  /// stray log line would hand over the object.
  @override
  String toString() =>
      'MediaReference(objectId: $objectId, mime: $mimeType, size: $sizeBytes, key: [REDACTED])';

  String encode() => jsonEncode(toJson());
}
