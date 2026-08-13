/// Direct HTTP client for `agentrouter.org` (New API fork).
///
/// Owns three concerns:
/// 1. The Claude Code header fingerprint that the upstream client-detection
///    gate enforces — see `spoof.dart`.
/// 2. The WAF cookie jar (`acw_tc` and rotated siblings) — see `waf.dart`.
///    The jar is passed in by the caller so the same cookies can be reused
///    across requests and persisted into the active profile on success.
/// 3. Auth header injection: chat keys go into `Authorization: Bearer` or
///    `x-api-key`; session tokens (captured from the local sign-in flow)
///    also go into `Authorization: Bearer`.
///
/// Streaming responses (chat completions / messages with `stream:true`) are
/// returned as a raw `HttpClientResponse` so the SSE pump in `server/sse.dart`
/// can drive backpressure and the format-aware terminator.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'spoof.dart';
import 'waf.dart';

/// Server endpoints known to the bridge.
class AgentRouterPaths {
  static const models = '/v1/models';
  static const chatCompletions = '/v1/chat/completions';
  static const messages = '/v1/messages';
  static const login = '/api/user/login';
  static const oauthState = '/api/oauth/state';
  static const userSelf = '/api/user/self';
  static const userSubscription = '/api/user/subscription';
  static const userDashboard = '/api/user/dashboard';
}

/// Successful warmup result: the merged cookie map (freshly captured WAF
/// cookies merged with whatever the caller already had).
class WarmupResult {
  final Map<String, String> cookies;
  final int statusCode;
  WarmupResult(this.cookies, this.statusCode);
}

/// Result of exchanging a provider OAuth code. [sessionToken] is populated
/// from the session cookie New API issues on the callback.
class OauthExchangeResult {
  final bool success;
  final String? sessionToken;
  final Map<String, dynamic>? accountInfo;
  final String? message;
  final int statusCode;
  OauthExchangeResult({
    required this.success,
    this.sessionToken,
    this.accountInfo,
    this.message,
    required this.statusCode,
  });
}

/// Extract the session token from a `Set-Cookie` header list (New API names
/// it `session-token`). Returns null when absent.
String? extractSessionCookie(List<String>? setCookie) {
  if (setCookie == null) return null;
  for (final raw in setCookie) {
    final pair = raw.split(';').first;
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    if (name.toLowerCase() == 'session-token' || name.toLowerCase() == 'session_token') {
      final v = pair.substring(eq + 1).trim();
      if (v.isNotEmpty) return v;
    }
  }
  return null;
}

/// Result of `POST /api/user/login`. Either [success] is true and
/// [sessionToken] is populated, or [success] is false and [message] carries
/// the upstream text (often in Chinese on New API).
class LoginResult {
  final bool success;
  final String? sessionToken;
  final String? message;
  final int statusCode;
  final Map<String, String> cookies;
  LoginResult({
    required this.success,
    this.sessionToken,
    this.message,
    required this.statusCode,
    required this.cookies,
  });
}

/// The HTTP client itself. One instance per process is fine; the underlying
/// `HttpClient` keeps connections alive.
class AgentRouterClient {
  final String baseUrl;
  final HttpClient _http;

