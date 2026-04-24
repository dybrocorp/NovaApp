import 'dart:math';

class IdentityUtils {
  static const String _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Excluded O, I, 0, 1 for clarity
  
  static String generateId() {
    final Random random = Random.secure();
    return List.generate(8, (index) => _chars[random.nextInt(_chars.length)]).join();
  }
}
