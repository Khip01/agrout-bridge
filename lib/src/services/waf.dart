/// WAF cookie jar: parse, merge, serialize the edge session cookies
/// (`acw_tc` and its rotated siblings) that the upstream AgentRouter
/// Alibaba Cloud edge assigns. The bridge carries these on every proxied
/// request as `Cookie:`. Without the cookie, the first request from a fresh
/// IP typically still passes (the gate is header-driven), but rotated
/// cookies help avoid a follow-up WAF challenge on heavy traffic.
///
/// Pure functions only: no I/O. The actual HTTP warmup lives in
/// `api_client.dart`; this file only knows how to parse the Set-Cookie
/// payload the warmup captures and how to merge new values into a profile's
/// existing cookie map.
library;

const Set<String> wafCookieNames = {
  'acw_tc',
  'acw_sc__v2',
  'acw_sc__v3',
  'cdn_sec_tc',
};

/// Serialize a `{name: value}` cookie map to the `Cookie:` header value.
/// Empty input returns `null` so callers can skip the header entirely.
String? serializeCookieHeader(Map<String, String>? cookies) {
  if (cookies == null || cookies.isEmpty) return null;
  return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Parse a Set-Cookie list (the raw `set-cookie` value, which may be a
/// string or a list of strings) and return only the WAF cookies with
/// non-empty values. Empty / expired cookies are skipped because shipping
/// an empty value in `Cookie:` is treated by the upstream WAF as a failed
/// challenge (worse than no cookie at all).
List<String> extractWafCookiePairs(dynamic setCookieHeader) {
  if (setCookieHeader == null) return const [];
  final raw = setCookieHeader is List ? setCookieHeader : <String>[setCookieHeader.toString()];
  final out = <String>[];
  for (final c in raw) {
    final s = c.toString();
    final pair = s.split(';').first;
    final eq = pair.indexOf('=');
    if (eq < 1) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (!wafCookieNames.contains(name) || value.isEmpty) continue;
    out.add('$name=$value');
  }
  return out;
}

/// Merge `fresh` cookie pairs into `current`, keyed by cookie name.
/// Returns a NEW map; `current` is not mutated. A fresh value for an
/// existing name replaces the old one; unrelated names are preserved.
Map<String, String> mergeWafCookies(Map<String, String> current, List<String> freshPairs) {
  final out = Map<String, String>.from(current);
  for (final pair in freshPairs) {
    final eq = pair.indexOf('=');
    if (eq < 1) continue;
    out[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
  }
  return out;
}

/// Returns true when [statusCode] from the upstream is a WAF block that the
/// bridge should retry after a fresh cookie capture.
bool isWafBlockStatus(int statusCode) {
  return statusCode == 401 || statusCode == 403 || statusCode == 405;
}
