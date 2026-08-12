import 'package:test/test.dart';

import 'package:agrout_bridge/src/services/usage_store.dart';
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
  setUp(UsageStore().reset);

  test('counts requests + success rate', () {
    final u = UsageStore();
    u.record(_o(200, model: 'a'));
    u.record(_o(200, model: 'a'));
    u.record(_o(500, model: 'b'));
    expect(u.totalRequests, 3);
    expect(u.successRequests, 2);
    expect(u.successRate, closeTo(0.6667, 0.01));
  });

  test('aggregates tokens + cost', () {
    final u = UsageStore();
    u.record(_o(200, model: 'a', inTok: 10, outTok: 5, cost: 0.01));
    u.record(_o(200, model: 'a', inTok: 3, outTok: 2, cost: 0.005));
    expect(u.inputTokens, 13);
    expect(u.outputTokens, 7);
    expect(u.costCny, closeTo(0.015, 1e-9));
  });

  test('per-model breakdown', () {
    final u = UsageStore();
    u.record(_o(200, model: 'a', inTok: 1, outTok: 1, cost: 0.001));
    u.record(_o(200, model: 'a', inTok: 1, outTok: 1, cost: 0.001));
    u.record(_o(200, model: 'b', inTok: 1, outTok: 1, cost: 0.002));
    final byModel = u.perModel;
    expect(byModel.first.model, 'a');
    expect(byModel.first.count, 2);
    expect(byModel.last.model, 'b');
  });

  test('reset clears all counters', () {
    final u = UsageStore();
    u.record(_o(200, model: 'a'));
    u.reset();
    expect(u.totalRequests, 0);
    expect(u.successRequests, 0);
    expect(u.inputTokens, 0);
    expect(u.perModel, isEmpty);
  });
}
