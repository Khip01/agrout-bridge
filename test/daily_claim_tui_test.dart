import 'dart:convert';

import 'package:agrout_bridge/src/services/daily_claim_tui.dart';
import 'package:test/test.dart';

void main() {
  group('dailyClaimFetch adapter', () {
    test('billing path routes through getJson (Bearer auth only)', () async {
      final client = _FakeClient(
        billingSubscription: '{"hard_limit_usd":24.5}',
      );
      final fetch = dailyClaimFetch(client);
      final out = await fetch('/v1/dashboard/billing/subscription', {
        'Authorization': 'Bearer sk-test',
      });
      expect(out['hard_limit_usd'], 24.5);
      expect(client.lastAuth, 'Bearer sk-test');
      expect(client.lastPath, '/v1/dashboard/billing/subscription');
    });

    test('log path passes through extra session + new-api-user headers',
        () async {
      final client = _FakeClient(
        logSelf: '{"data":{"items":[]}}',
      );
      final fetch = dailyClaimFetch(client);
      final out = await fetch(
          '/api/log/self?start_timestamp=1&end_timestamp=2', {
        'Authorization': 'Bearer sk-test',
        'Cookie': 'session=abc',
        'New-API-User': '353187',
      });
      expect(out['data'], isNotNull);
      expect(client.lastHeaders!['Cookie'], 'session=abc');
      expect(client.lastHeaders!['New-API-User'], '353187');
    });

    test('log path non-200 throws', () async {
      final client = _FakeClient(
        logSelf: '{"message":"no"}',
        logStatus: 404,
      );
      final fetch = dailyClaimFetch(client);
      await expectLater(
        fetch('/api/log/self', const {}),
        throwsA(isA<HttpAdapterExceptionFromCode>()),
      );
    });
  });
}

class _FakeClient implements DailyClaimHttpClient {
  final String billingSubscription;
  final String logSelf;
  final int logStatus;
  String? lastPath;
  String? lastAuth;
  Map<String, String>? lastHeaders;

  _FakeClient({
    this.billingSubscription = '{}',
    this.logSelf = '{"data":{"items":[]}}',
    this.logStatus = 200,
  });

  @override
  Future<Map<String, dynamic>> getJson({
    required String path,
    required String authHeader,
  }) async {
    lastPath = path;
    lastAuth = authHeader;
    return jsonDecode(billingSubscription) as Map<String, dynamic>;
  }

  @override
  Future<DailyClaimHttpResponse> send({
    required String method,
    required String path,
    required Map<String, String> extraHeaders,
  }) async {
    lastPath = path;
    lastHeaders = extraHeaders;
    return DailyClaimHttpResponse(logStatus, logSelf);
  }
}