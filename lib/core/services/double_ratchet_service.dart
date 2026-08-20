import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Double Ratchet Protocol implementation.
///
/// Provides ongoing forward secrecy after X3DH key establishment.
/// Each message is encrypted with a unique key derived from the ratchet.
///
/// Ratchet steps:
///   - Sending chain: advances with each sent message
///   - Receiving chain: advances with each received message
///   - DH ratchet: new DH exchange when receiving a new ratchet public key
///
/// State is persisted per-conversation for crash recovery.

class DoubleRatchetService {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _hkdf = Hkdf.hmacSha256(outputLength: 32, nonce: Uint8List(32));

  /// Ratchet state for a single conversation.
  static class RatchetState {
    // Root key (32 bytes)
    List<int> rootKey;
    // Sending chain key
    List<int>? sendingChainKey;
    // Receiving chain key
    List<int>? receivingChainKey;
    // My current ratchet public key (X25519)
    SimpleKeyPair? myRatchetKeyPair;
    // Their current ratchet public key
    SimplePublicKey? theirRatchetPublicKey;
    // Message counters
    int sendCount;
    int receiveCount;
    int previousSendCount;
    // Skipped message keys (for out-of-order messages)
    Map<String, List<int>> skippedMessageKeys;

    RatchetState({
      required this.rootKey,
      this.sendingChainKey,
      this.receivingChainKey,
      this.myRatchetKeyPair,
      this.theirRatchetPublicKey,
      this.sendCount = 0,
      this.receiveCount = 0,
      this.previousSendCount = 0,
      Map<String, List<int>>? skippedMessageKeys,
    }) : skippedMessageKeys = skippedMessageKeys ?? {};

    /// Serializes state for persistence.
    Map<String, dynamic> toJson() {
      return {
        'root_key': base64Encode(rootKey),
        'sending_chain_key': sendingChainKey != null ? base64Encode(sendingChainKey!) : null,
        'receiving_chain_key': receivingChainKey != null ? base64Encode(receivingChainKey!) : null,
        'their_ratchet_public_key': theirRatchetPublicKey != null
            ? base64Encode(theirRatchetPublicKey!.bytes)
            : null,
        'send_count': sendCount,
        'receive_count': receiveCount,
        'previous_send_count': previousSendCount,
        'skipped_keys': skippedMessageKeys.map(
          (k, v) => MapEntry(k, v.map((b) => base64Encode(b)).toList()),
        ),
      };
    }

    /// Deserializes state from persistence.
    factory RatchetState.fromJson(Map<String, dynamic> json) {
      return RatchetState(
        rootKey: base64Decode(json['root_key']),
        sendingChainKey: json['sending_chain_key'] != null
            ? base64Decode(json['sending_chain_key'])
            : null,
        receivingChainKey: json['receiving_chain_key'] != null
            ? base64Decode(json['receiving_chain_key'])
            : null,
        theirRatchetPublicKey: json['their_ratchet_public_key'] != null
            ? SimplePublicKey(base64Decode(json['their_ratchet_public_key']),
                type: KeyPairType.x25519)
            : null,
        sendCount: json['send_count'] ?? 0,
        receiveCount: json['receive_count'] ?? 0,
        previousSendCount: json['previous_send_count'] ?? 0,
        skippedMessageKeys: (json['skipped_keys'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, (v as List).map((b) => base64Encode(base64Decode(b))).toList()),
        ) ?? {},
      );
    }
  }

  /// Initializes a new Double Ratchet session after X3DH.
  /// [sharedSecret] — output from X3DH
  /// [theirRatchetPublicKey] — recipient's initial ratchet public key
  Future<RatchetState> initSession({
    required List<int> sharedSecret,
    required String theirRatchetPublicKeyBase64,
  }) async {
    final theirKey = SimplePublicKey(
      base64Decode(theirRatchetPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    // Generate my ratchet key pair
    final myKeyPair = await _x25519.newKeyPair();
    final myPublicKey = await myKeyPair.extractPublicKey();

    // Initialize root key from shared secret
    final rootKey = sharedSecret;

    // Perform initial DH to derive first sending chain
    final dhOutput = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: theirKey,
    );
    final dhBytes = await dhOutput.extractBytes();

    // Derive sending chain key
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey([...rootKey, ...dhBytes]),
    );
    final derivedBytes = await derived.extractBytes();

    LoggerService.info('Double Ratchet session initialized', tag: 'Ratchet');

    return RatchetState(
      rootKey: derivedBytes.sublist(0, 32),
      sendingChainKey: derivedBytes.sublist(0, 32),
      myRatchetKeyPair: myKeyPair,
      theirRatchetPublicKey: theirKey,
      sendCount: 0,
      receiveCount: 0,
    );
  }

  /// Encrypts a plaintext message.
  /// Returns { ciphertext, message_number, previous_chain_length, ratchet_public_key }
  Future<Map<String, dynamic>> encrypt({
    required RatchetState state,
    required String plaintext,
  }) async {
    // Advance sending chain
    final messageKey = await _deriveMessageKey(state.sendingChainKey!);
    final newChainKey = await _advanceChainKey(state.sendingChainKey!);

    // Encrypt with AES-256-GCM
    final nonce = Uint8List(12);
    final rng = await AesGcm.with256bits();
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(messageKey),
      nonce: nonce,
    );

