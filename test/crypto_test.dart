import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/services/auth_service.dart';

void main() {
  group('AuthService - PIN Hashing', () {
    test('hashPin produces consistent results', () {
      final hash1 = AuthService.hashPin('1234', 'salt123');
      final hash2 = AuthService.hashPin('1234', 'salt123');
      expect(hash1, equals(hash2));
    });

    test('hashPin produces different hashes for different PINs', () {
      final hash1 = AuthService.hashPin('1234', 'salt123');
      final hash2 = AuthService.hashPin('5678', 'salt123');
      expect(hash1, isNot(equals(hash2)));
    });

    test('hashPin produces different hashes for different salts', () {
      final hash1 = AuthService.hashPin('1234', 'salt123');
      final hash2 = AuthService.hashPin('1234', 'salt456');
      expect(hash1, isNot(equals(hash2)));
    });

    test('verifyPin returns true for correct PIN', () {
      final salt = 'testsalt';
      final hash = AuthService.hashPin('1234', salt);
      expect(AuthService.verifyPin('1234', hash, salt), isTrue);
    });

    test('verifyPin returns false for wrong PIN', () {
      final salt = 'testsalt';
      final hash = AuthService.hashPin('1234', salt);
      expect(AuthService.verifyPin('5678', hash, salt), isFalse);
    });

    test('verifyPin returns false for wrong salt', () {
      final hash = AuthService.hashPin('1234', 'salt123');
      expect(AuthService.verifyPin('1234', hash, 'wrong_salt'), isFalse);
    });

    test('PIN hash is base64 encoded', () {
      final hash = AuthService.hashPin('1234', 'salt');
      expect(() => Uri.decodeFull(hash), isNot(throwsException));
    });
  });
}
