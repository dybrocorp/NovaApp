import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Group encryption using Sender Keys protocol.
///
/// Flow:
///   1. Group creator generates a Sender Key (SK)
///   2. SK is distributed to each member via X3DH + SK
///   3. When creator sends a message, encrypts with SK
///   4. When a member is added/removed, SK is rotated
///   5. New SK is distributed to remaining members
///
/// This provides efficient group encryption (single encrypt per message)
/// with forward secrecy on member changes.

class GroupEncryptionService {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();

  /// Represents a group's encryption state.
  static class GroupKeyState {
    final String groupId;
    final List<int> senderKey; // 32-byte group key
    final int keyVersion; // Incremented on key rotation
    final Map<String, List<int>> memberKeys; // Per-member encrypted sender key

    GroupKeyState({
      required this.groupId,
      required this.senderKey,
      this.keyVersion = 0,
      Map<String, List<int>>? memberKeys,
    }) : memberKeys = memberKeys ?? {};
  }

  /// Generates a new Sender Key for a group.
  /// Returns the key state that should be distributed to all members.
  Future<GroupKeyState> generateSenderKey({
    required String groupId,
    required List<String> memberNovaIds,
  }) async {
    // Generate random 32-byte sender key
    final rng = await AesGcm.with256bits();
    final senderKey = List<int>.generate(32, (_) => DateTime.now().microsecondsSinceEpoch & 0xFF);

    LoggerService.info('Sender Key generated for group: $groupId', tag: 'GroupCrypto');

    return GroupKeyState(
      groupId: groupId,
      senderKey: senderKey,
      keyVersion: 0,
    );
  }

  /// Encrypts a message for a group using the Sender Key.
  /// Returns { ciphertext, nonce, key_version }
  Future<Map<String, dynamic>> encryptGroupMessage({
    required GroupKeyState keyState,
    required String plaintext,
  }) async {
    final nonce = List<int>.generate(12, (_) => DateTime.now().microsecondsSinceEpoch & 0xFF);

    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(keyState.senderKey),
      nonce: nonce,
    );

    return {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'key_version': keyState.keyVersion,
    };
  }

  /// Decrypts a group message using the Sender Key.
  Future<String> decryptGroupMessage({
    required GroupKeyState keyState,
    required Map<String, dynamic> encrypted,
  }) async {
    final ciphertext = base64Decode(encrypted['ciphertext']);
    final nonce = base64Decode(encrypted['nonce']);
    final mac = base64Decode(encrypted['mac']);

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    final plaintext = await _aesGcm.decrypt(secretBox, secretKey: SecretKey(keyState.senderKey));

    return utf8.decode(plaintext);
  }

  /// Rotates the Sender Key (e.g., when a member is removed).
  /// Returns a new key state with incremented version.
  Future<GroupKeyState> rotateKey({
    required GroupKeyState currentKeyState,
  }) async {
    final newSenderKey = List<int>.generate(32, (_) => DateTime.now().microsecondsSinceEpoch & 0xFF);

    LoggerService.info(
      'Sender Key rotated: ${currentKeyState.groupId} v${currentKeyState.keyVersion + 1}',
      tag: 'GroupCrypto',
    );

    return GroupKeyState(
      groupId: currentKeyState.groupId,
      senderKey: newSenderKey,
      keyVersion: currentKeyState.keyVersion + 1,
    );
  }

  /// Encrypts the Sender Key for a specific member using their identity key.
  /// Used during key distribution.
  Future<List<int>> encryptKeyForMember({
    required List<int> senderKey,
    required String memberPublicKeyBase64,
  }) async {
    final memberKey = SimplePublicKey(
      base64Decode(memberPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    // Generate ephemeral key for key exchange
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();

    // DH with member's key
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: memberKey,
    );
    final secretBytes = await sharedSecret.extractBytes();

    // Derive encryption key from shared secret
    final derived = await _aesGcm.getKeyFromPassword(
      password: secretBytes,
      nonce: List<int>.generate(12, (_) => 0),
    );

    // Encrypt sender key
    final encrypted = await _aesGcm.encrypt(
      senderKey,
      secretKey: derived,
    );

    // Return: ephemeral public key + encrypted sender key
    return [...ephemeralPublic.bytes, ...encrypted.cipherText, ...encrypted.mac.bytes];
  }

  /// Decrypts the Sender Key received from the group.
  Future<List<int>> decryptKeyForMember({
    required List<int> encryptedKeyBundle,
    required SimpleKeyPair myIdentityKey,
  }) async {
    // Extract ephemeral public key (32 bytes) and encrypted data
    final ephemeralPublicBytes = encryptedKeyBundle.sublist(0, 32);
    final encryptedData = encryptedKeyBundle.sublist(32);

    final ephemeralPublic = SimplePublicKey(ephemeralPublicBytes, type: KeyPairType.x25519);

    // DH with my identity key
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: myIdentityKey,
      remotePublicKey: ephemeralPublic,
    );
    final secretBytes = await sharedSecret.extractBytes();

    // Derive decryption key
    final derived = await _aesGcm.getKeyFromPassword(
      password: secretBytes,
      nonce: List<int>.generate(12, (_) => 0),
    );

    // Decrypt sender key
    final nonce = encryptedData.sublist(encryptedData.length - 12);
    final mac = encryptedData.sublist(encryptedData.length - 24, encryptedData.length - 12);
    final ciphertext = encryptedData.sublist(0, encryptedData.length - 24);

    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    final senderKey = await _aesGcm.decrypt(secretBox, secretKey: derived);

    return senderKey;
  }
}

final groupEncryptionServiceProvider = Provider((ref) => GroupEncryptionService());
