import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/services/api_client.dart';
import 'package:agrout_bridge/src/services/login.dart';
import 'package:test/test.dart';

void main() {
  test('LoginFlow serves a non-empty /login HTML body with OAuth providers', () async {
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
    // AgentRouter has no username/password sign-up: the page must surface the
    // provider OAuth buttons plus the paste-token fallback, never a
    // credential form.
    expect(body, contains('/oauth/github'));
    expect(body, contains('/oauth/linuxdo'));
    expect(body, contains('name="token"'));
    expect(body, isNot(contains('name="username"')));
    expect(body, isNot(contains('name="password"')));
    await flow.stop();
  });

  test('unknown provider path returns 404', () async {
    final flow = LoginFlow(AgentRouterClient());
    final url = await flow.start(onResult: (_) {});
    final parsed = Uri.parse(url).replace(path: '/oauth/unknown');
    final resp = await HttpClient().getUrl(parsed).then((r) => r.close());
    expect(resp.statusCode, 404);
    await flow.stop();
  });

  test('GET /oauth/github redirects to GitHub authorize with state', () async {
    // Mock agentrouter.org: /api/status exposes the GitHub client id and
    // /api/oauth/state returns a signed state token.
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mock.listen((req) {
      if (req.uri.path == '/api/status') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            '{"data":{"github_client_id":"mockgithubid","github_oauth":true,"linuxdo_client_id":"","linuxdo_oauth":false}}');
      } else if (req.uri.path == '/api/oauth/state') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"data":"mock-state-token","success":true}');
      } else {
        req.response.statusCode = 404;
      }
      req.response.close();
    });

    final flow = LoginFlow(AgentRouterClient(baseUrl: 'http://127.0.0.1:${mock.port}'));
    final url = await flow.start(onResult: (_) {});
    final parsed = Uri.parse(url).replace(path: '/oauth/github');

    // Raw socket request: HttpClient would auto-follow the 302 to
    // github.com, so drive the redirect check manually with a single
    // HTTP/1.1 request and read the status line + Location header.
    final sock = await Socket.connect(parsed.host, parsed.port);
    sock.write('GET ${parsed.path} HTTP/1.1\r\nHost: ${parsed.host}:${parsed.port}\r\nConnection: close\r\n\r\n');
    final buf = <int>[];
    await for (final chunk in sock) {
      buf.addAll(chunk);
    }
    await sock.close();
    final head = utf8.decode(buf).split('\r\n').first;
    expect(head, contains('302'), reason: 'provider redirect must be a 302, got: $head');
    final loc = utf8
        .decode(buf)
        .split('\r\n')
        .firstWhere((l) => l.toLowerCase().startsWith('location:'),
            orElse: () => '')
        .split(': ')
        .skip(1)
        .join(': ');
    expect(loc, startsWith('https://github.com/login/oauth/authorize'));
    expect(loc, contains('client_id=mockgithubid'));
    expect(loc, contains('state=mock-state-token'));
    await flow.stop();
    await mock.close(force: true);
  });
}
