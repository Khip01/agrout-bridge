import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:agrout_bridge/src/server/sse.dart';

Stream<String> _stream(List<String> events, {Duration perEvent = Duration.zero}) async* {
  for (final e in events) {
    if (perEvent > Duration.zero) await Future.delayed(perEvent);
    for (final line in const LineSplitter().convert(e)) {
      yield line;
    }
  }
}

void main() {
  group('eomTail', () {
    test('anthropic includes message_delta + message_stop', () {
      final s = eomTail(StreamFormat.anthropic);
      expect(s, contains('event: message_delta'));
      expect(s, contains('event: message_stop'));
      expect(s.endsWith('\n\n'), isTrue);
    });

    test('openai includes finish_reason stop + [DONE]', () {
      final s = eomTail(StreamFormat.openai);
      expect(s, contains('"finish_reason":"stop"'));
      expect(s, contains('data: [DONE]'));
      expect(s.endsWith('\n\n'), isTrue);
    });
  });

  group('isTerminalLine', () {
    test('anthropic message_stop', () {
      expect(isTerminalLine(StreamFormat.anthropic, 'event: message_stop'), isTrue);
      expect(isTerminalLine(StreamFormat.anthropic, 'event: message_start'), isFalse);
      expect(isTerminalLine(StreamFormat.anthropic, 'data: message_stop'), isFalse);
    });

    test('openai data: [DONE]', () {
      expect(isTerminalLine(StreamFormat.openai, 'data: [DONE]'), isTrue);
      expect(isTerminalLine(StreamFormat.openai, '  data: [DONE]  '), isTrue);
      expect(isTerminalLine(StreamFormat.openai, 'data: null'), isFalse);
    });
  });

  group('isOpenAiKeepaliveToDrop', () {
    test('drops "data: null" and "data:" lines for openai', () {
      expect(isOpenAiKeepaliveToDrop(StreamFormat.openai, 'data: null'), isTrue);
      expect(isOpenAiKeepaliveToDrop(StreamFormat.openai, 'data:'), isTrue);
      expect(isOpenAiKeepaliveToDrop(StreamFormat.openai, 'data: [DONE]'), isFalse);
      expect(isOpenAiKeepaliveToDrop(StreamFormat.openai, 'data: {"choices":[]}'), isFalse);
    });

    test('anthropic never drops', () {
      expect(isOpenAiKeepaliveToDrop(StreamFormat.anthropic, 'data: null'), isFalse);
      expect(isOpenAiKeepaliveToDrop(StreamFormat.anthropic, 'event: ping'), isFalse);
    });
  });

  group('pumpSse', () {
    test('anthropic forwards clean stream and detects message_stop', () async {
      final out = StringBuffer();
      final r = await pumpSse(
        source: _stream([
          'event: message_start\ndata: {}\n\n',
          'event: content_block_delta\ndata: {"delta":{"text":"hi"}}\n\n',
          'event: message_stop\ndata: {}\n\n',
        ]),
        emit: out.write,
        format: StreamFormat.anthropic,
        idleTimeout: const Duration(seconds: 5),
      );
      expect(r.sawTerminal, isTrue);
      expect(r.aborted, isFalse);
      expect(out.toString(), contains('event: message_stop'));
    });

    test('openai drops data: null keepalives', () async {
      final out = StringBuffer();
      await pumpSse(
        source: _stream([
          'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n',
          ': keep-alive\ndata: null\n\n',
          'data: [DONE]\n\n',
        ]),
        emit: out.write,
        format: StreamFormat.openai,
        idleTimeout: const Duration(seconds: 5),
      );
      final body = out.toString();
      expect(body, contains('hello'));
      expect(body.contains('data: null'), isFalse);
      expect(body, contains('data: [DONE]'));
    });

    test('flags aborted when upstream closed without terminal', () async {
      final out = StringBuffer();
      final r = await pumpSse(
        source: _stream(['event: message_start\ndata: {}\n\n']),
        emit: out.write,
        format: StreamFormat.anthropic,
        idleTimeout: const Duration(seconds: 5),
      );
      expect(r.sawTerminal, isFalse);
      expect(r.aborted, isTrue);
    });

    test('idle timeout fires when no lines arrive', () async {
      final out = StringBuffer();
      final r = await pumpSse(
        source: _stream(['event: message_start\ndata: {}\n\n'], perEvent: const Duration(milliseconds: 50))
            .asyncMap((l) => l),
        emit: out.write,
        format: StreamFormat.anthropic,
        idleTimeout: const Duration(milliseconds: 100),
      );
      // After the first line, nothing else arrives -> idle fires.
      expect(r.aborted, isTrue);
    });
  });
}
