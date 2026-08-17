import 'dart:convert';

import 'api_client.dart';
import 'daily_claim_detector.dart';

/// Raw HTTP response slice used by the adapter, so tests never reach into
/// `dart:io` internals.
class DailyClaimHttpResponse {
  final int statusCode;
  final String body;
  const DailyClaimHttpResponse(this.statusCode, this.body);
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

/// Minimal slice of the HTTP client that the adapter needs, so tests can fake
/// it without pulling in the real `dart:io` stack.
abstract interface class DailyClaimHttpClient {
  Future<Map<String, dynamic>> getJson({
    required String path,
    required String authHeader,
  });

  Future<DailyClaimHttpResponse> send({
    required String method,
    required String path,
    required Map<String, String> extraHeaders,
  });
}

/// Adapter from the real [AgentRouterClient] to [DailyClaimHttpClient].
class BridgedDailyClaimClient implements DailyClaimHttpClient {
  final AgentRouterClient _inner;
  BridgedDailyClaimClient(this._inner);

  @override
  Future<Map<String, dynamic>> getJson({
    required String path,
    required String authHeader,
  }) =>
      _inner.getJson(path: path, authHeader: authHeader);

  @override
  Future<DailyClaimHttpResponse> send({
    required String method,
    required String path,
    required Map<String, String> extraHeaders,
  }) async {
    final resp = await _inner.send(
        method: method, path: path, extraHeaders: extraHeaders);
    final body = await resp.transform(utf8.decoder).join();
    return DailyClaimHttpResponse(resp.statusCode, body);
  }
}

/// Adapter that turns a [DailyClaimHttpClient] into the injectable
/// [DailyClaimJsonFetch] used by [DailyClaimDetector].
///
/// Each call routes to the matching client method:
/// - `/v1/dashboard/billing/*` uses the OpenAI-style bearer auth (works with
///   an API key alone),
/// - `/api/log/self` needs the extra session + `New-API-User` headers, which
///   are passed through verbatim.
DailyClaimJsonFetch dailyClaimFetch(DailyClaimHttpClient client) {
  return (String path, Map<String, String> headers) async {
    if (path.contains('/api/')) {
      final resp = await client.send(
        method: 'GET',
        path: path,
        extraHeaders: headers,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpAdapterExceptionFromCode(resp.statusCode, resp.body);
      }
      return resp.json;
    }
    final auth = headers['Authorization'] ?? '';
    return client.getJson(path: path, authHeader: auth);
  };
}

class HttpAdapterExceptionFromCode implements Exception {
  final int statusCode;
  final dynamic body;
  HttpAdapterExceptionFromCode(this.statusCode, this.body);
  @override
  String toString() => 'HTTP $statusCode: $body';
}