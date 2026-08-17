import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/services/daily_claim.dart';
import 'package:agrout_bridge/src/services/daily_claim_detector.dart';
import 'package:test/test.dart';

void main() {
  group('DailyClaimConfig', () {
    test('defaults center on 25 with +-2 tolerance', () {
      final c = DailyClaimConfig();
      expect(c.enabled, isTrue);
      expect(c.expectedAmount, 25.0);
      expect(c.tolerance, 2.0);
      expect(c.mode, 'quota');
      expect(c.isConfigured, isFalse);
    });

    test('round-trips through JSON including per-key dates', () {
      final c = DailyClaimConfig(
        expectedAmount: 50.0,
        tolerance: 5.0,
        browser: 'brave',
        profileDir: '/tmp/bridge-browser',
        lastClaimDate: {'key-a': '2026-08-17'},
      );
      final restored = DailyClaimConfig.fromJson(
          jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
      expect(restored.expectedAmount, 50.0);
      expect(restored.tolerance, 5.0);
      expect(restored.browser, 'brave');
      expect(restored.profileDir, '/tmp/bridge-browser');
      expect(restored.lastClaimDate['key-a'], '2026-08-17');
      expect(restored.isConfigured, isTrue);
    });

    test('claimedToday uses local date and markClaimed persists', () {
      final c = DailyClaimConfig();
      expect(c.claimedToday('k1'), isFalse);
      c.markClaimed('k1');
      expect(c.claimedToday('k1'), isTrue);
      c.clearClaimed('k1');
      expect(c.claimedToday('k1'), isFalse);
    });
  });

  group('BrowserRegistry', () {
    test('never lists a browser whose data dir is absent', () {
      final tmp = Directory.systemTemp.createTempSync('agr-registry-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      expect(BrowserRegistry.detect(homeDir: tmp.path), isEmpty);
    });

    test('detects a browser when its data dir exists', () {
      final tmp = Directory.systemTemp.createTempSync('agr-registry-');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final braveDir =
          Directory('${tmp.path}/.config/BraveSoftware/Brave-Browser')
            ..createSync(recursive: true);
      final brave = BrowserRegistry.detect(homeDir: tmp.path)
          .where((b) => b.id == 'brave' && b.dataDir == braveDir.path)
          .toList();
      expect(brave, hasLength(1));
    });
  });

  group('DailyClaimDetector', () {
    DailyClaimJsonFetch stub(Map<String, Map<String, dynamic>> responses) {
      return (path, headers) async {
        for (final entry in responses.entries) {
          if (path == entry.key || path.startsWith('${entry.key}?')) {
            return entry.value;
          }
        }
        return const {};
      };
    }

    test('confirmed when billing delta sits inside the window', () async {
      final config = DailyClaimConfig(expectedAmount: 25.0, tolerance: 2.0);
      final d = DailyClaimDetector(
          stub({
            '/v1/dashboard/billing/subscription': {'hard_limit_usd': 24.5},
          }),
          config);
      final r = await d.check(credentialId: 'k', apiKey: 'sk-x');
      expect(r.isConfirmed, isTrue);
      expect(r.detail, contains('window'));
    });

    test('not claimed when delta sits outside the window', () async {
      final config = DailyClaimConfig(expectedAmount: 25.0, tolerance: 2.0);
      final d = DailyClaimDetector(
          stub({
            '/v1/dashboard/billing/subscription': {'hard_limit_usd': 1.0},
          }),
          config);
      final r = await d.check(credentialId: 'k', apiKey: 'sk-x');
      expect(r.isNotClaimed, isTrue);
    });

    test('unknown (not confirmed) on the unlimited sentinel', () async {
      final config = DailyClaimConfig();
      final d = DailyClaimDetector(
          stub({
            '/v1/dashboard/billing/subscription': {'hard_limit_usd': 100000000},
          }),
          config);
      final r = await d.check(credentialId: 'k', apiKey: 'sk-x');
      expect(r.isUnknown, isTrue);
    });

    test('log path wins over billing when session is present', () async {
      final config = DailyClaimConfig();
      final d = DailyClaimDetector(
          stub({
            '/api/log/self': {
              'data': {
                'items': [
                  {'type': 5, 'content': 'ignored'},
                  {'type': 4, 'content': '每日签到成功，增加额度 ＄25.000000'},
                ],
              },
            },
          }),
          config);
      final r = await d.check(
        credentialId: 'k',
        apiKey: 'sk-x',
        sessionCookie: 'abc',
        newApiUserId: '123',
      );
      expect(r.isConfirmed, isTrue);
      expect(r.detail, contains('log entry'));
    });

    test('already marked today short-circuits', () async {
      final config = DailyClaimConfig();
      config.markClaimed('k');
      final d = DailyClaimDetector(stub({}), config);
      final r = await d.check(credentialId: 'k', apiKey: 'sk-x');
      expect(r.isConfirmed, isTrue);
      expect(r.detail, contains('already marked'));
    });

    test('fetchQuotaWithSession reads quota from /api/user/self', () async {
      final config = DailyClaimConfig();
      final d = DailyClaimDetector(
          stub({
            '/api/user/self': {
              'data': {'quota': 100987074, 'used_quota': 91505424},
            },
          }),
          config);
      final usd = await d.fetchQuotaWithSession(
        apiKey: 'sk-x',
        sessionCookie: 'abc',
        newApiUserId: '353187',
      );
      // 100987074 / 500000 = 201.974148
      expect(usd, closeTo(201.974, 0.001));
    });

    test('fetchQuotaWithSession returns null on missing data', () async {
      final config = DailyClaimConfig();
      final d = DailyClaimDetector(stub({'/api/user/self': {'data': {}}}), config);
      final usd = await d.fetchQuotaWithSession(
        apiKey: 'sk-x',
        sessionCookie: 'abc',
        newApiUserId: '1',
      );
      expect(usd, isNull);
    });
  });
}
