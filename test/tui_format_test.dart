import 'package:test/test.dart';

import 'package:agrout_bridge/src/tui/app.dart';

void main() {
  group('formatDuration (uptime display)', () {
    test('zero elapsed -> 0h 0m 0s', () {
      expect(formatDuration(Duration.zero), '0h 0m 0s');
    });

    test('sub-minute -> 0h 0m Ns', () {
      expect(formatDuration(const Duration(seconds: 5)), '0h 0m 5s');
      expect(formatDuration(const Duration(seconds: 59)), '0h 0m 59s');
    });

    test('one minute -> 0h 1m 0s (seconds do not float into minutes)', () {
      expect(formatDuration(const Duration(seconds: 60)), '0h 1m 0s');
      expect(formatDuration(const Duration(seconds: 61)), '0h 1m 1s');
      expect(formatDuration(const Duration(seconds: 119)), '0h 1m 59s');
    });

    test('crossing the hour boundary', () {
      expect(formatDuration(const Duration(seconds: 3600)), '1h 0m 0s');
      expect(formatDuration(const Duration(seconds: 3661)), '1h 1m 1s');
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '0h 59m 59s');
    });

    test('hours + minutes + seconds all non-zero', () {
      expect(formatDuration(const Duration(hours: 2, minutes: 3, seconds: 20)),
          '2h 3m 20s');
      expect(formatDuration(const Duration(hours: 24, minutes: 12, seconds: 8)),
          '24h 12m 8s');
    });

    test('large uptimes (multi-day bridge runs)', () {
      expect(formatDuration(const Duration(hours: 100, minutes: 0, seconds: 0)),
          '100h 0m 0s');
      expect(formatDuration(const Duration(days: 3, hours: 4, minutes: 5, seconds: 6)),
          '76h 5m 6s');
    });
  });
}