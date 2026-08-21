import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novaapp/core/services/logger_service.dart';

/// Double Ratchet Protocol implementation (Signal Protocol compliant).
///
/// Provides ongoing forward secrecy after X3DH key establishment.
/// Each message is encrypted with a unique key derived from the ratchet.
///
/// Chain Key Evolution (HMAC-SHA256 per Signal spec):
///   Message Key:  MK  = HMAC-SHA256(CK, 0x01)
///   Chain Key:    CK' = HMAC-SHA256(CK, 0x02)
///
/// DH Ratchet Step (when receiving a new ratchet public key):
///   Phase 1 (receiving):
///     DH = DH(myOldKey, theirNewKey)
///     RK, CK_receive = KDF(RK || DH)
///   Phase 2 (sending):
///     Generate new keypair
///     DH = DH(myNewKey, theirNewKey)
///     RK, CK_send = KDF(RK || DH)
///
/// AAD = ratchet_public_key || message_number || previous_chain_length
///
/// Maximum skipped message keys to prevent DoS.

const int _maxSkippedKeys = 2000;

/// Ratchet state for a single conversation.
class RatchetState {
  List<int> rootKey;
  List<int>? sendingChainKey;
  List<int>? receivingChainKey;
  SimpleKeyPair? myRatchetKeyPair;
  SimplePublicKey? theirRatchetPublicKey;
  int sendCount;
  int receiveCount;
  int previousSendCount;
  Map<String, List<int>> skippedMessageKeys;
  Set<String> _decryptedMessageKeys;

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
    Set<String>? decryptedMessageKeys,
  })  : skippedMessageKeys = skippedMessageKeys ?? {},
        _decryptedMessageKeys = decryptedMessageKeys ?? {};

  bool get hasDecryptedBefore => _decryptedMessageKeys.isNotEmpty;
  bool get hasSendingChain => sendingChainKey != null;
  bool get hasReceivingChain => receivingChainKey != null;

  bool _isMessageDecrypted(int msgNum, List<int> theirRatchetKeyBytes) {
    final key = '$msgNum-${base64Encode(theirRatchetKeyBytes)}';
    return _decryptedMessageKeys.contains(key);
  }

  void _markDecrypted(int msgNum, List<int> theirRatchetKeyBytes) {
    final key = '$msgNum-${base64Encode(theirRatchetKeyBytes)}';
    _decryptedMessageKeys.add(key);
  }

  Map<String, dynamic> toJson() {
    return {
      'root_key': base64Encode(rootKey),
      'sending_chain_key':
          sendingChainKey != null ? base64Encode(sendingChainKey!) : null,
      'receiving_chain_key':
          receivingChainKey != null ? base64Encode(receivingChainKey!) : null,
      'their_ratchet_public_key': theirRatchetPublicKey != null
          ? base64Encode(theirRatchetPublicKey!.bytes)
          : null,
      'send_count': sendCount,
      'receive_count': receiveCount,
      'previous_send_count': previousSendCount,
      'skipped_keys': skippedMessageKeys.map(
        (k, v) => MapEntry(k, base64Encode(v)),
      ),
      'decrypted_msgs': _decryptedMessageKeys.toList(),
    };
  }

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
      skippedMessageKeys: (json['skipped_keys'] as Map<String, dynamic>?)
              ?.map(
            (k, v) => MapEntry(k, base64Decode(v as String)),
          ) ??
          {},
      decryptedMessageKeys: json['decrypted_msgs'] != null
          ? Set<String>.from(json['decrypted_msgs'] as List)
          : null,
    );
  }
}

