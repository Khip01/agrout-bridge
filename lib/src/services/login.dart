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

/// Local sign-in flow: serves a tiny HTML page on 127.0.0.1 that redirects
/// to the provider OAuth (GitHub / LinuxDO) authorize URL and accepts a
/// pasted session token / API key. AgentRouter has no username/password
/// registration, so credentials login is not offered. The pasted token is
/// stored on the active profile and (best effort) verified against the
/// dashboard via `GET /api/user/self`.
///
/// The page is opened by the user via a copyable URL (the TUI surfaces it
/// on `[l]` / `profile login`); nothing leaves the machine except the
/// OAuth state/config lookups to `agentrouter.org`.
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
      if (req.method == 'GET' && (path == '/oauth/github' || path == '/oauth/linuxdo')) {
        await _handleOAuth(path == '/oauth/linuxdo', req);
        return;
      }
      if (req.method == 'POST' && path == '/login/token') {
        await _handleTokenSubmit(req, onResult);
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

  /// Redirect the user's browser to the provider authorize URL. AgentRouter
  /// has no username/password registration, so the only working sign-in path
  /// is provider OAuth (GitHub or LinuxDO). We fetch the signed state token
  /// from `/api/oauth/state` and the client ids from `/api/status`, then 302
  /// to the provider. The provider redirects back to agentrouter.org which
  /// issues the session; the user then pastes their session token / API key
  /// back into the local page (see [_handleTokenSubmit]) since the bridge
  /// cannot read the provider cookie set on the agentrouter.org domain.
  Future<void> _handleOAuth(bool linuxdo, HttpRequest req) async {
    final state = await client.fetchOauthState();
    if (state == null) {
      _redirectWithError(req, 'failed to obtain OAuth state from agentrouter.org');
      return;
    }
    final cfg = await client.fetchOauthConfig();
    final clientId = linuxdo ? cfg['linuxdo_client_id']?.toString() : cfg['github_client_id']?.toString();
    if (clientId == null || clientId.isEmpty) {
      _redirectWithError(req, linuxdo ? 'LinuxDO sign-in is not enabled' : 'GitHub sign-in is not enabled');
      return;
    }
    final url = linuxdo
        ? 'https://connect.linux.do/oauth2/authorize?response_type=code&client_id=$clientId&state=$state'
        : 'https://github.com/login/oauth/authorize?client_id=$clientId&state=$state&scope=user:email';
    req.response.statusCode = 302;
    req.response.headers.set('Location', url);
    await req.response.close();
  }

  /// Store a pasted session token (from the agentrouter.org dashboard /
  /// success page after completing provider OAuth in the browser) onto the
  /// active profile. This is the only reliable way for a local process to
  /// obtain an authenticated session: the OAuth cookie itself is set on the
  /// agentrouter.org domain and is never visible to 127.0.0.1.
  Future<void> _handleTokenSubmit(HttpRequest req, void Function(LoginOutcome) onResult) async {
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
    final token = (fields['token'] ?? '').trim();
    if (token.isEmpty) {
      _redirectWithError(req, 'session token required');
      return;
    }

    Map<String, dynamic>? info;
    String? user;
    String? message;
    try {
      final self = await client.fetchSelf(sessionToken: token);
      final data = self['data'];
      info = data is Map ? data.cast<String, dynamic>() : self;
      user = info['username']?.toString() ?? info['display_name']?.toString();
      if (self['success'] != true) {
        message = self['message']?.toString() ?? 'token rejected';
      }
    } catch (_) {
      message = 'could not verify token against agentrouter.org';
    }

    if (message != null) {
      _redirectWithError(req, message);
      onResult(LoginOutcome(success: false, message: message));
      return;
    }

    onResult(LoginOutcome(
      success: true,
      sessionToken: token,
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
main { max-width:420px; margin:0 auto; }
h1 { font-size:16px; margin:0 0 16px; color:#7fd4ff; }
p { color:#9aa3ad; margin:0 0 14px; }
a.btn { display:block; text-align:center; text-decoration:none; padding:10px; border-radius:4px; font-weight:600; margin:8px 0; }
.btn-github { background:#2a6df4; color:#fff; }
.btn-linuxdo { background:#1a1d23; border:1px solid #2a2f37; color:#e8e8e8; }
.sep { border-top:1px solid #2a2f37; margin:20px 0; }
label { display:block; margin:12px 0 4px; color:#9aa3ad; }
input { width:100%; box-sizing:border-box; padding:8px; background:#1a1d23; color:#e8e8e8; border:1px solid #2a2f37; border-radius:4px; }
button { margin-top:12px; width:100%; padding:10px; background:#2a6df4; color:#fff; border:none; border-radius:4px; font-weight:600; cursor:pointer; }
.note { color:#7c8693; font-size:12px; margin-top:14px; }
.err { color:#ff7777; font-size:13px; margin-top:10px; }
</style></head><body><main>
<h1>agrout-bridge — AgentRouter sign-in</h1>
<p>AgentRouter accounts are created through GitHub or LinuxDO OAuth only.
Sign in with a provider, then paste your session token back here.</p>
<a class="btn btn-github" href="/oauth/github">Sign in with GitHub</a>
<a class="btn btn-linuxdo" href="/oauth/linuxdo">Sign in with LinuxDO</a>
<div class="sep"></div>
<form method="POST" action="/login/token">
  <label>Session token / API key (sk-...)</label>
  <input type="password" name="token" placeholder="paste token after provider sign-in" required>
  <button type="submit">Save token</button>
</form>
<p class="note">This page is served from 127.0.0.1 by your running agrout-bridge process. Provider OAuth happens in the agentrouter.org browser flow; the bridge cannot read the agentrouter session cookie, so the token is pasted manually.</p>
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
