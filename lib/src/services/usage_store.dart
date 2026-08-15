import '../server/proxy.dart';

/// Aggregated usage + cost from per-request [ProxyOutcome]s.
/// Cheap, in-memory only; reset on restart.
class UsageStore {
  static final UsageStore _instance = UsageStore._();
  factory UsageStore() => _instance;
  UsageStore._();

  int _totalRequests = 0;
  int _successRequests = 0;
  int _streamRequests = 0;
  int _inputTokens = 0;
  int _outputTokens = 0;
  int _cacheReadTokens = 0;
  int _cacheCreationTokens = 0;
  double _costCny = 0;
  String? _lastModel;
  DateTime? _lastRequestAt;
  final Map<String, _ModelStats> _byModel = {};
  int _version = 0;

  int get totalRequests => _totalRequests;
  int get version => _version;
  int get successRequests => _successRequests;
  int get streamRequests => _streamRequests;
  int get inputTokens => _inputTokens;
  int get outputTokens => _outputTokens;
  int get cacheReadTokens => _cacheReadTokens;
  int get cacheCreationTokens => _cacheCreationTokens;
  double get costCny => _costCny;
  String? get lastModel => _lastModel;
  DateTime? get lastRequestAt => _lastRequestAt;
  List<_ModelStats> get perModel => _byModel.values.toList()
    ..sort((a, b) => b.count.compareTo(a.count));

  double get successRate =>
      _totalRequests == 0 ? 0 : _successRequests / _totalRequests;

  void record(ProxyOutcome o) {
    _totalRequests++;
    if (o.statusCode >= 200 && o.statusCode < 400) _successRequests++;
    if (o.streaming) _streamRequests++;
    _inputTokens += o.inputTokens;
    _outputTokens += o.outputTokens;
    _cacheReadTokens += o.cacheReadTokens;
    _cacheCreationTokens += o.cacheCreationTokens;
    _costCny += o.costCny;
    _lastRequestAt = DateTime.now();
    _lastModel = o.model ?? _lastModel;
    if (o.model != null) {
      final m = _byModel.putIfAbsent(o.model!, () => _ModelStats(o.model!));
      m.count++;
      if (o.statusCode >= 200 && o.statusCode < 400) m.successCount++;
      m.inputTokens += o.inputTokens;
      m.outputTokens += o.outputTokens;
      m.costCny += o.costCny;
    }
    _version++;
  }

  void reset() {
    _totalRequests = 0;
    _successRequests = 0;
    _streamRequests = 0;
    _inputTokens = 0;
    _outputTokens = 0;
    _cacheReadTokens = 0;
    _cacheCreationTokens = 0;
    _costCny = 0;
    _lastModel = null;
    _lastRequestAt = null;
    _byModel.clear();
    _version++;
  }
}

class _ModelStats {
  final String model;
  int count = 0;
  int successCount = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  double costCny = 0;
  _ModelStats(this.model);
}
