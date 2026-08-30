import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:novaapp/core/services/double_ratchet_service.dart';

/// Full-fidelity persistence for [RatchetState] across app restarts.
///
/// WHY THIS EXISTS (ported from `arena/01a04505-novaapp` @ e15325c):
/// the frozen [RatchetState.toJson] — part of the FASE 0.5 architecture,
/// which this engine must not rewrite — does NOT serialize
/// `myRatchetKeyPair`. Anything persisted with it alone LOSES my ratchet
/// private key across a cold start: the session cannot DH forward,
/// subsequent sends fail and previously received messages can no longer be
/// decrypted. That violates the "no loss" requirement at the state layer.
///
/// This codec is ADDITIVE over the frozen serializer: it stores
/// `state.toJson()` verbatim and adds one key, `my_ratchet_private` — the
/// 32-byte X25519 seed of my current ratchet key pair. Decoding goes
/// through the same frozen `RatchetState.fromJson` (so every field it
/// understands, including the skipped-key map and the replay set, stays
/// authoritative) and then restores the key pair from the seed.
///
/// SECURITY: the private seed is written with EXACTLY the same durability
/// and trust as `state.rootKey` already has on the host app's persistence
/// layer (whatever the `RatchetSessionProvider` uses). This codec adds no
/// new storage surface — do not persist these strings anywhere the root
/// key is not already persisted.
class RatchetStatePersistence {
  const RatchetStatePersistence._();

  static const String _seedKey = 'my_ratchet_private';

  /// Serializes the full state, including my ratchet private seed.
  static Future<String> encode(RatchetState state) async {
    final json = state.toJson();
    final pair = state.myRatchetKeyPair;
    if (pair != null) {
      final privateKey = await pair.extractPrivateKey();
      final seed = await privateKey.extract().bytes;
      json[_seedKey] = base64Encode(seed);
    }
    return jsonEncode(json);
  }

  /// Parses an [encode] payload; also accepts payloads produced by the
  /// legacy `jsonEncode(state.toJson())` path (my key pair then stays null,
  /// exactly like before — documented limitation of the old data, not a
  /// regression introduced here).
  static Future<RatchetState> decode(String raw) async {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final seedB64 = json.remove(_seedKey) as String?;
    final state = RatchetState.fromJson(json);
    if (seedB64 != null) {
      state.myRatchetKeyPair =
          await X25519().newKeyPairFromSeed(base64Decode(seedB64));
    }
    return state;
  }
}
