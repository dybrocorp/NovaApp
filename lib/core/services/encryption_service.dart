import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class EncryptionService {
  final _storage = const FlutterSecureStorage();
  final _algorithm = X25519();
  final _cipher = Chacha20.poly1305Aead();

  // Generate and save a new key pair if it doesn't exist
  Future<void> ensureKeyPair() async {
    final existing = await _storage.read(key: 'nova_private_key');
    if (existing == null) {
      final keyPair = await _algorithm.newKeyPair();
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
      final publicKey = await keyPair.extractPublicKey();
      
      await _storage.write(key: 'nova_private_key', value: base64Encode(privateKeyBytes));
      await _storage.write(key: 'nova_public_key', value: base64Encode(publicKey.bytes));
    }
  }

  Future<String?> getPublicKey() async {
    return await _storage.read(key: 'nova_public_key');
  }

  // Encrypt a message for a specific recipient
  Future<String> encryptMessage(String plainText, String recipientPublicKeyBase64) async {
    final myPrivateKeyBytes = base64Decode(await _storage.read(key: 'nova_private_key') ?? '');
    final myKeyPair = await _algorithm.newKeyPairFromSeed(myPrivateKeyBytes);
    
    final recipientPubKey = SimplePublicKey(
      base64Decode(recipientPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    // Key Exchange (Diffie-Hellman)
    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: recipientPubKey,
    );

    // Encrypt with Chacha20
    final nonce = _cipher.newNonce();
    final secretBox = await _cipher.encrypt(
      utf8.encode(plainText),
      secretKey: sharedSecret,
      nonce: nonce,
    );

    // Result: nonce + chipertext
    return base64Encode(secretBox.concatenation());
  }

  // Decrypt a message from a specific sender
  Future<String> decryptMessage(String encryptedData, String senderPublicKeyBase64) async {
    final myPrivateKeyBytes = base64Decode(await _storage.read(key: 'nova_private_key') ?? '');
    final myKeyPair = await _algorithm.newKeyPairFromSeed(myPrivateKeyBytes);

    final senderPubKey = SimplePublicKey(
      base64Decode(senderPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: senderPubKey,
    );

    final data = base64Decode(encryptedData);
    final secretBox = SecretBox.fromConcatenation(
      data,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );

    final decryptedBytes = await _cipher.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    return utf8.decode(decryptedBytes);
  }
}

final encryptionServiceProvider = Provider((ref) => EncryptionService());
