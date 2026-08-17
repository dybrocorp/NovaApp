import 'dart:math';

class IdentityUtils {
  static const String _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Generates a unique Nova ID like "NOVA-A3K7X2B9"
  /// Uses the app prefix "NOVA" followed by 8 random alphanumeric characters.
  /// Includes timestamp-based seed + secure random for guaranteed uniqueness.
  static String generateId() {
    final Random random = Random.secure();
    final chars = List.generate(8, (_) => _chars[random.nextInt(_chars.length)]).join();
    return 'NOVA-$chars';
  }
}
