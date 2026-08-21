import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/utils/identity_utils.dart';

void main() {
  group('IdentityUtils.generateId', () {
    test('returns NOVA-XXXXXXXXX format (8 body + 1 check)', () {
      final id = IdentityUtils.generateId();
      expect(id, startsWith('NOVA-'));
      expect(id.length, equals(14)); // NOVA- + 9 body chars
    });

    test('produces different IDs', () {
      final ids = List.generate(100, (_) => IdentityUtils.generateId());
      final unique = ids.toSet();
      expect(unique.length, equals(100));
    });

    test('check digit is valid', () {
      for (int i = 0; i < 50; i++) {
        final id = IdentityUtils.generateId();
        expect(IdentityUtils.isValid(id), isTrue, reason: 'Failed for $id');
      }
    });

    test('no ambiguous characters in body', () {
      final id = IdentityUtils.generateId();
      final body = id.substring(5); // after NOVA-
      for (final char in body.split('')) {
        expect(['0', '1', 'I', 'O'].contains(char), isFalse, reason: 'Ambiguous char: $char');
      }
    });
  });

  group('IdentityUtils.isValid', () {
    test('accepts valid generated IDs', () {
      for (int i = 0; i < 20; i++) {
        final id = IdentityUtils.generateId();
        expect(IdentityUtils.isValid(id), isTrue);
      }
    });

    test('rejects wrong check digit', () {
      final id = IdentityUtils.generateId();
      final lastChar = id[id.length - 1];
      final replacement = lastChar == 'A' ? 'B' : 'A';
      final tampered = '${id.substring(0, id.length - 1)}$replacement';
      expect(IdentityUtils.isValid(tampered), isFalse);
    });

    test('rejects missing prefix', () {
      expect(IdentityUtils.isValid('ABC-12345678A'), isFalse);
    });

    test('rejects wrong length', () {
      expect(IdentityUtils.isValid('NOVA-1234'), isFalse);
      expect(IdentityUtils.isValid('NOVA-12345678901234'), isFalse);
    });
  });

  group('IdentityUtils.formatForDisplay', () {
    test('formats correctly with dash', () {
      final id = IdentityUtils.generateId();
      final display = IdentityUtils.formatForDisplay(id);
      expect(display, contains('NOVA-'));
      expect(display.split('-').length, greaterThanOrEqualTo(3));
    });
  });

  group('IdentityUtils.generateAccountId', () {
    test('produces valid UUID v4 format', () {
      final a1 = IdentityUtils.generateAccountId();
      expect(a1, matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    });

    test('generates unique IDs (CSPRNG)', () {
      final ids = List.generate(100, (_) => IdentityUtils.generateAccountId());
      final unique = ids.toSet();
      expect(unique.length, equals(100));
    });

    test('two calls produce different account IDs', () {
      final a1 = IdentityUtils.generateAccountId();
      final a2 = IdentityUtils.generateAccountId();
      expect(a1, isNot(equals(a2)));
    });
  });
}
