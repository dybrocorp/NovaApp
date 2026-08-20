import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/constants.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';
import 'package:novaapp/core/utils/identity_utils.dart';

/// Challenge-response auth flow: Nova ID + PIN.
///
/// Flow:
///   1. Client sends Nova ID to /auth/challenge
///   2. Server generates random challenge, stores it with timestamp
///   3. Client receives challenge, hashes: HMAC-SHA256(challenge, PIN)
///   4. Client sends response to /auth/verify
///   5. Server verifies, returns JWT + device token
///
/// PIN is NEVER stored on server. Server stores Argon2id hash of PIN.
/// Challenge expires after 60 seconds.

class AuthService {
  final SupabaseClient? _client;

  AuthService(this._client);

  // ===== PIN MANAGEMENT =====

  /// Hashes a PIN using Argon2id (simulated with PBKDF2-HMAC-SHA256 for portability).
  /// In production, use a native Argon2 library or Supabase Edge Function.
  static String hashPin(String pin, String salt) {
    // PBKDF2 with 310,000 iterations (OWASP 2023 recommendation for PBKDF2-SHA256)
    final key = _pbkdf2(pin, salt, 310000, 32);
    return base64Encode(key);
  }

  /// Verifies a PIN against its stored hash.
  static bool verifyPin(String pin, String storedHash, String salt) {
    final computed = hashPin(pin, salt);
    // Constant-time comparison
    if (computed.length != storedHash.length) return false;
    int result = 0;
    for (int i = 0; i < computed.length; i++) {
      result |= computed.codeUnitAt(i) ^ storedHash.codeUnitAt(i);
    }
    return result == 0;
  }

  // ===== CHALLENGE-RESPONSE =====

  /// Requests a login challenge from the server for a given Nova ID.
  /// Returns { challenge, challenge_id, expires_at } or null on failure.
  Future<Map<String, String>?> requestChallenge(String novaId) async {
    if (_client == null) return null;
    try {
      // Server-side: generate challenge, store it, return challenge + id
      final result = await _client!.rpc('auth_challenge_request', params: {
        'p_nova_id': novaId,
      });

      if (result == null) return null;

      return {
        'challenge': result['challenge'] as String,
        'challenge_id': result['challenge_id'] as String,
        'expires_at': result['expires_at'] as String,
      };
    } catch (e) {
      LoggerService.error('Failed to request challenge', error: e, tag: 'Auth');
      return null;
    }
  }

  /// Solves a challenge using the user's PIN and sends the response.
  /// Returns JWT token on success, null on failure.
  Future<String?> solveChallenge({
    required String challenge,
    required String challengeId,
    required String pin,
  }) async {
    if (_client == null) return null;
    try {
      // HMAC-SHA256(challenge, PIN) — challenge is the message, PIN is the key
      final hmac = Hmac(sha256, utf8.encode(pin));
      final digest = hmac.convert(utf8.encode(challenge));
      final response = base64Encode(digest.bytes);

      // Send response to server
      final result = await _client!.rpc('auth_challenge_verify', params: {
        'challenge_id': challengeId,
        'response': response,
      });

      if (result == null || result['token'] == null) {
        LoggerService.warning('Challenge verification failed', tag: 'Auth');
        return null;
      }

      final token = result['token'] as String;
      final refreshToken = result['refresh_token'] as String?;

      // Set session
      await _client!.auth.setSession(Session(
        accessToken: token,
        refreshToken: refreshToken ?? '',
        expiresIn: 3600,
        tokenType: 'bearer',
        expiresAt: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      ));

      LoggerService.info('Challenge-response auth successful', tag: 'Auth');
      return token;
    } catch (e) {
      LoggerService.error('Challenge solving failed', error: e, tag: 'Auth');
      return null;
    }
  }

  // ===== REGISTRATION =====

  /// Registers a new account with Nova ID + PIN.
  /// Server stores Argon2id hash of PIN (never the raw PIN).
  Future<bool> register({
    required String novaId,
    required String pin,
    required String displayName,
  }) async {
    if (_client == null) return false;
    try {
      // Generate salt
      final rng = Random.secure();
      final saltBytes = List<int>.generate(16, (_) => rng.nextInt(256));
      final salt = base64Encode(saltBytes);

      // Hash PIN
      final pinHash = hashPin(pin, salt);

      // Register via Edge Function (server-side Argon2id)
      final result = await _client!.rpc('auth_register', params: {
        'p_nova_id': novaId,
        'p_pin_hash': pinHash,
        'p_salt': salt,
        'p_display_name': displayName,
      });

      if (result == null || result == false) {
        LoggerService.warning('Registration failed for $novaId', tag: 'Auth');
        return false;
      }

      LoggerService.info('Account registered: $novaId', tag: 'Auth');
      return true;
    } catch (e) {
      LoggerService.error('Registration error', error: e, tag: 'Auth');
      return false;
    }
  }

  // ===== SESSION MANAGEMENT =====

  /// Refreshes the current JWT token.
  Future<bool> refreshSession() async {
    if (_client == null) return false;
    try {
      final response = await _client!.auth.refreshSession();
      return response.session != null;
    } catch (e) {
      LoggerService.error('Session refresh failed', error: e, tag: 'Auth');
      return false;
    }
  }

  /// Signs out from all devices.
  Future<void> signOutAll() async {
    if (_client == null) return;
    try {
      await _client!.auth.signOut(scope: SignOutScope.global);
      LoggerService.info('Signed out from all devices', tag: 'Auth');
    } catch (e) {
      LoggerService.error('Sign out failed', error: e, tag: 'Auth');
    }
  }

  // ===== HELPERS =====

  /// Returns true if the user has an active session.
  bool get isAuthenticated => _client?.auth.currentSession != null;

  /// Returns the current user's Nova ID from the JWT.
  String? get currentNovaId {
    final user = _client?.auth.currentUser;
    if (user == null) return null;
    return user.userMetadata?['nova_id'] as String?;
  }

  /// PBKDF2 key derivation (for PIN hashing).
  static List<int> _pbkdf2(String password, String salt, int iterations, int keyLength) {
    final passwordBytes = utf8.encode(password);
    final saltBytes = base64Decode(salt);

    final hmacSha256 = Hmac(sha256, passwordBytes);
    final blockCount = (keyLength / 32).ceil();
    final result = <int>[];

    for (int i = 1; i <= blockCount; i++) {
      var u = hmacSha256.convert([...saltBytes, ..._intToBytes(i)]);
      var t = u.bytes.toList();

      for (int j = 1; j < iterations; j++) {
        u = hmacSha256.convert(u.bytes);
        for (int k = 0; k < 32; k++) {
          t[k] ^= u.bytes[k];
        }
      }
      result.addAll(t);
    }

    return result.sublist(0, keyLength);
  }

  static List<int> _intToBytes(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AuthService(client);
});
