import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import 'api_client.dart';

/// Outcome of a login attempt. [apiKey] carries a pasted API key validated
/// against `/v1/models`; [keyName] is the optional human label entered in
/// the form. AgentRouter sign-in is OAuth-only and the bridge cannot
/// capture the provider session cookie automatically, so a profile is
/// API-key only; no session token or account info is tracked.
class LoginOutcome {
  final bool success;
  final String? apiKey;
  final String? keyName;
  final String? message;
  const LoginOutcome({
    required this.success,
    this.apiKey,
    this.keyName,
    this.message,
  });
}

/// Local sign-in flow: serves a tiny HTML page on 127.0.0.1 where the user
/// pastes an API key (`sk-...`) from the agentrouter.org dashboard. The key
/// is validated against `/v1/models` and stored on the active profile.
///
/// The page is opened by the user via a copyable URL (the TUI surfaces it
/// on `[l]` / `profile login`); nothing leaves the machine except the
/// model-list validation call to `agentrouter.org`.
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

  /// Store a pasted API key onto the active profile.
  ///
  /// AgentRouter authenticates proxying with the profile API key
  /// (`sk-...` from the dashboard). The pasted value is validated against
  /// `/v1/models` (the check that accepts a dashboard API key) before it is
  /// saved; account-info enrichment via session-token endpoints was removed
  /// because the bridge cannot capture a provider session cookie.
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
      _redirectWithError(req, 'API key required');
      return;
    }
    final keyName = (fields['name'] ?? '').trim();

    // Validation: /v1/models accepts dashboard API keys.
    List<String> models;
    try {
      models = await client.fetchModels(apiKey: token);
    } catch (_) {
      _redirectWithError(req, 'API key rejected by agentrouter.org');
      onResult(LoginOutcome(success: false, message: 'API key rejected by agentrouter.org'));
      return;
    }
    if (models.isEmpty) {
      _redirectWithError(req, 'API key rejected by agentrouter.org');
      onResult(LoginOutcome(success: false, message: 'API key rejected by agentrouter.org'));
      return;
    }

    onResult(LoginOutcome(
      success: true,
      apiKey: token,
      keyName: keyName.isEmpty ? null : keyName,
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
    req.response.close();
  }

  static const _loginHtml = '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>agrout-bridge sign-in</title>
<style>
body { font: 14px/1.5 -apple-system, system-ui, sans-serif; background:#0f1115; color:#d8d8d8; padding:32px; }
main { max-width:420px; margin:0 auto; }
h1 { font-size:16px; margin:0 0 16px; color:#7fd4ff; }
p { color:#9aa3ad; margin:0 0 14px; }
label { display:block; margin:12px 0 4px; color:#9aa3ad; }
input { width:100%; box-sizing:border-box; padding:8px; background:#1a1d23; color:#e8e8e8; border:1px solid #2a2f37; border-radius:4px; }
button { margin-top:12px; width:100%; padding:10px; background:#2a6df4; color:#fff; border:none; border-radius:4px; font-weight:600; cursor:pointer; }
.note { color:#7c8693; font-size:12px; margin-top:14px; }
.err { color:#ff7777; font-size:13px; margin-top:10px; }
</style></head><body><main>
  <h1>agrout-bridge | AgentRouter sign-in</h1>
<p>Paste the AgentRouter dashboard API key (`sk-...`) below. Give it an
optional name so you can recognise which key is in use. The bridge validates
it against /v1/models and saves it to the active profile.</p>
<form method="POST" action="/login/token">
  <label>Key name (optional)</label>
  <input type="text" name="name" placeholder="e.g. my-agentrouter-key">
  <label>API key (sk-...)</label>
  <input type="password" name="token" placeholder="paste API key from agentrouter.org dashboard" required>
  <button type="submit">Add API key</button>
</form>
<p class="note">This page is served from 127.0.0.1 by your running agrout-bridge process. Get a key from the agentrouter.org dashboard (sign in via GitHub/LinuxDO there, then create an API key). The bridge cannot capture the agentrouter session cookie automatically, so it never asks for a session token. The API key alone supports proxying and quota/usage display (Profile page).</p>
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
<h1>Sign-in successful</h1>
<p>Your API key has been saved to the active profile. You can close this tab and return to the agrout-bridge CLI or TUI.</p>
<p class="note">agrout-bridge</p>
</main></body></html>
''';
}

/// Save [outcome] onto [profile] (in place), persist via [ProfileStore].
/// A pasted API key overwrites the profile's [Profile.apiKey] and stamps
/// [Profile.apiKeyAt]; an optional key name renames the profile.
void applyLoginOutcome(Profile profile, LoginOutcome outcome, ProfileStore store) {
  if (!outcome.success || outcome.apiKey == null) return;
  final updated = profile.copyWith(
    apiKey: outcome.apiKey,
    apiKeyAt: DateTime.now(),
    name: outcome.keyName ?? profile.name,
  );
  store.upsert(updated);
}