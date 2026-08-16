/// Direct HTTP client for `agentrouter.org` (New API fork).
///
/// Owns three concerns:
/// 1. The Claude Code header fingerprint that the upstream client-detection
///    gate enforces (see `spoof.dart`).
/// 2. The WAF cookie jar (`acw_tc` and rotated siblings), see `waf.dart`.
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
  static const billingSubscription = '/v1/dashboard/billing/subscription';
  static const billingUsage = '/v1/dashboard/billing/usage';
}

/// Successful warmup result: the merged cookie map (freshly captured WAF
/// cookies merged with whatever the caller already had).
class WarmupResult {
  final Map<String, String> cookies;
  final int statusCode;
  WarmupResult(this.cookies, this.statusCode);
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
  /// `Set-Cookie` from that response. Don't gate on the status code here.
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

  /// `GET /v1/models` returns the list of model ids the chat key can use.
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

  /// `GET /v1/dashboard/billing/subscription`: the OpenAI-style billing
  /// endpoint that New API panels expose to a plain API key (no session
  /// token needed). Returns quota limits (soft_limit_usd / hard_limit_usd).
  Future<Map<String, dynamic>> fetchBillingSubscription({
    required String apiKey,
  }) async {
    return getJson(
      path: AgentRouterPaths.billingSubscription,
      authHeader: 'Bearer $apiKey',
    );
  }

  /// `GET /v1/dashboard/billing/usage?start_date&end_date`: OpenAI-style
  /// usage endpoint that New API panels expose to a plain API key. Returns
  /// `total_usage` (aggregate) and per-date `daily_costs` when present.
  Future<Map<String, dynamic>> fetchBillingUsage({
    required String apiKey,
    required String startDate,
    required String endDate,
  }) async {
    return getJson(
      path: '${AgentRouterPaths.billingUsage}?start_date=$startDate&end_date=$endDate',
      authHeader: 'Bearer $apiKey',
    );
  }

}
