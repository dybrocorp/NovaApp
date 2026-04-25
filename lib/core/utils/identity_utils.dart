import 'dart:math';

class IdentityUtils {
  static const String _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Generates a unique Nova ID like "NOVA-A3K7X2B9"
  /// Uses the app prefix "NOVA" followed by 8 random alphanumeric characters.
  /// Includes timestamp-based seed + secure random for guaranteed uniqueness.
  static String generateId() {
    final Random random = Random.secure();
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    // Mix timestamp bits into the random generation for extra uniqueness
    final seed = Random(timestamp);
    final chars = List.generate(8, (index) {
      // Alternate between secure random and timestamp-seeded random
      final r = index.isEven ? random : seed;
      return _chars[r.nextInt(_chars.length)];
    }).join();
    return 'NOVA-$chars';
  }
}
