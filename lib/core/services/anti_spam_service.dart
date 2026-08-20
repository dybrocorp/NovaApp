import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:novaapp/core/services/logger_service.dart';
import 'package:novaapp/core/services/supabase_service.dart';

/// Anti-spam and abuse protection service for FASE 14.
///
/// Features:
///   - Rate limiting (messages, calls, searches)
///   - Anti-enumeration (fuzzy search, limited results)
///   - Flooding protection (message burst detection)
///   - Bot detection (behavioral analysis)
///   - Mass account creation prevention

class AntiSpamService {
  final SupabaseClient? _client;

  AntiSpamService(this._client);

  // ===== RATE LIMITING =====

  /// Checks if an action is rate-limited.
  /// Returns true if the action is allowed.
  Future<bool> checkRateLimit({
    required String novaId,
    required String action, // 'message', 'call', 'search', 'register'
    int maxRequests = 30,
    Duration window = const Duration(minutes: 1),
  }) async {
    if (_client == null) return true; // Fail open in dev
    try {
      final result = await _client!.rpc('check_rate_limit', params: {
        'p_nova_id': novaId,
        'p_action': action,
        'p_max_requests': maxRequests,
        'p_window_seconds': window.inSeconds,
      });

      return result == true;
    } catch (e) {
      LoggerService.error('Rate limit check failed', error: e, tag: 'AntiSpam');
      return true; // Fail open
    }
  }