  AgentRouterClient({String? baseUrl, Duration? timeout})
      : baseUrl = baseUrl ?? 'https://agentrouter.org',
        _http = HttpClient()
          ..connectionTimeout = timeout ?? const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 30)
          ..userAgent = warmupUserAgent;

  void close() {
    _http.close(force: true);
  }

  /// Warmup probe: `GET /` with browser-like headers (no API key). Returns
  /// the merged WAF cookie jar (caller-supplied `existingCookies` + any
  /// fresh ones captured from `Set-Cookie`).
  ///
  /// The upstream often returns a 3xx redirect or 400/404 on this root path
  /// when the edge rejects the visitor fingerprint; we still want the
  /// `Set-Cookie` from that response. Don't gate on the status code here —
  /// callers should treat the cookie jar as the result and retry real API
  /// calls.
  Future<WarmupResult> warmup({Map<String, String>? existingCookies}) async {
    final req = await _http.getUrl(Uri.parse('$baseUrl/'));
    req.headers.clear();
    warmupHeaders.forEach((k, v) => req.headers.set(k, v));
    final cookie = serializeCookieHeader(existingCookies);
    if (cookie != null) req.headers.set('Cookie', cookie);

    final resp = await req.close();
    // Drain the body so the socket returns to the pool.
    try {
      await resp.drain<void>();
    } catch (_) {}

    final fresh = extractWafCookiePairs(resp.headers['set-cookie']);
    final merged = mergeWafCookies(existingCookies ?? const <String, String>{}, fresh);
    return WarmupResult(merged, resp.statusCode);
  }

  /// Build the base header set for a proxied request. Caller adds auth +
  /// `Cookie` afterwards (we never overwrite their values).
  Map<String, String> _baseHeaders({required bool anthropicPath}) {
    final out = Map<String, String>.from(genericSpoofHeaders);
    if (anthropicPath) out.addAll(anthropicSpoofHeaders);
    return out;
  }

  /// Low-level: send a single request. The caller supplies auth + cookie
  /// headers; we fill in the spoof and content type. Returns the raw
  /// `HttpClientResponse` so streaming callers can drive it.
  Future<HttpClientResponse> send({
    required String method,
    required String path,
    required Map<String, String> extraHeaders,
    Uint8List? body,
    bool anthropicPath = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final req = await _http.openUrl(method, uri);
    final headers = _baseHeaders(anthropicPath: anthropicPath);
    if (body != null) headers['Content-Type'] = 'application/json';
    headers.addAll(extraHeaders);
    headers.forEach((k, v) {
      // HttpHeaders is case-insensitive; set replaces, add appends.
      if (k.toLowerCase() == 'cookie') {
        req.headers.add('Cookie', v);
      } else {
        req.headers.set(k, v);
      }
    });
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    return req.close();
  }

  // ── JSON convenience wrappers ───────────────────────────────────────

  /// GET a JSON endpoint. Returns parsed body on success, throws on non-2xx.
  Future<Map<String, dynamic>> getJson({
    required String path,
    required String authHeader, // `Authorization: Bearer sk-...`
    Map<String, String>? cookies,
    bool anthropicPath = false,
  }) async {
    final resp = await send(
      method: 'GET',
      path: path,
      anthropicPath: anthropicPath,
      extraHeaders: {
        'Authorization': authHeader,
        if (serializeCookieHeader(cookies) != null) 'Cookie': serializeCookieHeader(cookies)!,
        'Accept': 'application/json',
      },
    );
    final raw = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('GET $path failed: ${resp.statusCode} $raw');
    }
    final parsed = jsonDecode(raw);
    if (parsed is! Map) throw HttpException('GET $path: expected JSON object, got ${parsed.runtimeType}');
    return parsed.cast<String, dynamic>();
  }

  /// POST a JSON body and return the parsed response.
  Future<Map<String, dynamic>> postJson({
    required String path,
    required String authHeader,
    required String body,
    Map<String, String>? cookies,
    bool anthropicPath = false,
  }) async {
    final resp = await send(
      method: 'POST',
      path: path,
      anthropicPath: anthropicPath,
      body: Uint8List.fromList(utf8.encode(body)),
      extraHeaders: {
        'Authorization': authHeader,
        if (serializeCookieHeader(cookies) != null) 'Cookie': serializeCookieHeader(cookies)!,
        'Accept': 'application/json',
      },
    );
    final raw = await resp.transform(utf8.decoder).join();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('POST $path failed: ${resp.statusCode} $raw');
    }
    final parsed = jsonDecode(raw);
    if (parsed is! Map) throw HttpException('POST $path: expected JSON object, got ${parsed.runtimeType}');
    return parsed.cast<String, dynamic>();
  }

  // ── High-level endpoints ────────────────────────────────────────────

  /// `GET /v1/models` — returns the list of model ids the chat key can use.
  Future<List<String>> fetchModels({
    required String apiKey,
    Map<String, String>? cookies,
  }) async {
    final resp = await getJson(
      path: AgentRouterPaths.models,
      authHeader: 'Bearer $apiKey',
      cookies: cookies,
    );
    final data = resp['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((m) => m['id']?.toString())
        .whereType<String>()
        .toList(growable: false);
  }

  /// `POST /api/user/login` — warmup the cookie jar first, then carry those
  /// cookies into the login POST so the upstream CSRF / first-party checks
  /// see a normal visitor session.
  Future<LoginResult> login({
    required String username,
    required String password,
    Map<String, String>? cookies,
  }) async {
    final jar = (await warmup(existingCookies: cookies)).cookies;
    final resp = await send(
      method: 'POST',
      path: AgentRouterPaths.login,
      body: Uint8List.fromList(utf8.encode(jsonEncode({'username': username, 'password': password}))),
      extraHeaders: {
        'Origin': baseUrl,
        'Referer': '$baseUrl/',
        'Accept': 'application/json',
        if (serializeCookieHeader(jar) != null) 'Cookie': serializeCookieHeader(jar)!,
      },
    );
    final raw = await resp.transform(utf8.decoder).join();
    final jarAfter = mergeWafCookies(jar, extractWafCookiePairs(resp.headers['set-cookie']));

    // New API typically returns {success:bool, data:{token:'sk-...'}, message:''}.
    // Older one-api forks nest under {success, data, message} with the token
    // at data.token. Some endpoints return the token at the top level.
    String? token;
    String? message;
    bool success = false;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        success = parsed['success'] == true;
        message = parsed['message']?.toString();
        final data = parsed['data'];
        if (data is Map && data['token'] is String) token = data['token'] as String;
        // Edge case: token at top level.
        token ??= parsed['token']?.toString();
      }
    } catch (_) {
      // Body wasn't JSON; surface upstream status + raw text.
      message = raw.isEmpty ? 'HTTP ${resp.statusCode}' : raw;
    }

    if (resp.statusCode == 200 && token == null && !success) {
      message ??= raw;
    }

    return LoginResult(
      success: token != null,
      sessionToken: token,
      message: message,
      statusCode: resp.statusCode,
      cookies: jarAfter,
    );
  }

  /// `GET /api/status` — site-level OAuth configuration. AgentRouter only
  /// supports provider sign-in (GitHub / LinuxDO / optional OIDC); there is
  /// no username+password registration, so the local sign-in flow must open
  /// the provider authorize URL instead of posting credentials.
  Future<Map<String, dynamic>> fetchOauthConfig() async {
    final raw = await send(
      method: 'GET',
      path: '/api/status',
      extraHeaders: const {},
    );
    final body = await raw.transform(utf8.decoder).join();
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map && parsed['data'] is Map) {
        return (parsed['data'] as Map).cast<String, dynamic>();
      }
      if (parsed is Map) return parsed.cast<String, dynamic>();
    } catch (_) {}
    return const {};
  }

  /// `GET /api/oauth/state?mode=login` — returns the signed state token that
  /// must be carried into the provider authorize URL.
  Future<String?> fetchOauthState() async {
    final raw = await send(
      method: 'GET',
      path: '${AgentRouterPaths.oauthState}?mode=login',
      extraHeaders: const {},
    );
    final body = await raw.transform(utf8.decoder).join();
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map) {
        final data = parsed['data'];
        if (data is String && data.isNotEmpty) return data;
      }
    } catch (_) {}
    return null;
  }

  /// `GET /api/user/self`. Auth via session token from login.
  Future<Map<String, dynamic>> fetchSelf({
    required String sessionToken,
    Map<String, String>? cookies,
  }) async {
    return getJson(
      path: AgentRouterPaths.userSelf,
      authHeader: 'Bearer $sessionToken',
      cookies: cookies,
    );
  }

  /// `GET /api/oauth/<provider>?code=...&state=...&mode=login` — exchange a
  /// provider OAuth code (from a redirect_uri bounce-back) for the session
  /// payload. The response `data` is the user object, and the session token
  /// is available from the `Set-Cookie` headers (New API issues it as a
  /// session cookie). This lets the local bridge complete a full provider
  /// sign-in without any manual paste.
  Future<OauthExchangeResult> exchangeOauthCode({
    required String code,
    required String state,
  }) async {
    final resp = await send(
      method: 'GET',
      path: '/api/oauth/github?code=$code&state=$state&mode=login',
      extraHeaders: const {},
    );
    final body = await resp.transform(utf8.decoder).join();

    // New API issues the session via `Set-Cookie` on this callback.
    String? sessionToken = extractSessionCookie(resp.headers['set-cookie']);
    Map<String, dynamic>? info;
    String? message;
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map) {
        if (parsed['success'] != true) {
          message = parsed['message']?.toString() ?? 'OAuth exchange failed';
        }
        final data = parsed['data'];
        if (data is Map) info = data.cast<String, dynamic>();
        final tok = data is Map ? data['token']?.toString() : null;
        sessionToken ??= tok;
      }
    } catch (_) {
      message = body.isEmpty ? 'HTTP ${resp.statusCode}' : body;
    }

    return OauthExchangeResult(
      success: sessionToken != null && message == null,
      sessionToken: sessionToken,
      accountInfo: info,
      message: message,
      statusCode: resp.statusCode,
    );
  }

  Future<Map<String, dynamic>> fetchSubscription({
    required String sessionToken,
    Map<String, String>? cookies,
  }) async {
    return getJson(
      path: AgentRouterPaths.userSubscription,
      authHeader: 'Bearer $sessionToken',
      cookies: cookies,
    );
  }

  Future<Map<String, dynamic>> fetchDashboard({
    required String sessionToken,
    Map<String, String>? cookies,
  }) async {
    return getJson(
      path: AgentRouterPaths.userDashboard,
      authHeader: 'Bearer $sessionToken',
      cookies: cookies,
    );
  }
}
