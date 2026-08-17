import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'logger_service.dart';

class EncryptionService {
  final _storage = const FlutterSecureStorage();
  final _x25519 = X25519();
  final _algorithm = Chacha20.poly1305Aead();
  
  SimpleKeyPair? _myKeyPair;
  bool get isInitialized => _myKeyPair != null;

  // Generate and save a new key pair if it doesn't exist
  Future<void> ensureKeyPair() async {
    try {
      final existing = await _storage.read(key: 'nova_private_key');
      if (existing == null) {
        _myKeyPair = await _x25519.newKeyPair();
        final privateKeyBytes = await _myKeyPair!.extractPrivateKeyBytes();
        final publicKey = await _myKeyPair!.extractPublicKey();
        
        await _storage.write(key: 'nova_private_key', value: base64Encode(privateKeyBytes));
        await _storage.write(key: 'nova_public_key', value: base64Encode(publicKey.bytes));
      } else {
        // Load existing key pair
        await initFromPrivateBase64(existing);
      }
    } catch (e) {
      LoggerService.warning('Error reading encryption keys, regenerating', error: e, tag: 'Encryption');
      await _storage.delete(key: 'nova_private_key');
      await _storage.delete(key: 'nova_public_key');
      
      _myKeyPair = await _x25519.newKeyPair();
      final privateKeyBytes = await _myKeyPair!.extractPrivateKeyBytes();
      final publicKey = await _myKeyPair!.extractPublicKey();
      
      await _storage.write(key: 'nova_private_key', value: base64Encode(privateKeyBytes));
      await _storage.write(key: 'nova_public_key', value: base64Encode(publicKey.bytes));
    }
  }

  /// Inicializa el par de claves desde un secreto privado guardado (base64).
  Future<void> initFromPrivateBase64(String privateKeyBase64) async {
    final privateKeyBytes = base64Decode(privateKeyBase64);
    _myKeyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
  }

  Future<String?> getPublicKey() async {
    if (_myKeyPair != null) {
      return base64Encode((await _myKeyPair!.extractPublicKey()).bytes);
    }
    return await _storage.read(key: 'nova_public_key');
  }

  /// Deriva el secreto compartido usando tu clave privada y la clave pública del otro usuario.
  Future<SecretKey> computeSharedSecret(SimplePublicKey otherPublicKey) async {
    if (_myKeyPair == null) {
      await ensureKeyPair();
    }
    return await _x25519.sharedSecretKey(
      keyPair: _myKeyPair!,
      remotePublicKey: otherPublicKey,
    );
  }

  /// Helper para convertir un string base64 en un objeto SimplePublicKey.
  SimplePublicKey? importPublicKeyFromBase64(String base64Str) {
    try {
      return SimplePublicKey(
        base64Decode(base64Str.trim()),
        type: KeyPairType.x25519,
      );
    } catch (e) {
      LoggerService.error('Error importing public key', error: e, tag: 'Encryption');
      return null;
    }
  }

  /// Encripta un mensaje usando el secreto compartido generado, garantizando Forward Secrecy.
  Future<Map<String, dynamic>> encryptMessage(String text, SecretKey sharedSecret) async {
    final clearTextBytes = utf8.encode(text);
    final secretBox = await _algorithm.encrypt(
      clearTextBytes,
      secretKey: sharedSecret,
    );
    
    final eContent = base64Encode(secretBox.cipherText);
    final nContent = base64Encode(secretBox.nonce);
    final mContent = base64Encode(secretBox.mac.bytes);
    
    LoggerService.trace('Encrypted Len: ${eContent.length}, Nonce: ${nContent.length}, Mac: ${mContent.length}', tag: 'Encryption');

    return {
      'encrypted_content': eContent,
      'nonce': nContent,
      'mac': mContent,
    };
  }

  /// Encripta un mensaje para un destinatario específico (compatibilidad con código existente)
  Future<String> encryptMessageForRecipient(String plainText, String recipientPublicKeyBase64) async {
    final privateKeyBase64 = await _storage.read(key: 'nova_private_key');
    if (privateKeyBase64 == null || privateKeyBase64.isEmpty) {
      LoggerService.error('No private key found, cannot encrypt', tag: 'Encryption');
      return plainText;
    }
    final myPrivateKeyBytes = base64Decode(privateKeyBase64);
    final myKeyPair = await _x25519.newKeyPairFromSeed(myPrivateKeyBytes);
    
    final recipientPubKey = SimplePublicKey(
      base64Decode(recipientPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    // Key Exchange (Diffie-Hellman)
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: recipientPubKey,
    );

    // Encrypt with Chacha20
    final nonce = _algorithm.newNonce();
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plainText),
      secretKey: sharedSecret,
      nonce: nonce,
    );

    // Result: nonce + chipertext
    return base64Encode(secretBox.concatenation());
  }

  /// Desencripta un cipherText usando el secreto local
  Future<String> decryptMessage(
    String cipherTextBase64, 
    String nonceBase64, 
    String macBase64, 
    SecretKey sharedSecret
  ) async {
    try {
      if (cipherTextBase64.isEmpty || nonceBase64.isEmpty || macBase64.isEmpty) {
        return '[Mensaje vacío o corrupto]';
      }

      final secretBox = SecretBox(
        base64Decode(cipherTextBase64.trim()),
        nonce: base64Decode(nonceBase64.trim()),
        mac: Mac(base64Decode(macBase64.trim())),
      );

      final clearTextBytes = await _algorithm.decrypt(
        secretBox,
        secretKey: sharedSecret,
      );

      return utf8.decode(clearTextBytes);
    } catch (e) {
      LoggerService.error('Error decrypting message', error: e, tag: 'Encryption');
      return 'Error de cifrado ($e)';
    }
  }

  /// Desencripta un mensaje de un remitente específico (compatibilidad con código existente)
  Future<String> decryptMessageFromSender(String encryptedData, String senderPublicKeyBase64) async {
    final privateKeyBase64 = await _storage.read(key: 'nova_private_key');
    if (privateKeyBase64 == null || privateKeyBase64.isEmpty) {
      LoggerService.error('No private key found, cannot decrypt', tag: 'Encryption');
      return '[Error de cifrado]';
    }
    final myPrivateKeyBytes = base64Decode(privateKeyBase64);
    final myKeyPair = await _x25519.newKeyPairFromSeed(myPrivateKeyBytes);

    final senderPubKey = SimplePublicKey(
      base64Decode(senderPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: senderPubKey,
    );

    final data = base64Decode(encryptedData);
    final secretBox = SecretBox.fromConcatenation(
      data,
      nonceLength: _algorithm.nonceLength,
      macLength: _algorithm.macAlgorithm.macLength,
    );

    final decryptedBytes = await _algorithm.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    return utf8.decode(decryptedBytes);
  }
}

final encryptionServiceProvider = Provider((ref) => EncryptionService());
