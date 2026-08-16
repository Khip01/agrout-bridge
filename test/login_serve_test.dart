import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/services/api_client.dart';
import 'package:agrout_bridge/src/services/login.dart';
import 'package:test/test.dart';

void main() {
  test('LoginFlow serves a non-empty /login HTML body with a paste field', () async {
    final flow = LoginFlow(AgentRouterClient());
    String? captured;
    final url = await flow.start(onResult: (_) {});
    captured = url;
    expect(captured, startsWith('http://127.0.0.1:'));
    final parsed = Uri.parse(captured);
    final resp = await HttpClient().getUrl(parsed).then((r) => r.close());
    final body = await resp.transform(utf8.decoder).join();
    expect(resp.statusCode, 200, reason: 'status was ${resp.statusCode}');
    expect(body.length, greaterThan(200), reason: 'login HTML must include the page');
    expect(body, contains('agrout-bridge'));
    // API-key only: the page exposes a name field and a paste-token field,
    // never OAuth buttons (the provider session cannot be captured
    // automatically) and never a credential form.
    expect(body, contains('name="name"'));
    expect(body, contains('name="token"'));
    expect(body, contains('Add API key'));
    expect(body, isNot(contains('/oauth/')));
    expect(body, isNot(contains('name="username"')));
    expect(body, isNot(contains('name="password"')));
    await flow.stop();
  });

  test('unknown path returns 404', () async {
    final flow = LoginFlow(AgentRouterClient());
    final url = await flow.start(onResult: (_) {});
    final parsed = Uri.parse(url).replace(path: '/unknown');
    final resp = await HttpClient().getUrl(parsed).then((r) => r.close());
    expect(resp.statusCode, 404);
    await flow.stop();
  });

  test('POST /login/token validates against /v1/models and sets apiKey', () async {
    // Mock agentrouter: /v1/models accepts the key and returns a model list.
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mock.listen((req) {
      if (req.uri.path == '/v1/models') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"data":[{"id":"claude-opus-4-8"},{"id":"claude-sonnet-4-5"}]}');
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });

    final flow = LoginFlow(AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}'));
    LoginOutcome? outcome;
    final url = await flow.start(onResult: (o) => outcome = o);
    final parsed = Uri.parse(url);

    final sock = await Socket.connect(parsed.host, parsed.port);
    sock.write('POST /login/token HTTP/1.1\r\nHost: ${parsed.host}:${parsed.port}\r\n'
        'Content-Type: application/x-www-form-urlencoded\r\n'
        'Content-Length: ${'name=work&token=sk-testkey'.length}\r\nConnection: close\r\n\r\n'
        'name=work&token=sk-testkey');
    await for (final _ in sock) {}
    await sock.close();

    expect(outcome, isNotNull);
    expect(outcome!.success, isTrue);
    expect(outcome!.apiKey, 'sk-testkey');
    expect(outcome!.keyName, 'work');
    await flow.stop();
    await mock.close(force: true);
  });

  test('POST /login/token saves a key without a name', () async {
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mock.listen((req) {
      if (req.uri.path == '/v1/models') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"data":[{"id":"m1"}]}');
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });

    final flow = LoginFlow(AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}'));
    LoginOutcome? outcome;
    final url = await flow.start(onResult: (o) => outcome = o);
    final parsed = Uri.parse(url);

    final sock = await Socket.connect(parsed.host, parsed.port);
    sock.write('POST /login/token HTTP/1.1\r\nHost: ${parsed.host}:${parsed.port}\r\n'
        'Content-Type: application/x-www-form-urlencoded\r\n'
        'Content-Length: ${'token=sk-noname'.length}\r\nConnection: close\r\n\r\n'
        'token=sk-noname');
    await for (final _ in sock) {}
    await sock.close();

    expect(outcome!.success, isTrue);
    expect(outcome!.apiKey, 'sk-noname');
    expect(outcome!.keyName, isNull);
    await flow.stop();
    await mock.close(force: true);
  });

  test('POST /login/token rejects a key /v1/models does not honour', () async {
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mock.listen((req) {
      if (req.uri.path == '/v1/models') {
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"error":{"message":"invalid api key"}}');
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });

    final flow = LoginFlow(AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}'));
    LoginOutcome? outcome;
    final url = await flow.start(onResult: (o) => outcome = o);
    final parsed = Uri.parse(url);

    final sock = await Socket.connect(parsed.host, parsed.port);
    sock.write('POST /login/token HTTP/1.1\r\nHost: ${parsed.host}:${parsed.port}\r\n'
        'Content-Type: application/x-www-form-urlencoded\r\n'
        'Content-Length: ${'token=sk-bad'.length}\r\nConnection: close\r\n\r\n'
        'token=sk-bad');
    await for (final _ in sock) {}
    await sock.close();

    expect(outcome, isNotNull);
    expect(outcome!.success, isFalse);
    expect(outcome!.message, contains('rejected'));
    await flow.stop();
    await mock.close(force: true);
  });
}