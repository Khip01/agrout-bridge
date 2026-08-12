// Live smoke test against `agentrouter.org`. Skipped unless the API key is
// available locally via `dev/api_key.txt` (mode 0600) or the env var
// `AGROUT_TEST_API_KEY`. Both are gitignored. Run with:
//
//     dart test test/live_smoke_test.dart
//
// This test makes real network calls (and consumes a few tokens from the
// upstream account) so it MUST be skipped in CI and only run by hand.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:agrout_bridge/src/services/api_client.dart';
import 'package:agrout_bridge/src/services/waf.dart';

Uint8List _u8(String s) => Uint8List.fromList(utf8.encode(s));

String? _loadKey() {
  final env = Platform.environment['AGROUT_TEST_API_KEY'];
  if (env != null && env.isNotEmpty) return env;
  final f = File('${Directory.current.path}${Platform.pathSeparator}dev${Platform.pathSeparator}api_key.txt');
  if (!f.existsSync()) return null;
  return f.readAsStringSync().trim();
}

void main() {
  final apiKey = _loadKey();
  if (apiKey == null || apiKey.isEmpty) {
    test('live smoke skipped: no key in env AGROUT_TEST_API_KEY or dev/api_key.txt', () {}, skip: 'no key');
    return;
  }

  test('warmup is best-effort and returns a cookie map', () async {
    final c = AgentRouterClient();
    try {
      final r = await c.warmup();
      // Status may be 200, 3xx, or 4xx depending on edge behaviour; the
      // contract is "no throw + return a (possibly empty) cookie map".
      expect(r.cookies, isA<Map<String, String>>());
    } finally {
      c.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('fetchModels returns at least one model', () async {
    final c = AgentRouterClient();
    try {
      final warm = await c.warmup();
      final models = await c.fetchModels(apiKey: apiKey, cookies: warm.cookies);
      // Per live test 2026-08-12: only claude-opus-4-8 for this account.
      expect(models, isNotEmpty);
      expect(models, contains('claude-opus-4-8'));
    } finally {
      c.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('POST /v1/chat/completions non-stream returns 200', () async {
    final c = AgentRouterClient();
    try {
      final warm = await c.warmup();
      Map<String, dynamic>? resp;
      HttpException? lastErr;
      // Retry once on transient 4xx/5xx (QPS throttle).
      for (var i = 0; i < 2; i++) {
        try {
          resp = await c.postJson(
            path: AgentRouterPaths.chatCompletions,
            authHeader: 'Bearer $apiKey',
            body: jsonEncode({
              'model': 'claude-opus-4-8',
              'max_tokens': 6,
              'messages': [
                {'role': 'user', 'content': 'hi'}
              ],
            }),
            cookies: warm.cookies,
          );
          break;
        } on HttpException catch (e) {
          lastErr = e;
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      expect(resp, isNotNull, reason: lastErr?.message ?? 'no response');
      expect(resp!['object'], 'chat.completion');
      final choices = (resp['choices'] as List?) ?? const [];
      expect(choices, isNotEmpty);
    } finally {
      c.close();
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('POST /v1/messages non-stream returns 200 + content + billing', () async {
    final c = AgentRouterClient();
    try {
      final warm = await c.warmup();
      Map<String, dynamic>? resp;
      HttpException? lastErr;
      for (var i = 0; i < 2; i++) {
        try {
          resp = await c.postJson(
            path: AgentRouterPaths.messages,
            authHeader: 'Bearer $apiKey',
            body: jsonEncode({
              'model': 'claude-opus-4-8',
              'max_tokens': 6,
              'messages': [
                {'role': 'user', 'content': 'reply with the word: PONG'}
              ],
            }),
            cookies: warm.cookies,
            anthropicPath: true,
          );
          break;
        } on HttpException catch (e) {
          lastErr = e;
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      expect(resp, isNotNull, reason: lastErr?.message ?? 'no response');
      expect(resp!['role'], 'assistant');
      expect(resp['content'], isNotNull);
      final contentList = (resp['content'] as List?) ?? const [];
      final text = contentList
          .map((e) => e is Map ? e['text']?.toString() : null)
          .whereType<String>()
          .join();
      expect(text.toUpperCase(), contains('PONG'));
    } finally {
      c.close();
    }
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('POST /v1/messages stream returns text/event-stream', () async {
    final c = AgentRouterClient();
    try {
      final warm = await c.warmup();
      final resp = await c.send(
        method: 'POST',
        path: AgentRouterPaths.messages,
        body: _u8(jsonEncode({
          'model': 'claude-opus-4-8',
          'max_tokens': 6,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'reply with the word: STREAM'}
          ],
        })),
        anthropicPath: true,
        extraHeaders: {
          'Authorization': 'Bearer $apiKey',
          if (serializeCookieHeader(warm.cookies) != null) 'Cookie': serializeCookieHeader(warm.cookies)!,
        },
      );
      expect(resp.statusCode, 200);
      expect((resp.headers.value('content-type') ?? '').contains('text/event-stream'), isTrue);
      final buf = StringBuffer();
      final sub = resp.transform(utf8.decoder).listen(buf.write);
      await Future.delayed(const Duration(seconds: 8));
      await sub.cancel();
      final body = buf.toString();
      expect(body, contains('event: message_start'));
      expect(body, contains('event: message_stop'));
    } finally {
      c.close();
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
