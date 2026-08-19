import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import '../server/proxy.dart';

/// Per-model usage totals for a single calendar day (local time).
class ModelStats {
  final String model;
  int count = 0;
  int successCount = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  double costCny = 0;
  ModelStats(this.model);

  Map<String, dynamic> toJson() => {
        'n': count,
        'ok': successCount,
        'in': inputTokens,
        'out': outputTokens,
        'cost': costCny,
      };
  factory ModelStats.fromJson(String model, Map<String, dynamic> j) {
    final m = ModelStats(model);
    m.count = j['n'] as int? ?? 0;
    m.successCount = j['ok'] as int? ?? 0;
    m.inputTokens = j['in'] as int? ?? 0;
    m.outputTokens = j['out'] as int? ?? 0;
    m.costCny = (j['cost'] as num?)?.toDouble() ?? 0;
    return m;
  }
}

/// Aggregated usage for one calendar day (local time).
class DayStats {
  final DateTime day;
  int totalRequests = 0;
  int successRequests = 0;
  int streamRequests = 0;
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheCreationTokens = 0;
  double costCny = 0;
  String? lastModel;
  DateTime? lastRequestAt;
  final Map<String, ModelStats> _byModel = {};
  DayStats(this.day);

  List<ModelStats> get perModel => _byModel.values.toList()
    ..sort((a, b) => b.count.compareTo(a.count));

  double get successRate =>
      totalRequests == 0 ? 0 : successRequests / totalRequests;

  void record(ProxyOutcome o) {
    totalRequests++;
    if (o.statusCode >= 200 && o.statusCode < 400) successRequests++;
    if (o.streaming) streamRequests++;
    inputTokens += o.inputTokens;
    outputTokens += o.outputTokens;
    cacheReadTokens += o.cacheReadTokens;
    cacheCreationTokens += o.cacheCreationTokens;
    costCny += o.costCny;
    lastRequestAt = DateTime.now();
    lastModel = o.model ?? lastModel;
    if (o.model != null) {
      final m = _byModel.putIfAbsent(o.model!, () => ModelStats(o.model!));
      m.count++;
      if (o.statusCode >= 200 && o.statusCode < 400) m.successCount++;
      m.inputTokens += o.inputTokens;
      m.outputTokens += o.outputTokens;
      m.costCny += o.costCny;
    }
  }

  Map<String, dynamic> toJson() => {
        'date': _fmtDay(day),
        'total': totalRequests,
        'ok': successRequests,
        'stream': streamRequests,
        'in': inputTokens,
        'out': outputTokens,
        'cr': cacheReadTokens,
        'cc': cacheCreationTokens,
        'cost': costCny,
        'lastModel': lastModel,
        'lastRequestAt': lastRequestAt?.toIso8601String(),
        'models': _byModel.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory DayStats.fromJson(Map<String, dynamic> j) {
    final d = DayStats(_parseDay(j['date'] as String));
    d.totalRequests = j['total'] as int? ?? 0;
    d.successRequests = j['ok'] as int? ?? 0;
    d.streamRequests = j['stream'] as int? ?? 0;
    d.inputTokens = j['in'] as int? ?? 0;
    d.outputTokens = j['out'] as int? ?? 0;
    d.cacheReadTokens = j['cr'] as int? ?? 0;
    d.cacheCreationTokens = j['cc'] as int? ?? 0;
    d.costCny = (j['cost'] as num?)?.toDouble() ?? 0;
    d.lastModel = j['lastModel'] as String?;
    final ts = j['lastRequestAt'] as String?;
    if (ts != null) d.lastRequestAt = DateTime.tryParse(ts);
    final models = j['models'] as Map<String, dynamic>? ?? const {};
    for (final e in models.entries) {
      final m = ModelStats.fromJson(e.key, e.value as Map<String, dynamic>);
      d._byModel[e.key] = m;
    }
    return d;
  }
}

String _fmtDay(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _parseDay(String s) {
  final parts = s.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

/// Persistent per-day usage + cost. Written to
/// `~/.config/agrout-bridge/stats.jsonl`, one JSON line per calendar day, so
/// the numbers survive restarts and are independent of the (user-clearable)
/// activity log. Old days are pruned beyond [retentionDays].
class StatsStore {
  static final StatsStore _instance = StatsStore._();
  factory StatsStore() => _instance;
  StatsStore._();

  /// How many calendar days (including today) are kept on disk.
  static const int retentionDays = 30;

  static String? _path;
  final Map<String, DayStats> _days = {};
  int _version = 0;

  static String get path =>
      _path ?? '${configDir()}${Platform.pathSeparator}stats.jsonl';

  int get version => _version;
  List<DayStats> get days =>
      _days.values.toList()..sort((a, b) => b.day.compareTo(a.day));

  static void init() {
    _instance._load();
    _instance._version++;
  }

  void _load() {
    _days.clear();
    final f = File(path);
    if (!f.existsSync()) return;
    try {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final d = DayStats.fromJson(jsonDecode(line) as Map<String, dynamic>);
        _days[_fmtDay(d.day)] = d;
      }
    } catch (_) {}
    _prune();
  }

  void _persist() {
    try {
      final dir = Directory(configDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final body = _days.values
          .map((d) => jsonEncode(d.toJson()))
          .join('\n');
      File(path).writeAsStringSync(body.isEmpty ? '' : '$body\n', flush: true);
    } catch (_) {}
  }

  void _prune() {
    final cutoff = DateTime.now();
    final keep = cutoff.subtract(Duration(days: retentionDays - 1));
    _days.removeWhere((_, d) => d.day.isBefore(keep));
  }

  DayStats? day(DateTime d) => _days[_fmtDay(d)];

  DayStats? get today => day(DateTime.now());

  void record(ProxyOutcome o) {
    final now = DateTime.now();
    final key = _fmtDay(now);
    final d = _days.putIfAbsent(key, () => DayStats(DateTime(now.year, now.month, now.day)));
    d.record(o);
    _prune();
    _persist();
    _version++;
  }

  /// Number of day entries older than 00:00 local time today.
  int countBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _days.values.where((d) => d.day.isBefore(today)).length;
  }

  void clearAll() {
    _days.clear();
    _persist();
    _version++;
  }

  void clearBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _days.removeWhere((_, d) => d.day.isBefore(today));
    _persist();
    _version++;
  }

  void reset() {
    _days.clear();
    _version++;
  }
}
