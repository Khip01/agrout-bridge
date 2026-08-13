import 'dart:io';

import 'package:agrout_bridge/src/services/api_client.dart';
import 'package:test/test.dart';

void main() {
  test('fetchBillingSubscription sends Bearer key to /v1/dashboard/billing/subscription', () async {
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? authHeader;
    mock.listen((req) async {
      expect(req.uri.path, '/v1/dashboard/billing/subscription');
      authHeader = req.headers.value(HttpHeaders.authorizationHeader);
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"object":"billing_subscription","soft_limit_usd":100000000}');
      await req.response.close();
    });

    final client = AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}');
    final res = await client.fetchBillingSubscription(apiKey: 'sk-test');
    expect(authHeader, 'Bearer sk-test');
    expect(res['soft_limit_usd'], 100000000);
    await mock.close(force: true);
  });

  test('fetchBillingUsage sends date range + returns total_usage', () async {
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? authHeader;
    mock.listen((req) async {
      expect(req.uri.path, '/v1/dashboard/billing/usage');
      expect(req.uri.queryParameters['start_date'], '2026-07-14');
      expect(req.uri.queryParameters['end_date'], '2026-08-13');
      authHeader = req.headers.value(HttpHeaders.authorizationHeader);
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"object":"list","total_usage":213.1132}');
      await req.response.close();
    });

    final client = AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}');
    final res = await client.fetchBillingUsage(
      apiKey: 'sk-test',
      startDate: '2026-07-14',
      endDate: '2026-08-13',
    );
    expect(authHeader, 'Bearer sk-test');
    expect(res['total_usage'], 213.1132);
    await mock.close(force: true);
  });
}
