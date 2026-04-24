import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SupabaseService {
  static const String supabaseUrl = 'https://jhadjzkynfsqxmbfwqbg.supabase.co';
  static const String supabaseAnonKey = 'sb_publishable_rBY6P7NM9Yg0dktmSOtvdg_HORr42UR';

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
    );
  }

  SupabaseClient get client => Supabase.instance.client;

  // Helpers for common operations
  Future<void> signInWithOtp(String phone) async {
    await client.auth.signInWithOtp(phone: phone);
  }

  Future<AuthResponse> verifyOtp(String phone, String token) async {
    return await client.auth.verifyOTP(
      type: OtpType.sms,
      token: token,
      phone: phone,
    );
  }

  Future<String?> getRemotePublicKey(String userId) async {
    final response = await client.from('profiles').select('public_key').eq('id', userId).single();
    return response['public_key'] as String?;
  }

  Future<void> updatePublicKey(String publicKey) async {
    final user = currentUser;
    if (user != null) {
      await client.from('profiles').upsert({
        'id': user.id,
        'public_key': publicKey,
      });
    }
  }

  User? get currentUser => client.auth.currentUser;
}

final supabaseServiceProvider = Provider((ref) => SupabaseService());
final supabaseClientProvider = Provider((ref) => ref.watch(supabaseServiceProvider).client);
