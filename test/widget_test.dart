import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/utils/identity_utils.dart';

void main() {
  test('IdentityUtils.generateId returns NOVA-XXXXXXXX format', () {
    final id = IdentityUtils.generateId();
    expect(id, matches(RegExp(r'^NOVA-[A-Z0-9]{8}$')));
  });

  test('IdentityUtils.generateId produces different IDs', () {
    final id1 = IdentityUtils.generateId();
    final id2 = IdentityUtils.generateId();
    expect(id1, isNot(equals(id2)));
  });

  test('IdentityUtils characters are valid (no 0,1,I,O)', () {
    final id = IdentityUtils.generateId();
    final suffix = id.replaceAll('NOVA-', '');
    expect(suffix.contains('0'), isFalse);
    expect(suffix.contains('1'), isFalse);
    expect(suffix.contains('I'), isFalse);
    expect(suffix.contains('O'), isFalse);
  });
}
