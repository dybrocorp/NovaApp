import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/constants.dart';
import 'logger_service.dart';

class EncryptionService {
  final _storage = const FlutterSecureStorage();
  final _x25519 = X25519();
  final _algorithm = Chacha20.poly1305Aead();

  SimpleKeyPair? _myKeyPair;
  bool get isInitialized => _myKeyPair != null;

  // ===== KEY MANAGEMENT =====

  Future<void> ensureKeyPair() async {
    try {
      final existing = await _storage.read(key: AppConstants.keyPrivateKey);
      if (existing != null) {
        await _initFromPrivateBase64(existing);
        return;
      }
    } catch (e) {
      LoggerService.warning('Error reading keys, regenerating', error: e, tag: 'Crypto');
      await _storage.delete(key: AppConstants.keyPrivateKey);
      await _storage.delete(key: AppConstants.keyPublicKey);
    }
    await _generateAndStoreKeyPair();
  }

  Future<void> _generateAndStoreKeyPair() async {
    _myKeyPair = await _x25519.newKeyPair();
    final privBytes = await _myKeyPair!.extractPrivateKeyBytes();
    final pubKey = await _myKeyPair!.extractPublicKey();

    await _storage.write(key: AppConstants.keyPrivateKey, value: base64Encode(privBytes));
    await _storage.write(key: AppConstants.keyPublicKey, value: base64Encode(pubKey.bytes));
  }

  Future<void> _initFromPrivateBase64(String privateKeyBase64) async {
    final bytes = base64Decode(privateKeyBase64);
    _myKeyPair = await _x25519.newKeyPairFromSeed(bytes);
  }

  Future<String?> getPublicKey() async {
    if (_myKeyPair != null) {
      return base64Encode((await _myKeyPair!.extractPublicKey()).bytes);
    }
    return await _storage.read(key: AppConstants.keyPublicKey);
  }

  // ===== SHARED SECRET =====

  Future<SecretKey> computeSharedSecret(SimplePublicKey otherPublicKey) async {
    if (_myKeyPair == null) await ensureKeyPair();
    return await _x25519.sharedSecretKey(
      keyPair: _myKeyPair!,
      remotePublicKey: otherPublicKey,
    );
  }

  SimplePublicKey? importPublicKeyFromBase64(String base64Str) {
    try {
      return SimplePublicKey(base64Decode(base64Str.trim()), type: KeyPairType.x25519);
    } catch (e) {
      LoggerService.error('Error importing public key', error: e, tag: 'Crypto');
      return null;
    }
  }

  // ===== UNIFIED ENCRYPTION API =====
  //
  // Format: base64(nonce || ciphertext || mac)
  // This is the single API for all message encryption/decryption.

  /// Encrypts [plainText] for [recipientPublicKeyBase64] using X25519 DH + ChaCha20-Poly1305.
  /// Returns a single base64 string containing nonce + ciphertext + mac.
  Future<String> encryptForRecipient(String plainText, String recipientPublicKeyBase64) async {
    if (_myKeyPair == null) {
      await ensureKeyPair();
    }
    if (_myKeyPair == null) {
      throw StateError('No key pair available — cannot encrypt');
    }

    final recipientPubKey = importPublicKeyFromBase64(recipientPublicKeyBase64);
    if (recipientPubKey == null) {
      throw ArgumentError('Invalid recipient public key');
    }

    final sharedSecret = await computeSharedSecret(recipientPubKey);
    final nonce = _algorithm.newNonce();
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plainText),
      secretKey: sharedSecret,
      nonce: nonce,
    );

    return base64Encode(secretBox.concatenation());
  }

  /// Decrypts [encryptedBase64] from [senderPublicKeyBase64] using X25519 DH + ChaCha20-Poly1305.
  Future<String> decryptFromSender(String encryptedBase64, String senderPublicKeyBase64) async {
    if (_myKeyPair == null) {
      await ensureKeyPair();
    }
    if (_myKeyPair == null) {
      throw StateError('No key pair available — cannot decrypt');
    }

    final senderPubKey = importPublicKeyFromBase64(senderPublicKeyBase64);
    if (senderPubKey == null) {
      throw ArgumentError('Invalid sender public key');
    }

    final sharedSecret = await computeSharedSecret(senderPubKey);
    final data = base64Decode(encryptedBase64);
    final secretBox = SecretBox.fromConcatenation(
      data,
      nonceLength: _algorithm.nonceLength,
      macLength: _algorithm.macAlgorithm.macLength,
    );

    final decrypted = await _algorithm.decrypt(secretBox, secretKey: sharedSecret);
    return utf8.decode(decrypted);
  }

  // ===== LEGACY API (kept for backward compatibility, delegates to unified API) =====

  @Deprecated('Use encryptForRecipient instead')
  Future<String> encryptMessageForRecipient(String plainText, String recipientPublicKeyBase64) =>
      encryptForRecipient(plainText, recipientPublicKeyBase64);

  @Deprecated('Use decryptFromSender instead')
  Future<String> decryptMessageFromSender(String encryptedData, String senderPublicKeyBase64) =>
      decryptFromSender(encryptedData, senderPublicKeyBase64);

  /// Encrypts using a pre-computed shared secret (for when DH is done externally).
  Future<Map<String, dynamic>> encryptWithSecret(String text, SecretKey sharedSecret) async {
    final secretBox = await _algorithm.encrypt(utf8.encode(text), secretKey: sharedSecret);
    return {
      'encrypted_content': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    };
  }

  /// Decrypts using a pre-computed shared secret (for when DH is done externally).
  Future<String> decryptWithSecret(
    String cipherTextBase64,
    String nonceBase64,
    String macBase64,
    SecretKey sharedSecret,
  ) async {
    if (cipherTextBase64.isEmpty || nonceBase64.isEmpty || macBase64.isEmpty) {
      return '[Mensaje vacio o corrupto]';
    }
    final secretBox = SecretBox(
      base64Decode(cipherTextBase64.trim()),
      nonce: base64Decode(nonceBase64.trim()),
      mac: Mac(base64Decode(macBase64.trim())),
    );
    final clearBytes = await _algorithm.decrypt(secretBox, secretKey: sharedSecret);
    return utf8.decode(clearBytes);
  }
}

final encryptionServiceProvider = Provider((ref) => EncryptionService());
