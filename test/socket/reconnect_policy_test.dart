// FASE 0.5 — PASO 4 — §6 RECONEXIÓN: backoff exponencial + jitter + tope
// de intentos (sin bucles infinitos).
import 'package:flutter_test/flutter_test.dart';
import 'package:novaapp/core/socket/reconnect_policy.dart';

void main() {
  group('10. Backoff exponencial', () {
    test('Sin jitter (random=0) los delays duplican y se capan a 30s', () {
      final policy = ReconnectPolicy(jitterRandom: () => 0.0);
      final delays = <int>[
        for (var i = 0; i < 12; i++) policy.nextDelay().inMilliseconds,
      ];
      expect(delays.sublist(0, 5), [1000, 2000, 4000, 8000, 16000]);
      expect(delays[5], 30000); // 32000 -> capped
      expect(delays[6], 30000);
    });

    test('Con jitter completo los delays quedan en [0, cap]', () {
      final policy = ReconnectPolicy(jitterRandom: () => 0.999);
      for (var i = 0; i < 6; i++) {
        final delay = policy.nextDelay();
        expect(delay.inMilliseconds, lessThanOrEqualTo(30000));
        expect(delay.isNegative, isFalse);
      }
    });

    test('peekDelay no avanza el contador', () {
      final policy = ReconnectPolicy(jitterRandom: () => 0.0);
      expect(policy.peekDelay().inMilliseconds, 1000);
      expect(policy.peekDelay().inMilliseconds, 1000);
      expect(policy.attempt, 0);
    });
  });

  group('Tope de intentos — sin bucles infinitos', () {
    test('Tras maxAttempts el policy se agota y devuelve 0', () {
      final policy = ReconnectPolicy(
        maxAttempts: 3,
        jitterRandom: () => 0.0,
      );
      expect(policy.exhausted, isFalse);
      policy.nextDelay();
      policy.nextDelay();
      policy.nextDelay();
      expect(policy.exhausted, isTrue);
      expect(policy.nextDelay(), Duration.zero);
    });

    test('reset() rearma el ciclo tras una autenticación exitosa', () {
      final policy = ReconnectPolicy(
        maxAttempts: 2,
        jitterRandom: () => 0.0,
      );
      policy.nextDelay();
      policy.nextDelay();
      expect(policy.exhausted, isTrue);
      policy.reset();
      expect(policy.exhausted, isFalse);
      expect(policy.nextDelay().inMilliseconds, 1000);
    });

    test('countAttempt consume intento sin delay (reconnect inmediato)', () {
      final policy = ReconnectPolicy(maxAttempts: 2);
      policy.countAttempt();
      policy.countAttempt();
      expect(policy.exhausted, isTrue);
    });
  });

  group('Distribución del jitter (full jitter)', () {
    test('Los delays varían entre intentos con la misma semilla de reloj',
        () {
      // Con random real, dos policies en el mismo intento suelen diferir;
      // verificamos acotamiento y variabilidad estadística simple.
      final a = ReconnectPolicy();
      final b = ReconnectPolicy();
      var differ = 0;
      for (var i = 0; i < 8; i++) {
        final da = a.nextDelay();
        final db = b.nextDelay();
        expect(da.inMilliseconds, lessThanOrEqualTo(30000));
        expect(db.inMilliseconds, lessThanOrEqualTo(30000));
        if (da != db) differ++;
      }
      // Con 8 pares es prácticamente imposible que todos coincidan.
      expect(differ, greaterThan(0),
          reason: 'El jitter debe desincronizar a los clientes');
    });
  });
}
