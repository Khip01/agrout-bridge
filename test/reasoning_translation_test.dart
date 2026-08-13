import 'package:agrout_bridge/src/server/proxy.dart';
import 'package:test/test.dart';

void main() {
  group('looksLikeClaude', () {
    test('detects claude family', () {
      expect(looksLikeClaude('claude-opus-4-8'), isTrue);
      expect(looksLikeClaude('claude-3-5-sonnet-20241022'), isTrue);
      expect(looksLikeClaude('claude-sonnet-4-20250514'), isTrue);
    });

    test('rejects non-claude', () {
      expect(looksLikeClaude('gpt-4.1'), isFalse);
      expect(looksLikeClaude('gpt-5.6-sol'), isFalse);
      expect(looksLikeClaude('o3-mini'), isFalse);
      expect(looksLikeClaude('deepseek-v4-pro'), isFalse);
    });
  });

  group('normalizeReasoning (OpenAI -> Anthropic thinking)', () {
    late Map<String, dynamic> body;

    test('reasoning_effort=high maps to thinking{type:enabled,budget:8192}', () {
      body = {'model': 'claude-opus-4-8', 'reasoning_effort': 'high'};
      expect(normalizeReasoning('claude-opus-4-8', body), isTrue);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['thinking'], equals({'type': 'enabled', 'budget_tokens': 8192}));
    });

    test('reasoning_effort=low maps to budget 1024', () {
      body = {'model': 'claude-opus-4-8', 'reasoning_effort': 'low'};
      expect(normalizeReasoning('claude-opus-4-8', body), isTrue);
      expect(body['thinking'], equals({'type': 'enabled', 'budget_tokens': 1024}));
    });

    test('reasoning_effort=medium maps to budget 4096', () {
      body = {'model': 'claude-opus-4-8', 'reasoning_effort': 'medium'};
      expect(normalizeReasoning('claude-opus-4-8', body), isTrue);
      expect(body['thinking'], equals({'type': 'enabled', 'budget_tokens': 4096}));
    });

    test('reasoning_effort=none strips thinking', () {
      body = {'model': 'claude-opus-4-8', 'reasoning_effort': 'none', 'thinking': {'type': 'enabled'}};
      expect(normalizeReasoning('claude-opus-4-8', body), isTrue);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('thinking'), isFalse);
    });

    test('non-Claude model is left untouched', () {
      body = {'model': 'gpt-4.1', 'reasoning_effort': 'high'};
      expect(normalizeReasoning('gpt-4.1', body), isFalse);
      expect(body['reasoning_effort'], equals('high'));
    });

    test('existing thinking{enabled:true} normalized to thinking{type:enabled}', () {
      body = {
        'model': 'claude-opus-4-8',
        'thinking': {'enabled': true, 'budget_tokens': 1024},
      };
      expect(normalizeReasoning('claude-opus-4-8', body), isTrue);
      expect(body['thinking'], equals({'type': 'enabled', 'budget_tokens': 1024}));
    });

    test('already-standard thinking{type:enabled} is left untouched', () {
      body = {'model': 'claude-opus-4-8', 'thinking': {'type': 'enabled', 'budget_tokens': 1024}};
      expect(normalizeReasoning('claude-opus-4-8', body), isFalse);
    });

    test('no reasoning fields => no change', () {
      body = {'model': 'claude-opus-4-8', 'max_tokens': 1000};
      expect(normalizeReasoning('claude-opus-4-8', body), isFalse);
    });
  });
}
