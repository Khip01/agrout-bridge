import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:agrout_bridge/src/models/profile.dart';
import 'package:agrout_bridge/src/services/stats_store.dart';
import 'package:agrout_bridge/src/server/proxy.dart';

ProxyOutcome _o(int s, {String? model, int inTok = 0, int outTok = 0, double cost = 0, bool stream = false}) =>
    ProxyOutcome(
      statusCode: s,
      model: model,
      inputTokens: inTok,
      outputTokens: outTok,
      costCny: cost,
      streaming: stream,
      duration: Duration.zero,
    );

void main() {
  late Directory tmp;
  late String oldOverride;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stats_store_test');
    oldOverride = configDirOverride ?? '';
    configDirOverride = tmp.path;
    StatsStore().reset();
    StatsStore.init();
  });

  tearDown(() {
    configDirOverride = oldOverride.isEmpty ? null : oldOverride;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('counts requests + success rate for today', () {
    StatsStore().record(_o(200, model: 'a'));
    StatsStore().record(_o(200, model: 'a'));
    StatsStore().record(_o(500, model: 'b'));
    final t = StatsStore().today!;
    expect(t.totalRequests, 3);
    expect(t.successRequests, 2);
    expect(t.successRate, closeTo(0.6667, 0.01));
  });

  test('aggregates tokens + cost', () {
    StatsStore().record(_o(200, model: 'a', inTok: 10, outTok: 5, cost: 0.01));
    StatsStore().record(_o(200, model: 'a', inTok: 3, outTok: 2, cost: 0.005));
    final t = StatsStore().today!;
    expect(t.inputTokens, 13);
    expect(t.outputTokens, 7);
    expect(t.costCny, closeTo(0.015, 1e-9));
  });

  test('per-model breakdown sorted by count desc', () {
    StatsStore().record(_o(200, model: 'b', inTok: 1, outTok: 1, cost: 0.002));
    StatsStore().record(_o(200, model: 'a', inTok: 1, outTok: 1, cost: 0.001));
    StatsStore().record(_o(200, model: 'a', inTok: 1, outTok: 1, cost: 0.001));
    final byModel = StatsStore().today!.perModel;
    expect(byModel.first.model, 'a');
    expect(byModel.first.count, 2);
    expect(byModel.last.model, 'b');
  });

  test('survives re-init (persisted file reloads daily totals)', () {
    StatsStore().record(_o(200, model: 'a', inTok: 10, outTok: 5));
    StatsStore().record(_o(500, model: 'b'));
    StatsStore.init(); // simulates restart, reloads from disk
    final t = StatsStore().today!;
    expect(t.totalRequests, 2);
    expect(t.successRequests, 1);
    expect(t.inputTokens, 10);
    expect(t.perModel.length, 2);
  });

  test('clearAll wipes the file and memory', () {
    StatsStore().record(_o(200, model: 'a'));
    StatsStore().clearAll();
    expect(StatsStore().today, isNull);
    expect(StatsStore().days, isEmpty);
    StatsStore.init();
    expect(StatsStore().today, isNull);
  });

  test('clearBeforeToday keeps only today', () {
    StatsStore().record(_o(200, model: 'a'));
    // Simulate an old day entry so countBeforeToday sees something (records
    // always land on today; inject an old day directly).
    final fakeOld = DayStats(DateTime.now().subtract(const Duration(days: 5)));
    final path = tmp.path + Platform.pathSeparator + 'stats.jsonl';
    File(path).writeAsStringSync(
        '${jsonEncode(fakeOld.toJson())}\n'
        '${jsonEncode(StatsStore().today!.toJson())}\n');
    StatsStore.init();
    expect(StatsStore().countBeforeToday(), 1);
    StatsStore().clearBeforeToday();
    expect(StatsStore().countBeforeToday(), 0);
    expect(StatsStore().days, isNotEmpty);
  });

  test('retention prunes days older than retentionDays', () {
    // Inject 40 fake old days + persist, then re-init -> only ~31 kept.
    final path = tmp.path + Platform.pathSeparator + 'stats.jsonl';
    final lines = <String>[];
    for (var i = 40; i >= 0; i--) {
      final d = DayStats(DateTime.now().subtract(Duration(days: i)));
      lines.add(jsonEncode(d.toJson()));
    }
    File(path).writeAsStringSync('${lines.join('\n')}\n');
    StatsStore.init();
    expect(StatsStore().days.length, lessThanOrEqualTo(StatsStore.retentionDays));
  });
}