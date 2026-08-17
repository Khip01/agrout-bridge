import 'daily_claim.dart';

/// Fetches a JSON API response. Returns the parsed body on success, throws on
/// non-2xx. Injectable so tests never touch a real socket.
typedef DailyClaimJsonFetch = Future<Map<String, dynamic>> Function(
  String path,
  Map<String, String> headers,
);

/// Detection of the daily AgentRouter claim.
///
/// The claim happens server-side on the first daily sign-in and is NOT
/// directly observable with an API key alone (billing subscription reports a
/// fixed 100000000 sentinel for unlimited tokens, and `/api/user/self` rejects
/// Bearer auth). The reliable signal is the account's own activity log
/// (`GET /api/log/self`, entry `type=4` "每日签到成功"), which requires a
/// session cookie captured by the browser automation. As a cookie-less
/// fallback we compare the billing subscription quota delta against the
/// configured [DailyClaimConfig] window.
class DailyClaimDetector {
  final DailyClaimJsonFetch _fetch;
  final DailyClaimConfig _config;

  DailyClaimDetector(this._fetch, this._config);

  /// Evaluate whether a claim has happened today, returning a human-readable
  /// reason so the caller can log or display it.
  Future<ClaimCheckResult> check({
    required String credentialId,
    required String apiKey,
    String? sessionCookie,
    String? newApiUserId,
  }) async {
    if (_config.claimedToday(credentialId)) {
      return ClaimCheckResult.confirmed('already marked today');
    }
    if (sessionCookie != null && newApiUserId != null) {
      final viaLog = await _checkActivityLog(
          apiKey: apiKey,
          sessionCookie: sessionCookie,
          newApiUserId: newApiUserId);
      if (viaLog != null) return viaLog;
    }
    return _checkQuota(apiKey: apiKey);
  }

  /// Authoritative check: read today's activity log entries. A `type=4`
  /// entry whose content contains a check-in marker means the claim fired.
  /// Returns null when the log path is unavailable (network error etc.).
  Future<ClaimCheckResult?> _checkActivityLog({
    required String apiKey,
    required String sessionCookie,
    required String newApiUserId,
  }) async {
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day)
          .millisecondsSinceEpoch ~/ 1000;
      final end = now.millisecondsSinceEpoch ~/ 1000;
      final raw = await _fetch(
        '/api/log/self?start_timestamp=$start&end_timestamp=$end',
        {
          'Authorization': 'Bearer $apiKey',
          'Cookie': 'session=$sessionCookie',
          'New-API-User': newApiUserId,
        },
      );
      final items = (raw['data'] as Map?)?['items'] as List? ?? [];
      for (final it in items) {
        if (it is! Map) continue;
        if (it['type'] == 4) {
          final content = (it['content'] as String?) ?? '';
          if (content.contains('签到成功') || content.contains('签到')) {
            return ClaimCheckResult.confirmed(
                'log entry: ${it['created_at']} $content');
          }
        }
      }
      return ClaimCheckResult.notClaimed('no check-in log entry today');
    } catch (_) {
      return null;
    }
  }

  /// Cookie-less fallback: compare billing subscription quota against the
  /// configured detection window. The quota reported here is the token's
  /// lifetime total, which moves only on a credit event; a positive movement
  /// inside `[expectedAmount - tolerance, expectedAmount + tolerance]` counts
  /// as the daily claim.
  Future<ClaimCheckResult> _checkQuota({required String apiKey}) async {
    try {
      final sub = await _fetch('/v1/dashboard/billing/subscription', {
        'Authorization': 'Bearer $apiKey',
      });
      final usd = (sub['hard_limit_usd'] as num?)?.toDouble();
      if (usd == null) {
        return ClaimCheckResult.unknown('billing returned no hard_limit_usd');
      }
      // The unlimited sentinel never moves, so a claim cannot be seen here.
      if (usd >= 100000000) {
        return ClaimCheckResult.unknown('unlimited token sentinel, cannot '
            'detect via billing');
      }
      final low = _config.expectedAmount - _config.tolerance;
      final high = _config.expectedAmount + _config.tolerance;
      if (usd >= low && usd <= high) {
        return ClaimCheckResult.confirmed(
            'billing delta \$${usd.toStringAsFixed(2)} in window '
            '[\$${low.toStringAsFixed(2)}, \$${high.toStringAsFixed(2)}]');
      }
      return ClaimCheckResult.notClaimed(
          'billing \$${usd.toStringAsFixed(2)} outside window '
          '[\$${low.toStringAsFixed(2)}, \$${high.toStringAsFixed(2)}]');
    } catch (e) {
      return ClaimCheckResult.unknown('billing check failed: $e');
    }
  }
}

/// Outcome of a claim-status evaluation.
class ClaimCheckResult {
  /// `confirmed` = already claimed today, `notClaimed` = not yet claimed,
  /// `unknown` = could not determine.
  final String state;
  final String detail;

  const ClaimCheckResult._(this.state, this.detail);

  factory ClaimCheckResult.confirmed(String detail) =>
      ClaimCheckResult._('confirmed', detail);
  factory ClaimCheckResult.notClaimed(String detail) =>
      ClaimCheckResult._('notClaimed', detail);
  factory ClaimCheckResult.unknown(String detail) =>
      ClaimCheckResult._('unknown', detail);

  bool get isConfirmed => state == 'confirmed';
  bool get isNotClaimed => state == 'notClaimed';
  bool get isUnknown => state == 'unknown';
}
