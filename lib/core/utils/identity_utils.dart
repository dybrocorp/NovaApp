import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

class IdentityUtils {
  IdentityUtils._();

  // Crockford-like base32 alphabet (excludes I, O, 0, 1 to avoid confusion)
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const String prefix = 'NOVA-';
  static const int bodyLength = 8;

  // ===== GENERATION =====

  /// Generates a Nova ID with check digit: NOVA-XXXXXXXXX (9 body chars, last is check)
  static String generateId() {
    final rng = Random.secure();
    final body = List.generate(bodyLength, (_) => _alphabet[rng.nextInt(_alphabet.length)]).join();
    final checkChar = _computeCheckDigit(body);
    return '$prefix$body$checkChar';
  }

  // ===== CHECK DIGIT (Luhn mod 32) =====

  /// Computes a check character using Luhn mod 32 over the body string.
  static String _computeCheckDigit(String body) {
    int sum = 0;
    for (int i = 0; i < body.length; i++) {
      final code = body.codeUnitAt(i);
      int value;
      if (code >= 65 && code <= 90) {
        value = code - 55; // A=10, B=11, ..., Z=35
      } else if (code >= 50 && code <= 55) {
        value = code - 50 + 2; // '2'=2, '3'=3, ..., '7'=7
      } else if (code >= 56 && code <= 57) {
        value = code - 56 + 8; // '8'=8, '9'=9
      } else {
        value = 0;
      }

      if (i.isOdd) {
        value *= 2;
        if (value >= 36) value -= 36;
      }

      sum += value;
    }
    final remainder = sum % 32;
    final checkIndex = (32 - remainder) % 32;
    return _alphabet[checkIndex];
  }

  // ===== VALIDATION =====

  /// Returns true if [novaId] is a valid Nova ID format with correct check digit.
  static bool isValid(String novaId) {
    if (!novaId.startsWith(prefix)) return false;
    final body = novaId.substring(prefix.length);
    if (body.length != bodyLength + 1) return false; // 8 body + 1 check

    final bodyPart = body.substring(0, bodyLength);
    final checkPart = body.substring(bodyLength);

    if (!_bodyCharsValid(bodyPart)) return false;
    if (checkPart.length != 1) return false;

    return _computeCheckDigit(bodyPart) == checkPart;
  }

  /// Returns true if the format is valid (ignoring check digit).
  static bool isValidFormat(String novaId) {
    if (!novaId.startsWith(prefix)) return false;
    final body = novaId.substring(prefix.length);
    if (body.length < bodyLength) return false;
    return _bodyCharsValid(body.substring(0, min(body.length, bodyLength)));
  }

  static bool _bodyCharsValid(String body) {
    for (final char in body.toUpperCase().split('')) {
      if (!_alphabet.contains(char)) return false;
    }
    return true;
  }

  /// Extracts the body (without prefix and check digit) for display.
  static String extractBody(String novaId) {
    if (!novaId.startsWith(prefix)) return novaId;
    final body = novaId.substring(prefix.length);
    return body.substring(0, min(body.length, bodyLength));
  }

  /// Formats for display: NOVA-XXXX-XXXX
  static String formatForDisplay(String novaId) {
    if (!novaId.startsWith(prefix)) return novaId;
    final body = novaId.substring(prefix.length);
    if (body.length <= 4) return '$prefix$body';
    return '$prefix${body.substring(0, 4)}-${body.substring(4)}';
  }

  // ===== ACCOUNT ID (deterministic, derived from Nova ID) =====

  /// Derives a deterministic Account ID (UUID v5-like) from a Nova ID using
  /// HMAC-SHA256 with a domain-specific key. This is a stable, non-reversible
  /// mapping so the Account ID cannot be used to recover the Nova ID.
  static String generateAccountId(String novaId) {
    final key = utf8.encode('nova-account-id-v1');
    final hmacResult = Hmac(sha256, key).convert(utf8.encode(novaId));
    final bytes = hmacResult.bytes;
    return '${_hexStr(bytes, 0, 4)}-${_hexStr(bytes, 4, 6)}-${_hexStr(bytes, 6, 8)}-${_hexStr(bytes, 8, 10)}-${_hexStr(bytes, 10, 16)}';
  }

  static String _hexStr(List<int> bytes, int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  // ===== DEVICE ID (cryptographic random) =====

  /// Generates a unique Device ID using cryptographic randomness.
  static String generateDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return '${_hexStr(bytes, 0, 4)}-${_hexStr(bytes, 4, 6)}-${_hexStr(bytes, 6, 8)}-${_hexStr(bytes, 8, 10)}-${_hexStr(bytes, 10, 16)}';
  }
}
