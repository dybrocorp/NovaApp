// FASE 0.5 — PASO 4 — §14 RATE LIMITING: token bucket por dominio de
// eventos, incluido auth.challenge/response.
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/rate_limiter.dart';
import 'package:novaapp/core/socket/socket_config.dart';

void main() {
  var now = DateTime.utc(2026, 1, 1);
  DateTime clock() => now;

  group('16. Token bucket', () {
    test('Agota el burst y luego rechaza', () {
      final bucket = TokenBucketRateLimiter(
        burst: 5,
        perMinute: 5,
        clock: clock,
      );
      for (var i = 0; i < 5; i++) {
        expect(bucket.allow(), isTrue, reason: 'intento $i');
      }
      expect(bucket.allow(), isFalse, reason: 'el 6º dentro del burst falla');
    });

    test('Repone tokens con el tiempo (5/min => 2.5 en 30s)', () {
      final bucket = TokenBucketRateLimiter(
        burst: 5,
        perMinute: 5,
        clock: clock,
      );
      for (var i = 0; i < 5; i++) {
        bucket.allow();
      }
      expect(bucket.allow(), isFalse);
      now = now.add(const Duration(seconds: 30)); // +2.5 tokens
      expect(bucket.allow(), isTrue);
      expect(bucket.allow(), isTrue);
      expect(bucket.allow(), isFalse); // queda 0.5 < 1
    });

    test('Nunca supera el burst aunque pase mucho tiempo', () {
      final bucket = TokenBucketRateLimiter(
        burst: 3,
        perMinute: 60,
        clock: clock,
      );
      now = now.add(const Duration(hours: 5));
      expect(bucket.availableTokens, 3.0);
      expect(bucket.allowN(3), isTrue);
      expect(bucket.allow(), isFalse);
    });

    test('allowN rechaza peticiones mayores que el burst', () {
      final bucket = TokenBucketRateLimiter(
        burst: 2,
        perMinute: 10,
        clock: clock,
      );
      expect(bucket.allowN(3), isFalse);
    });

    test('drain() vacía el bucket (penalización)', () {
      final bucket = TokenBucketRateLimiter(
        burst: 10,
        perMinute: 10,
        clock: clock,
      );
      bucket.drain();
      expect(bucket.allow(), isFalse);
    });
  });

  group('Presets por dominio (SocketRateLimiters)', () {
    test('El límite de auth es estricto (protege brute force)', () {
      final limits = SocketRateLimiters(clock: clock);
      for (var i = 0; i < SocketRateLimitPresets.authPerMinute; i++) {
        expect(limits.auth.allow(), isTrue);
      }
      expect(limits.auth.allow(), isFalse);
    });

    test('Mensajes: 30/min; signaling: 60/min', () {
      final limits = SocketRateLimiters(clock: clock);
      var sent = 0;
      while (limits.message.allow()) {
        sent++;
      }
      expect(sent, SocketRateLimitPresets.messagePerMinute);

      var signals = 0;
      while (limits.signaling.allow()) {
        signals++;
      }
      expect(signals, SocketRateLimitPresets.signalingPerMinute);
    });

    test('El agregado acota el total aunque cada dominio tenga cupo', () {
      final limits = SocketRateLimiters(clock: clock);
      var total = 0;
      // Agotar alternando dominios: el aggregate muere antes que la suma.
      while (limits.aggregate.allow()) {
        limits.message.allow();
        limits.typing.allow();
        total++;
      }
      expect(total, SocketRateLimitPresets.totalEventsPerMinute);
      // El aggregate agotado bloquea incluso con cupo por dominio.
      expect(limits.message.availableTokens, greaterThan(0));
    });
  });
}