  /// Records an action for rate limiting.
  Future<void> recordAction({
    required String novaId,
    required String action,
  }) async {
    if (_client == null) return;
    try {
      await _client!.from('rate_limits').insert({
        'nova_id': novaId,
        'action': action,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (_) {}
  }

  // ===== ANTI-ENUMERATION =====

  /// Sanitized search that prevents user enumeration.
  /// Returns limited, shuffled results with no exact match indicator.
  Future<List<Map<String, dynamic>>> safeSearch({
    required String query,
    required String requesterNovaId,
    int maxResults = 5,
  }) async {
    if (_client == null) return [];
    try {
      // Sanitize query
      final sanitized = _sanitizeSearchQuery(query);
      if (sanitized.length < 3) return []; // Minimum query length

      // Add slight delay to prevent timing attacks
      await Future.delayed(const Duration(milliseconds: 100));

      final result = await _client!.from('users')
          .select('nova_id, display_name, avatar_url')
          .neq('nova_id', requesterNovaId)
          .ilike('display_name', '%$sanitized%')
          .limit(maxResults + 2); // Fetch extra to shuffle

      // Shuffle and limit to prevent enumeration
      final shuffled = List<Map<String, dynamic>>.from(result)..shuffle();
      return shuffled.take(maxResults).toList();
    } catch (e) {
      LoggerService.error('Search failed', error: e, tag: 'AntiSpam');
      return [];
    }
  }

  String _sanitizeSearchQuery(String query) {
    // Remove special characters, limit length
    final sanitized = query.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    return sanitized.substring(0, sanitized.length.clamp(0, 30));
  }

  // ===== FLOODING PROTECTION =====

  /// Detects message flooding (burst of messages in short time).
  /// Returns true if flooding is detected.
  Future<bool> detectFlooding({
    required String novaId,
    required String chatId,
    int threshold = 10,
    Duration window = const Duration(seconds: 10),
  }) async {
    if (_client == null) return false;
    try {
      final cutoff = DateTime.now().subtract(window).toIso8601String();
      final result = await _client!.from('messages')
          .select('id')
          .eq('sender_id', novaId)
          .eq('chat_id', chatId)
          .gt('created_at', cutoff);

      final count = result.length;
      if (count >= threshold) {
        LoggerService.warning('Flooding detected: $novaId sent $count messages in ${window.inSeconds}s', tag: 'AntiSpam');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ===== BOT DETECTION =====

  /// Analyzes user behavior to detect bots.
  /// Returns a risk score (0.0 = safe, 1.0 = definitely bot).
  Future<double> analyzeBehavior({
    required String novaId,
  }) async {
    if (_client == null) return 0.0;
    try {
      double riskScore = 0.0;

      // Check account age
      final profile = await _client!.from('users')
          .select('created_at')
          .eq('nova_id', novaId)
          .maybeSingle();

      if (profile != null) {
        final accountAge = DateTime.now().difference(DateTime.parse(profile['created_at']));
        if (accountAge.inMinutes < 5) riskScore += 0.3;
        if (accountAge.inHours < 1) riskScore += 0.1;
      }

      // Check message patterns
      final recentMessages = await _client!.from('messages')
          .select('text, created_at')
          .eq('sender_id', novaId)
          .order('created_at', ascending: false)
          .limit(20);

      if (recentMessages.isNotEmpty) {
        // Check for repetitive content
        final texts = recentMessages.map((m) => m['text'] as String? ?? '').toList();
        final uniqueTexts = texts.toSet();
        if (uniqueTexts.length < texts.length * 0.3) riskScore += 0.3;

        // Check for rapid-fire messages
        if (recentMessages.length >= 10) {
          final first = DateTime.parse(recentMessages.first['created_at']);
          final last = DateTime.parse(recentMessages.last['created_at']);
          final timeDiff = first.difference(last).inSeconds;
          if (timeDiff < 30) riskScore += 0.2;
        }
      }

      return riskScore.clamp(0.0, 1.0);
    } catch (_) {
      return 0.0;
    }
  }

  // ===== MASS CREATION PREVENTION =====

  /// Checks if registration should be allowed based on IP/device patterns.
  Future<bool> canRegister({
    required String ipHash, // Hashed IP, never store raw
    required String deviceFingerprint,
  }) async {
    if (_client == null) return true;
    try {
      // Check for mass registrations from same IP
      final ipRegistrations = await _client!.from('registration_attempts')
          .select('id')
          .eq('ip_hash', ipHash)
          .gt('created_at', DateTime.now().subtract(const Duration(hours: 1)).toIso8601String());

      if (ipRegistrations.length >= 3) {
        LoggerService.warning('Mass registration blocked from IP', tag: 'AntiSpam');
        return false;
      }

      // Check for mass registrations from same device
      final deviceRegistrations = await _client!.from('registration_attempts')
          .select('id')
          .eq('device_fingerprint', deviceFingerprint)
          .gt('created_at', DateTime.now().subtract(const Duration(hours: 24)).toIso8601String());

      if (deviceRegistrations.length >= 2) {
        LoggerService.warning('Mass registration blocked from device', tag: 'AntiSpam');
        return false;
      }

      // Record this attempt
      await _client!.from('registration_attempts').insert({
        'ip_hash': ipHash,
        'device_fingerprint': deviceFingerprint,
        'created_at': DateTime.now().toIso8601String(),
      });

      return true;
    } catch (e) {
      LoggerService.error('Registration check failed', error: e, tag: 'AntiSpam');
      return true; // Fail open
    }
  }

  // ===== CALL ABUSE PREVENTION =====

  /// Checks for call abuse (too many calls in short period).
  Future<bool> checkCallAbuse({
    required String callerNovaId,
    required String recipientNovaId,
    int maxCalls = 5,
    Duration window = const Duration(minutes: 5),
  }) async {
    if (_client == null) return false;
    try {
      final cutoff = DateTime.now().subtract(window).toIso8601String();
      final result = await _client!.from('calls')
          .select('id')
          .eq('caller_nova_id', callerNovaId)
          .eq('recipient_nova_id', recipientNovaId)
          .gt('started_at', cutoff);

      return result.length >= maxCalls;
    } catch (_) {
      return false;
    }
  }
}

final antiSpamServiceProvider = Provider<AntiSpamService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AntiSpamService(client);
});
