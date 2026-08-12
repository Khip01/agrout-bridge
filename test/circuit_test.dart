import 'package:test/test.dart';

import 'package:agrout_bridge/src/server/circuit.dart';

void main() {
  group('CircuitBreaker', () {
    test('starts closed', () {
      final cb = CircuitBreaker();
      expect(cb.isOpen, isFalse);
      expect(cb.consecutiveFails, 0);
    });

    test('opens after threshold consecutive failures', () {
      final cb = CircuitBreaker();
      for (var i = 0; i < 5; i++) {
        cb.recordFailure();
      }
      expect(cb.isOpen, isTrue);
      expect(cb.consecutiveFails, 5);
    });

    test('does not open below threshold', () {
      final cb = CircuitBreaker();
      for (var i = 0; i < 4; i++) {
        cb.recordFailure();
      }
      expect(cb.isOpen, isFalse);
    });

    test('success resets consecutive fails', () {
      final cb = CircuitBreaker();
      for (var i = 0; i < 4; i++) {
        cb.recordFailure();
      }
      cb.recordSuccess();
      expect(cb.consecutiveFails, 0);
      // Need 5 again to open.
      for (var i = 0; i < 4; i++) {
        cb.recordFailure();
      }
      expect(cb.isOpen, isFalse);
    });
  });

  group('ModelHealth', () {
    test('healthy by default', () {
      final m = ModelHealth();
      expect(m.isHealthy('claude-opus-4-8'), isTrue);
    });

    test('unhealthy after 3+ failures in window', () {
      final m = ModelHealth();
      m.recordFailure('claude-opus-4-8', 500);
      m.recordFailure('claude-opus-4-8', 502);
      m.recordFailure('claude-opus-4-8', 503);
      expect(m.isHealthy('claude-opus-4-8'), isFalse);
    });

    test('filters unhealthy from list', () {
      final m = ModelHealth();
      m.recordFailure('a', 500);
      m.recordFailure('a', 500);
      m.recordFailure('a', 500);
      expect(m.filter(['a', 'b']), ['b']);
    });
  });
}
