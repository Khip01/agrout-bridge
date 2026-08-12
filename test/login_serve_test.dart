import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/services/api_client.dart';
import 'package:agrout_bridge/src/services/login.dart';
import 'package:test/test.dart';

void main() {
  test('LoginFlow serves a non-empty /login HTML body', () async {
    final flow = LoginFlow(AgentRouterClient());
    String? captured;
    final url = await flow.start(onResult: (_) {});
    captured = url;
    expect(captured, startsWith('http://127.0.0.1:'));
    final parsed = Uri.parse(captured);
    final resp = await HttpClient().getUrl(parsed).then((r) => r.close());
    final body = await resp.transform(utf8.decoder).join();
    expect(resp.statusCode, 200, reason: 'status was ${resp.statusCode}');
    expect(body.length, greaterThan(200), reason: 'login HTML must include the form');
    expect(body, contains('agrout-bridge'));
    expect(body, contains('name="username"'));
    expect(body, contains('name="password"'));
    await flow.stop();
  });
}
