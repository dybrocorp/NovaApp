import 'dart:math';

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
}
