import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import 'api_client.dart';

/// Outcome of a login attempt (driven from either the local page or the
/// in-app paste-session-token fallback).
class LoginOutcome {
  final bool success;
  final String? sessionToken;
  final String? username;
  final String? message;
  final Map<String, dynamic>? accountInfo;
  const LoginOutcome({
    required this.success,
    this.sessionToken,
    this.username,
    this.message,
    this.accountInfo,
  });
}

/// Local sign-in flow: serves a tiny HTML form on 127.0.0.1, relays the
/// submitted credentials to `POST /api/user/login`, captures the session
/// token, stores it on the active profile, and (best effort) fetches the
/// dashboard profile into `accountInfo`.
///
/// The page is opened by the user via a copyable URL (the TUI surfaces it
/// on `[l]` / `profile login`); nothing leaves the machine except the
/// single POST to `agentrouter.org` carrying the warmup cookie jar.
class LoginFlow {
  final AgentRouterClient client;
  LoginFlow(this.client);

  HttpServer? _server;
  String? _url;
  String? get url => _url;

  /// Start the local server. If [preferredPort] is 0 (default) the kernel
  /// picks any free port. Call [stop] when the panel is closed or the
  /// login window expires.
  Future<String> start({
    int preferredPort = 0,
    required void Function(LoginOutcome outcome) onResult,
    Duration ttl = const Duration(minutes: 10),
  }) async {
    if (_server != null) return _url!;
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, preferredPort);
    _server = s;
    _url = 'http://127.0.0.1:${s.port}/login';
    Timer(ttl, () => stop());
    s.listen((req) => _handle(req, onResult));
    return _url!;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _url = null;
    await s?.close(force: true);
  }

  Future<void> _handle(HttpRequest req, void Function(LoginOutcome) onResult) async {
    final path = req.uri.path;
    try {
      if (req.method == 'GET' && path == '/login') {
        req.response.headers.contentType = ContentType.html;
        await _servePage(req);
        return;
      }
      if (req.method == 'POST' && path == '/login') {
        await _handleSubmit(req, onResult);
        return;
      }
      if (req.method == 'GET' && path == '/success') {
        req.response.headers.contentType = ContentType.html;
        await _serveSuccess(req);
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    } catch (_) {
      try { await req.response.close(); } catch (_) {}
    }
  }

  Future<void> _servePage(HttpRequest req) async {
    final body = _loginHtml;
    final bytes = utf8.encode(body);
    req.response.headers.contentType = ContentType.html;
    req.response.headers.contentLength = bytes.length;
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _handleSubmit(HttpRequest req, void Function(LoginOutcome) onResult) async {
    final raw = <int>[];
    await for (final chunk in req) {
      raw.addAll(chunk);
    }
    Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(utf8.decode(raw));
    } catch (_) {
      _redirectWithError(req, 'bad form data');
      return;
    }
    final username = fields['username'] ?? '';
    final password = fields['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      _redirectWithError(req, 'username and password required');
      return;
    }

    final result = await client.login(username: username, password: password);
    if (!result.success || result.sessionToken == null) {
      _redirectWithError(req, result.message ?? 'login failed');
      onResult(LoginOutcome(
        success: false,
        message: result.message ?? 'login failed',
      ));
      return;
    }

    Map<String, dynamic>? info;
    String? user;
    try {
      final self = await client.fetchSelf(sessionToken: result.sessionToken!, cookies: result.cookies);
      info = self['data'] is Map ? (self['data'] as Map).cast<String, dynamic>() : self;
      user = info['username']?.toString() ?? info['display_name']?.toString();
    } catch (_) {
      // Soft failure: token works for API even if self failed.
    }

    onResult(LoginOutcome(
      success: true,
      sessionToken: result.sessionToken,
      username: user,
      accountInfo: info,
    ));

    req.response.statusCode = 303;
    req.response.headers.set('Location', '/success');
    await req.response.close();
  }

  Future<void> _serveSuccess(HttpRequest req) async {
    final body = _successHtml;
    final bytes = utf8.encode(body);
    req.response.headers.contentType = ContentType.html;
    req.response.headers.contentLength = bytes.length;
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.add(bytes);
    await req.response.close();
  }

  void _redirectWithError(HttpRequest req, String msg) {
    req.response.statusCode = 303;
    req.response.headers.set('Location', '/login?err=${Uri.encodeQueryComponent(msg)}');
    req.response.headers.contentLength = 0;
  }

  static const _loginHtml = '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>agrout-bridge sign-in</title>
<style>
body { font: 14px/1.5 -apple-system, system-ui, sans-serif; background:#0f1115; color:#d8d8d8; padding:32px; }
main { max-width:360px; margin:0 auto; }
h1 { font-size:16px; margin:0 0 16px; color:#7fd4ff; }
label { display:block; margin:12px 0 4px; color:#9aa3ad; }
input { width:100%; box-sizing:border-box; padding:8px; background:#1a1d23; color:#e8e8e8; border:1px solid #2a2f37; border-radius:4px; }
button { margin-top:18px; width:100%; padding:10px; background:#2a6df4; color:#fff; border:none; border-radius:4px; font-weight:600; cursor:pointer; }
.note { color:#7c8693; font-size:12px; margin-top:14px; }
.err { color:#ff7777; font-size:13px; margin-top:10px; }
</style></head><body><main>
<h1>agrout-bridge — AgentRouter sign-in</h1>
<form method="POST" action="/login">
  <label>Username / email</label>
  <input type="text" name="username" autofocus required>
  <label>Password</label>
  <input type="password" name="password" required>
  <button type="submit">Sign in</button>
</form>
<p class="note">This page is served from 127.0.0.1 by your running agrout-bridge process. Credentials are sent only to agentrouter.org.</p>
<script>
const p = new URLSearchParams(location.search);
if (p.get('err')) {
  const n = document.createElement('p'); n.className='err'; n.textContent = p.get('err');
  document.querySelector('main').appendChild(n);
}
</script>
</main></body></html>
''';

  static const _successHtml = '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>agrout-bridge</title>
<style>
body { font:14px/1.5 system-ui,sans-serif; background:#0f1115; color:#d8d8d8; padding:32px; }
main { max-width:360px; margin:0 auto; }
h1 { color:#7fd4ff; font-size:16px; }
.note { color:#7c8693; font-size:12px; margin-top:18px; }
</style></head><body><main>
<h1>Login berhasil</h1>
<p>Session token tersimpan lokal di profil. Tutup tab ini dan kembali ke agrout-bridge.</p>
<p class="note">agrout-bridge</p>
</main></body></html>
''';
}

/// Save [outcome] onto [profile] (in place), persist via [ProfileStore].
void applyLoginOutcome(Profile profile, LoginOutcome outcome, ProfileStore store) {
  if (!outcome.success || outcome.sessionToken == null) return;
  final updated = profile.copyWith(
    authToken: outcome.sessionToken,
    authTokenAt: DateTime.now(),
    accountInfo: outcome.accountInfo ?? profile.accountInfo,
  );
  store.upsert(updated);
}