class DoubleRatchetService {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _hmac = Hmac.sha256();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);

  /// Initializes a new Double Ratchet session (Alice / sender only).
  ///
  /// After X3DH, Alice calls this to set up her sending chain.
  /// Bob does NOT call this — he derives his receiving chain from
  /// Alice's first message via _initReceiverSession.
  Future<RatchetState> initSession({
    required List<int> sharedSecret,
    required String theirRatchetPublicKeyBase64,
  }) async {
    final theirKey = SimplePublicKey(
      base64Decode(theirRatchetPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final myKeyPair = await _x25519.newKeyPair();

    final dhOutput = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: theirKey,
    );
    final dhBytes = await dhOutput.extractBytes();

    final derived = await _kdfChainKey(
      sharedSecret,
      Uint8List.fromList(dhBytes),
    );

    LoggerService.info('Double Ratchet session initialized (sender)',
        tag: 'Ratchet');

    return RatchetState(
      rootKey: derived.sublist(0, 32),
      sendingChainKey: derived.sublist(32, 64),
      myRatchetKeyPair: myKeyPair,
      theirRatchetPublicKey: theirKey,
      sendCount: 0,
      receiveCount: 0,
      previousSendCount: 0,
    );
  }

  /// Initializes a Double Ratchet session for Bob (receiver) from
  /// Alice's first encrypted message.
  ///
  /// Bob MUST already have his ratchet keypair (from key bundle generation).
  /// Uses ECDH symmetry: DH(bob_old_priv, alice_pub) == DH(alice_priv, bob_old_pub)
  /// so that Bob's rootKey matches Alice's.
  ///
  /// Phase 1: Receiving chain using Bob's EXISTING keypair
  /// Phase 2: Sending chain using a NEW keypair
  Future<void> _initReceiverSession(
    RatchetState state,
    List<int> aliceRatchetPubBytes,
  ) async {
    if (state.myRatchetKeyPair == null) {
      throw StateError(
        'Bob must have a ratchet keypair before receiving Alice\'s first message. '
        'Set myRatchetKeyPair on the RatchetState before calling decrypt.',
      );
    }

    final theirKey = SimplePublicKey(
      aliceRatchetPubBytes,
      type: KeyPairType.x25519,
    );

    // Phase 1: Receiving chain using Bob's EXISTING keypair
    // DH(bob_old_priv, alice_pub) == DH(alice_priv, bob_old_pub)
    final dhRecvOutput = await _x25519.sharedSecretKey(
      keyPair: state.myRatchetKeyPair!,
      remotePublicKey: theirKey,
    );
    final dhRecvBytes = await dhRecvOutput.extractBytes();
    final derivedRecv = await _kdfChainKey(state.rootKey, dhRecvBytes);

    state.rootKey = derivedRecv.sublist(0, 32);
    state.receivingChainKey = derivedRecv.sublist(32, 64);
    state.theirRatchetPublicKey = theirKey;
    state.previousSendCount = 0;
    state.sendCount = 0;
    state.receiveCount = 0;

    // Phase 2: Sending chain using a NEW keypair
    final newKeyPair = await _x25519.newKeyPair();
    final dhSendOutput = await _x25519.sharedSecretKey(
      keyPair: newKeyPair,
      remotePublicKey: theirKey,
    );
    final dhSendBytes = await dhSendOutput.extractBytes();
    final derivedSend = await _kdfChainKey(state.rootKey, dhSendBytes);

    state.rootKey = derivedSend.sublist(0, 32);
    state.sendingChainKey = derivedSend.sublist(32, 64);
    state.myRatchetKeyPair = newKeyPair;

    LoggerService.info('Receiver session initialized', tag: 'Ratchet');
  }

  /// Encrypts a plaintext message.
  Future<Map<String, dynamic>> encrypt({
    required RatchetState state,
    required String plaintext,
  }) async {
    if (state.sendingChainKey == null) {
      throw StateError('No sending chain — cannot encrypt');
    }

    final messageKeyBytes = await _deriveMessageKey(state.sendingChainKey!);
    state.sendingChainKey =
        await _advanceChainKey(state.sendingChainKey!);

    final myPublicKey = await state.myRatchetKeyPair?.extractPublicKey();
    final ratchetPubKey =
        myPublicKey != null ? base64Encode(myPublicKey.bytes) : '';

    final header = _buildHeader(ratchetPubKey, state.sendCount, state.previousSendCount);

    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
      secretKey: SecretKey(messageKeyBytes),
      nonce: nonce,
      aad: header,
    );

    final result = {
      'ciphertext': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(secretBox.mac.bytes),
      'message_number': state.sendCount,
      'previous_chain_length': state.previousSendCount,
      'ratchet_public_key': ratchetPubKey,
    };

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
    final theirRatchetPubKeyB64 = encrypted['ratchet_public_key'] as String;
    final theirRatchetPubKeyBytes = base64Decode(theirRatchetPubKeyB64);

    final isNewKey = theirRatchetPubKeyB64.isNotEmpty &&
        (state.theirRatchetPublicKey == null ||
            base64Encode(state.theirRatchetPublicKey!.bytes) !=
                theirRatchetPubKeyB64);

    if (isNewKey) {
      if (state.hasReceivingChain) {
        await _dhRatchetStep(state, theirRatchetPubKeyBytes);
      } else {
        await _initReceiverSession(state, theirRatchetPubKeyBytes);
      }
    }

    final theirKeyBytes = state.theirRatchetPublicKey?.bytes ?? [];

    if (state._isMessageDecrypted(messageNumber, theirKeyBytes)) {
      throw StateError('Message #$messageNumber already decrypted (replay)');
    }

    final skipKey = '$messageNumber-${base64Encode(theirKeyBytes)}';

    if (state.skippedMessageKeys.containsKey(skipKey)) {
      final messageKey = state.skippedMessageKeys.remove(skipKey)!;
      final header = _buildHeader(theirRatchetPubKeyB64, messageNumber, previousChainLength);
      final plaintext = await _decryptWithAad(messageKey, nonce, ciphertext, mac, header);
      state._markDecrypted(messageNumber, theirKeyBytes);
      return plaintext;
    }

    while (state.receiveCount < messageNumber) {
      if (state.receivingChainKey == null) {
        throw StateError('No receiving chain and not a new ratchet key');
      }
      final skippedKey = await _deriveMessageKey(state.receivingChainKey!);
      final skippedEntry =
          '${state.receiveCount}-${base64Encode(theirKeyBytes)}';
      state.skippedMessageKeys[skippedEntry] = skippedKey;
      state.receivingChainKey =
          await _advanceChainKey(state.receivingChainKey!);
      state.receiveCount++;
    }

    if (state.skippedMessageKeys.length > _maxSkippedKeys) {
      throw StateError(
          'Skipped message keys limit exceeded ($_maxSkippedKeys)');
    }

    final messageKey = await _deriveMessageKey(state.receivingChainKey!);
    state.receivingChainKey =
        await _advanceChainKey(state.receivingChainKey!);
    state.receiveCount++;

    final header = _buildHeader(theirRatchetPubKeyB64, messageNumber, previousChainLength);
    final plaintext = await _decryptWithAad(messageKey, nonce, ciphertext, mac, header);
    state._markDecrypted(messageNumber, theirKeyBytes);
    return plaintext;
  }

  // ===== INTERNAL =====

  Uint8List _buildHeader(String ratchetPubKey, int msgNum, int prevChainLen) {
    return Uint8List.fromList(utf8.encode(ratchetPubKey) +
        [msgNum & 0xFF, (msgNum >> 8) & 0xFF, (msgNum >> 16) & 0xFF, (msgNum >> 24) & 0xFF] +
        [prevChainLen & 0xFF, (prevChainLen >> 8) & 0xFF, (prevChainLen >> 16) & 0xFF, (prevChainLen >> 24) & 0xFF]);
  }

  Future<List<int>> _kdfChainKey(List<int> salt, List<int> dhBytes) async {
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(dhBytes),
      nonce: salt,
    );
    return (await derived.extractBytes()).sublist(0, 64);
  }

  Future<List<int>> _deriveMessageKey(List<int> chainKey) async {
    final mac = await _hmac.calculateMac(
      [0x01],
      secretKey: SecretKey(chainKey),
    );
    return mac.bytes.sublist(0, 32);
  }

  Future<List<int>> _advanceChainKey(List<int> chainKey) async {
    final mac = await _hmac.calculateMac(
      [0x02],
      secretKey: SecretKey(chainKey),
    );
    return mac.bytes.sublist(0, 32);
  }

  Future<String> _decryptWithAad(
    List<int> messageKey,
    List<int> nonce,
    List<int> ciphertext,
    List<int> mac,
    Uint8List aad,
  ) async {
    final secretBox =
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));
    final plaintext = await _aesGcm.decrypt(
      secretBox,
      secretKey: SecretKey(messageKey),
      aad: aad,
    );
    return utf8.decode(plaintext);
  }

  /// DH Ratchet Step when receiving a new ratchet public key.
  ///
  /// Phase 1: Receiving chain using OLD local key + their new key
  ///   RK, CK_receive = KDF(RK, DH(myOldKey, theirNewKey))
  ///
  /// Phase 2: Generate NEW local key, sending chain with their new key
  ///   RK, CK_send = KDF(RK, DH(myNewKey, theirNewKey))
  Future<void> _dhRatchetStep(
      RatchetState state, List<int> theirNewPubKeyBytes) async {
    final theirNewKey = SimplePublicKey(
      theirNewPubKeyBytes,
      type: KeyPairType.x25519,
    );

    // Phase 1: Receiving chain using EXISTING (old) local key
    final dhRecvOutput = await _x25519.sharedSecretKey(
      keyPair: state.myRatchetKeyPair!,
      remotePublicKey: theirNewKey,
    );
    final dhRecvBytes = await dhRecvOutput.extractBytes();

    final derivedRecv = await _kdfChainKey(state.rootKey, dhRecvBytes);
    state.rootKey = derivedRecv.sublist(0, 32);
    state.receivingChainKey = derivedRecv.sublist(32, 64);

    state.previousSendCount = state.sendCount;
    state.sendCount = 0;
    state.receiveCount = 0;
    state.theirRatchetPublicKey = theirNewKey;

    // Phase 2: Generate NEW keypair, sending chain with their new key
    final newKeyPair = await _x25519.newKeyPair();
    final dhSendOutput = await _x25519.sharedSecretKey(
      keyPair: newKeyPair,
      remotePublicKey: theirNewKey,
    );
    final dhSendBytes = await dhSendOutput.extractBytes();

    final derivedSend = await _kdfChainKey(state.rootKey, dhSendBytes);
    state.rootKey = derivedSend.sublist(0, 32);
    state.sendingChainKey = derivedSend.sublist(32, 64);

    state.myRatchetKeyPair = newKeyPair;

    LoggerService.info('DH ratchet step completed', tag: 'Ratchet');
  }
}

final doubleRatchetServiceProvider = Provider((ref) => DoubleRatchetService());
