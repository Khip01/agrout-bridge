import 'dart:convert';

import 'package:agrout_bridge/src/server/proxy.dart';
import 'package:test/test.dart';

String _b64Run(int chars) => 'A' * chars;

void main() {
  group('scrubBase64Payload', () {
    test('strips base64 data URIs from tool results', () {
      final body = {
        'messages': [
          {
            'role': 'tool',
            'tool_call_id': 'c1',
            'content': 'ok\n![logo](data:image/png;base64,${_b64Run(2000)})\nrest',
          },
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final content = (body['messages'] as List).first['content'] as String;
      expect(content.contains('data:image/png;base64,'), isFalse);
      expect(content, contains('[base64 data stripped by bridge]'));
      expect(content, contains('ok'));
      expect(content, contains('rest'));
    });

    test('strips long bare base64 runs in user text', () {
      final body = {
        'messages': [
          {'role': 'user', 'content': 'here is the blob: ${_b64Run(300)} and more'},
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains(_b64Run(100))));
      expect(content, contains('here is the blob:'));
    });

    test('leaves plain text, URLs and short tokens untouched', () {
      final body = {
        'messages': [
          {'role': 'user', 'content': 'hello world, check https://example.com/a/BcDe+fGh='},
          {'role': 'user', 'content': 'jwt-like: eyJhbGciOiJIUzI1NiJ9.some.payload'},
        ],
      };
      final before = jsonEncode(body);
      final changed = scrubBase64Payload(body);
      expect(changed, isFalse);
      expect(jsonEncode(body), before);
    });

    test('strips short data URIs too (accumulated base64 still trips the filter)', () {
      final body = {
        'messages': [
          {
            'role': 'tool',
            'tool_call_id': 'c1',
            'content': 'data:image/png;base64,${_b64Run(50)}',
          },
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, contains('[base64 data stripped by bridge]'));
    });

    test('walks nested Anthropic content blocks', () {
      final body = {
        'system': 'you are a helper',
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'name': 'read', 'input': {'filePath': '/tmp/a.png'}},
            ],
          },
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_1',
                'content': [
                  {'type': 'text', 'text': 'data:image/png;base64,${_b64Run(2400)}'},
                ],
              },
            ],
          },
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final blocks = (body['messages'] as List)[1]['content'] as List;
      final inner = (blocks.first['content'] as List).first;
      expect(inner['text'], contains('[base64 data stripped by bridge]'));
    });

    test('does not mutate when no base64 present', () {
      final body = {
        'messages': [
          {'role': 'user', 'content': 'hari ini kita latih lora wan 2.2'},
        ],
      };
      final before = jsonEncode(body);
      expect(scrubBase64Payload(body), isFalse);
      expect(jsonEncode(body), before);
    });

    test('strips Google Docs kix element IDs', () {
      final body = {
        'messages': [
          {
            'role': 'assistant',
            'content': 'lalu gambar `kix.kuawx1xiz6sv` di section landscape',
          },
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains('kix.kuawx1xiz6sv')));
      expect(content, contains('[kix element id stripped by bridge]'));
      expect(content, contains('lalu gambar'));
      expect(content, contains('di section landscape'));
    });

    test('strips bare kix token without dot', () {
      final body = {
        'messages': [
          {'role': 'assistant', 'content': 'id: kixkuawx1xiz6sv di sini'},
        ],
      };
      final changed = scrubBase64Payload(body);
      expect(changed, isTrue);
      final content = (body['messages'] as List).first['content'] as String;
      expect(content, isNot(contains('kixkuawx1xiz6sv')));
      expect(content, contains('[kix element id stripped by bridge]'));
    });

    test('leaves short kix tokens and plain text untouched', () {
      final body = {
        'messages': [
          {'role': 'assistant', 'content': 'kix.abc dan kalimat biasa saja'},
        ],
      };
      final before = jsonEncode(body);
      expect(scrubBase64Payload(body), isFalse);
      expect(jsonEncode(body), before);
    });
  });
}
