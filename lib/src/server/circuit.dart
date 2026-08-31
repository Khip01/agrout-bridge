/// Circuit breaker + per-model health tracking for the upstream AgentRouter
/// gateway. The breaker is conservative (it does NOT black-hole requests on
/// a per-model 429 throttle, since the model is still healthy at the network
/// level, the client just falls back via 9Router / OpenCode).
library;

/// A small per-model success / failure counter used to decide whether to
/// surface a model in `/v1/models`. Failures older than [_healthWindow] are
/// dropped so transient throttles do not permanently hide a model.
class ModelHealth {
  static const int _healthWindow = 60 * 60 * 1000; // 1 hour
  final Map<String, List<_Failure>> _failures = {};

  void recordFailure(String model, int statusCode) {
    final list = _failures.putIfAbsent(model, () => <_Failure>[]);
    list.add(_Failure(DateTime.now().millisecondsSinceEpoch, statusCode));
    list.removeWhere((f) => DateTime.now().millisecondsSinceEpoch - f.at > _healthWindow);
  }

  bool isHealthy(String model) {
    final list = _failures[model];
    if (list == null || list.isEmpty) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final recent = list.where((f) => now - f.at < _healthWindow).length;
    // A model is unhealthy if it has 3+ failures in the window.
    return recent < 3;
  }

  List<String> filter(List<String> models) => models.where(isHealthy).toList();

  Map<String, dynamic> snapshot() => {
        'windowMs': _healthWindow,
        'failures': _failures.map((k, v) => MapEntry(k, v.length)),
      };

  void clear() => _failures.clear();
}

class _Failure {
  final int at;
  final int statusCode;
  _Failure(this.at, this.statusCode);
}

/// Open / closed circuit breaker that trips on consecutive final transport-
/// level upstream failures (502, 503, 504, socket exceptions, host lookup
/// failures). 4xx and "policy" 5xx (notably AgentRouter's `500` with body
/// `{"error":{"code":"sensitive_words_detected" | "content-blocked" | ...}}`)
/// are **permanent** caller-or-policy rejections: the upstream is healthy
/// and the same request will fail the same way. Counting those would open
/// the circuit for a model that is actually fine, masking it for 1-10
/// minutes. The per-model `ModelHealth` table still records 4xx and policy
/// 5xx so the TUI can surface a misbehaving model.
class CircuitBreaker {
  static const int _failureThreshold = 5;
  static const int _cooldownMs = 60 * 1000; // 1 minute
  static const int _maxCooldownMs = 10 * 60 * 1000; // 10 minutes

  int _consecutiveFails = 0;
  int _openUntil = 0;
  int _currentCooldown = _cooldownMs;

  bool get isOpen {
    if (DateTime.now().millisecondsSinceEpoch < _openUntil) return true;
    return false;
  }

  int get consecutiveFails => _consecutiveFails;

  void recordSuccess() {
    _consecutiveFails = 0;
    _currentCooldown = _cooldownMs;
  }

  /// Record an upstream failure. [statusCode] is the HTTP status the
  /// upstream returned (0 means a transport error -- DNS, socket, TLS,
  /// timeout). Only transport-level failures contribute to the breaker;
  /// permanent rejections (4xx and policy 5xx) are ignored.
  void recordFailure([int statusCode = 0]) {
    if (_isPermanentRejection(statusCode)) return;
    _consecutiveFails++;
    if (_consecutiveFails >= _failureThreshold) {
      _openUntil = DateTime.now().millisecondsSinceEpoch + _currentCooldown;
      _currentCooldown = (_currentCooldown * 2).clamp(_cooldownMs, _maxCooldownMs);
    }
  }

  /// True for HTTP statuses that signal a permanent caller or policy
  /// rejection (4xx) and the 5xx codes AgentRouter uses for content /
  /// language / sensitive_words gates. None of these indicate that the
  /// upstream is unhealthy, so the circuit breaker ignores them.
  static bool _isPermanentRejection(int statusCode) {
    if (statusCode == 0) return false; // transport error
    if (statusCode >= 400 && statusCode < 500) return true;
    if (statusCode == 500) return true; // agentrouter policy gate
    return false; // 502/503/504: real upstream trouble
  }

  Map<String, dynamic> snapshot() => {
        'consecutiveFails': _consecutiveFails,
        'openUntil': _openUntil,
        'isOpen': isOpen,
      };

  void reset() {
    _consecutiveFails = 0;
    _openUntil = 0;
    _currentCooldown = _cooldownMs;
  }
}
