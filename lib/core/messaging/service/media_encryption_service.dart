/// Encrypted media objects (§23, §24, §25, §26).
///
/// §23 forbids sending files through Socket.IO and forbids plaintext ever
/// reaching the server. The pipeline:
///
///   file bytes
///     -> fresh random AES-256-GCM key, ONE PER OBJECT
///     -> encrypt locally
///     -> upload the ENCRYPTED blob to object storage
///     -> MediaReference {object_id, key, nonce, sha256} goes inside the
///        message ciphertext
///     -> recipient downloads, verifies the digest, decrypts locally
///
/// Two properties make this safe:
///
///  * The key travels inside the E2EE body, never in envelope metadata,
///    so the storage backend holds bytes it cannot read.
///  * The key is per object, not the ratchet key. A leaked media key
///    exposes exactly one object and never the conversation.
///
/// The digest is over the CIPHERTEXT so a tampered or truncated download
/// is detected before any decryption work (and before AEAD failure noise).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../model/media_reference.dart';
import '../model/message_type.dart';

/// Upload/download of opaque encrypted blobs.
///
/// The implementation must NOT use permanent public URLs (§24): access is
/// authorized and links expire.
abstract interface class EncryptedObjectStorage {
  /// Uploads ciphertext under [objectId]. Returns false on failure.
  Future<bool> upload({
    required String objectId,
    required Uint8List ciphertext,
  });

  /// Downloads ciphertext, or null when missing/unauthorized.
  Future<Uint8List?> download(String objectId);

  Future<void> delete(String objectId);
}

class MediaEncryptionError implements Exception {
  const MediaEncryptionError(this.reason);
  final String reason;
  @override
  String toString() => 'MediaEncryptionError: $reason';
}

/// Locally prepared media, ready to be referenced by a message.
class PreparedMedia {
  const PreparedMedia({required this.reference, required this.ciphertext});

  final MediaReference reference;
  final Uint8List ciphertext;
}

class MediaEncryptionService {
  MediaEncryptionService(this._storage, {Random? random})
      : _random = random ?? Random.secure();

  final EncryptedObjectStorage _storage;
  final Random _random;
  final _aesGcm = AesGcm.with256bits();
  final _sha256 = Sha256();

  /// Encrypts [bytes] and uploads the blob.
  ///
  /// [thumbnailBytes] must ALREADY be a locally generated thumbnail
  /// (§25): the server cannot make one, since it never sees the image.
  /// It is encrypted with the same object key and embedded in the
  /// reference so a preview needs no extra download.
  Future<MediaReference> encryptAndUpload({
    required Uint8List bytes,
    required String mimeType,
    required MessageType messageType,
    String? fileName,
    int? durationMs,
    int? width,
    int? height,
    Uint8List? thumbnailBytes,
    List<int>? waveform,
  }) async {
    if (!messageType.isMedia) {
      throw const MediaEncryptionError('NOT_A_MEDIA_TYPE');
    }

    final objectId = _randomObjectId();
    final secretKey = await _aesGcm.newSecretKey();
    final keyBytes = await secretKey.extractBytes();
    final nonce = _aesGcm.newNonce();

    final box = await _aesGcm.encrypt(bytes, secretKey: secretKey, nonce: nonce);
    // Concatenated so the blob is self-contained: ciphertext || tag.
    final ciphertext = Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);

    final digest = await _sha256.hash(ciphertext);

    String? encryptedThumb;
    if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
      // Distinct nonce: reusing a nonce with the same key would be a
      // catastrophic AES-GCM failure.
      final thumbNonce = _aesGcm.newNonce();
      final thumbBox =
          await _aesGcm.encrypt(thumbnailBytes, secretKey: secretKey, nonce: thumbNonce);
      encryptedThumb = base64Encode(<int>[
        ...thumbNonce,
        ...thumbBox.cipherText,
        ...thumbBox.mac.bytes,
      ]);
    }

    final uploaded = await _storage.upload(objectId: objectId, ciphertext: ciphertext);
    if (!uploaded) throw const MediaEncryptionError('UPLOAD_FAILED');

    return MediaReference(
      objectId: objectId,
      keyBase64: base64Encode(keyBytes),
      nonceBase64: base64Encode(nonce),
      sha256Base64: base64Encode(digest.bytes),
      sizeBytes: bytes.length,
      mimeType: mimeType,
      fileName: fileName,
      durationMs: durationMs,
      width: width,
      height: height,
      thumbnailBase64: encryptedThumb,
      waveform: waveform,
    );
  }

  /// Downloads and decrypts an object referenced by a message.
  ///
  /// Verifies the ciphertext digest BEFORE decrypting: a truncated or
  /// substituted blob is rejected early, and the check is independent of
  /// the AEAD tag.
  Future<Uint8List> downloadAndDecrypt(MediaReference reference) async {
    final ciphertext = await _storage.download(reference.objectId);
    if (ciphertext == null) throw const MediaEncryptionError('OBJECT_NOT_FOUND');

    final digest = await _sha256.hash(ciphertext);
    if (base64Encode(digest.bytes) != reference.sha256Base64) {
      throw const MediaEncryptionError('DIGEST_MISMATCH');
    }

    return _openBox(
      payload: ciphertext,
      keyBase64: reference.keyBase64,
      nonce: base64Decode(reference.nonceBase64),
    );
  }

  /// Decrypts the embedded thumbnail (§25). Null when absent.
  Future<Uint8List?> decryptThumbnail(MediaReference reference) async {
    final thumb = reference.thumbnailBase64;
    if (thumb == null || thumb.isEmpty) return null;

    final raw = base64Decode(thumb);
    final nonceLength = _aesGcm.nonceLength;
    if (raw.length <= nonceLength + 16) return null;

    return _openBox(
      payload: Uint8List.fromList(raw.sublist(nonceLength)),
      keyBase64: reference.keyBase64,
      nonce: raw.sublist(0, nonceLength),
    );
  }

  /// Splits `ciphertext || tag` and opens the AEAD box.
  Future<Uint8List> _openBox({
    required Uint8List payload,
    required String keyBase64,
    required List<int> nonce,
  }) async {
    const macLength = 16; // AES-GCM tag
    if (payload.length < macLength) {
      throw const MediaEncryptionError('MALFORMED_OBJECT');
    }
    final body = payload.sublist(0, payload.length - macLength);
    final mac = payload.sublist(payload.length - macLength);

    try {
      final plaintext = await _aesGcm.decrypt(
        SecretBox(body, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(base64Decode(keyBase64)),
      );
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      throw const MediaEncryptionError('AUTHENTICATION_FAILED');
    }
  }

  /// 256 bits of CSPRNG output. Unrelated to the conversation or sender,
  /// so the storage path leaks nothing about who is talking (§24).
  String _randomObjectId() {
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