    // Get my current ratchet public key
    final myPublicKey = await state.myRatchetKeyPair?.extractPublicKey();
    final ratchetPubKey = myPublicKey != null ? base64Encode(myPublicKey.bytes) : '';

    final result = {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'message_number': state.sendCount,
      'previous_chain_length': state.previousSendCount,
      'ratchet_public_key': ratchetPubKey,
    };

    // Update state
    state.sendingChainKey = newChainKey;
    state.sendCount++;

    return result;
  }

  /// Decrypts a ciphertext message.
  /// Handles out-of-order messages via skipped message keys.
  Future<String> decrypt({
    required RatchetState state,
    required Map<String, dynamic> encrypted,
  }) async {
    final ciphertext = base64Decode(encrypted['ciphertext']);
    final nonce = base64Decode(encrypted['nonce']);
    final mac = base64Decode(encrypted['mac']);
    final messageNumber = encrypted['message_number'] as int;
    final previousChainLength = encrypted['previous_chain_length'] as int;
    final theirRatchetPubKey = encrypted['ratchet_public_key'] as String;

    // Check if this is a new ratchet step
    if (theirRatchetPubKey.isNotEmpty &&
        (state.theirRatchetPublicKey == null ||
            base64Encode(state.theirRatchetPublicKey!.bytes) != theirRatchetPubKey)) {
      // New ratchet key — perform DH ratchet step
      await _dhRatchetStep(state, theirRatchetPubKey);
    }

    // Try skipped message keys first (for out-of-order messages)
    final skipKey = '$messageNumber-${base64Encode(state.theirRatchetPublicKey?.bytes ?? [])}';
    if (state.skippedMessageKeys.containsKey(skipKey)) {
      final messageKey = state.skippedMessageKeys.remove(skipKey)!;
      final plaintext = await _decryptWithKey(messageKey, nonce, ciphertext, mac);
      return plaintext;
    }

    // Advance receiving chain to get the correct message key
    while (state.receiveCount < messageNumber) {
      final skippedKey = await _deriveMessageKey(state.receivingChainKey!);
      final skipKeyEntry = '$receiveCount-${base64Encode(state.theirRatchetPublicKey?.bytes ?? [])}';
      state.skippedMessageKeys[skipKeyEntry] = skippedKey;
      state.receivingChainKey = await _advanceChainKey(state.receivingChainKey!);
      state.receiveCount++;
    }

    // Decrypt the message
    final messageKey = await _deriveMessageKey(state.receivingChainKey!);
    state.receivingChainKey = await _advanceChainKey(state.receivingChainKey!);
    state.receiveCount++;

    final plaintext = await _decryptWithKey(messageKey, nonce, ciphertext, mac);
    return plaintext;
  }

  // ===== INTERNAL =====

  Future<List<int>> _deriveMessageKey(List<int> chainKey) async {
    final derived = await _hkdf.deriveKey(secretKey: SecretKey(chainKey));
    return (await derived.extractBytes()).sublist(0, 32);
  }

  Future<List<int>> _advanceChainKey(List<int> chainKey) async {
    final derived = await _hkdf.deriveKey(secretKey: SecretKey(chainKey));
    return (await derived.extractBytes()).sublist(0, 32);
  }

  Future<String> _decryptWithKey(
    List<int> messageKey,
    List<int> nonce,
    List<int> ciphertext,
    List<int> mac,
  ) async {
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    final plaintext = await _aesGcm.decrypt(secretBox, secretKey: SecretKey(messageKey));
    return utf8.decode(plaintext);
  }

  Future<void> _dhRatchetStep(RatchetState state, String theirNewPubKeyBase64) async {
    final theirNewKey = SimplePublicKey(
      base64Decode(theirNewPubKeyBase64),
      type: KeyPairType.x25519,
    );

    // Skip receiving chain (already advanced)

    // Generate new ratchet key pair
    final newKeyPair = await _x25519.newKeyPair();
    final newPublicKey = await newKeyPair.extractPublicKey();

    // DH with new keys
    final dhOutput = await _x25519.sharedSecretKey(
      keyPair: newKeyPair,
      remotePublicKey: theirNewKey,
    );
    final dhBytes = await dhOutput.extractBytes();

    // Derive new root key and receiving chain
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey([...state.rootKey, ...dhBytes]),
    );
    final derivedBytes = await derived.extractBytes();

    state.rootKey = derivedBytes.sublist(0, 32);
    state.receivingChainKey = derivedBytes.sublist(0, 32);
    state.theirRatchetPublicKey = theirNewKey;
    state.previousSendCount = state.sendCount;
    state.sendCount = 0;
    state.receiveCount = 0;

    // Generate new sending chain
    final newDhOutput = await _x25519.sharedSecretKey(
      keyPair: newKeyPair,
      remotePublicKey: theirNewKey,
    );
    final newDhBytes = await newDhOutput.extractBytes();
    final sendingDerived = await _hkdf.deriveKey(
      secretKey: SecretKey([...state.rootKey, ...newDhBytes]),
    );
    final sendingBytes = await sendingDerived.extractBytes();
    state.sendingChainKey = sendingBytes.sublist(0, 32);
    state.myRatchetKeyPair = newKeyPair;

    LoggerService.info('DH ratchet step completed', tag: 'Ratchet');
  }
}

final doubleRatchetServiceProvider = Provider((ref) => DoubleRatchetService());
