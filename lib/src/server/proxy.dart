import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../services/api_client.dart';
import '../services/waf.dart';
import 'circuit.dart';
import 'sse.dart';

/// What happened to a single proxied request.
class ProxyOutcome {
  final int statusCode;
  final String? model;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final double costCny;
  final bool streaming;
  final Duration duration;
  ProxyOutcome({
    required this.statusCode,
    this.model,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.costCny = 0,
    required this.streaming,
    required this.duration,
  });
}

/// Callback used to surface a proxy outcome to the rest of the bridge (log
/// store, usage store, etc.) without coupling this module to them.
typedef OutcomeSink = void Function(ProxyOutcome outcome);

/// Forward a single request from [clientReq] to the AgentRouter upstream,
/// attaching the Claude Code spoof headers, the per-profile WAF cookies,
/// and either buffering the response or piping an SSE stream verbatim.
///
/// Returns once the upstream response is fully delivered to the client.
/// [format] determines which terminal event counts as a clean close and
/// which lines (if any) should be scrubbed. [onWafCaptured] is invoked with
/// any fresh WAF cookies seen on the upstream response so the caller can
/// persist them into the active profile (so the next request keeps the
/// rotated cookie).
Future<void> proxyRequest({
  required HttpRequest clientReq,
  required AgentRouterClient upstream,
  required String authHeader,
  required Map<String, String> cookies,
  required StreamFormat format,
  required CircuitBreaker circuit,
  required ModelHealth modelHealth,
  required OutcomeSink onOutcome,
  void Function(List<String> freshCookiePairs)? onWafCaptured,
  void Function(String line)? onLog,
  Duration idleTimeout = const Duration(seconds: 120),
}) async {
  final startedAt = DateTime.now();
  bool streaming = false;
  String? model;
  int inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheCreationTokens = 0;
  double costCny = 0;
  int statusCode = 502;
  bool headersSent = false;

  void logMsg(String msg) {
    final cb = onLog;
    if (cb != null) cb(msg);
  }

  Future<void> sendJsonError(int code, String errCode, String message) async {
    if (headersSent) return;
    clientReq.response.statusCode = code;
    clientReq.response.headers.contentType = ContentType.json;
    clientReq.response.write(jsonEncode({'error': {'code': errCode, 'message': message, 'type': 'proxy_error'}}));
    await clientReq.response.close();
    headersSent = true;
  }

  try {
    if (circuit.isOpen) {
      await sendJsonError(503, 'circuit_open', 'Upstream circuit breaker is open, retry later');
      logMsg('PROXY 503 circuit_open');
      return;
    }

    // Buffer the request body.
    final bodyBytes = <int>[];
    await for (final chunk in clientReq) {
      bodyBytes.addAll(chunk);
    }
    // Best-effort model extraction from JSON.
    if (bodyBytes.isNotEmpty) {
      try {
        final parsed = jsonDecode(utf8.decode(bodyBytes));
        if (parsed is Map) {
          final body = Map<String, dynamic>.from(parsed);
          if (body['model'] is String) model = body['model'] as String;
          if (body['stream'] == true) streaming = true;
          // Normalize OpenAI-native reasoning params into the Anthropic-native
          // `thinking` block for Claude-family models.
          //
          // OpenCode's `@ai-sdk/openai-compatible` (baseURL .../v1) emits
          // `reasoning_effort: "high"` per the OpenAI schema. AgentRouter routes
          // Claude requests to a backend whose schema rejects
          // `thinking.enabled` / `reasoning_effort` and instead wants
          // `output_config.effort` / `thinking.adaptive`. Forwarding the OpenAI
          // body verbatim therefore errors server-side with:
          //   "thinking.enabled is not supported for this model. Use
          //    thinking.adaptive and output_config.effort..."
          // We verified agentrouter.org accepts Anthropic-native
          // `thinking: { type: "enabled", budget_tokens }` (HTTP 200), so we
          // translate here. We only touch Claude-family models so native
          // OpenAI reasoning (e.g. o-series) is left intact for those routes.
        if (format == StreamFormat.openai && model != null) {
          if (normalizeReasoning(model, body)) {
              bodyBytes
                ..clear()
                ..addAll(utf8.encode(jsonEncode(body)));
            }
          }
        }
      } catch (_) {}
    }

    final upstreamResp = await upstream.send(
      method: clientReq.method,
      path: clientReq.uri.path,
      body: bodyBytes.isEmpty ? null : Uint8List.fromList(bodyBytes),
      anthropicPath: format == StreamFormat.anthropic,
      extraHeaders: {
        'Authorization': authHeader,
        if (serializeCookieHeader(cookies) != null) 'Cookie': serializeCookieHeader(cookies)!,
        'Accept': streaming ? 'text/event-stream' : 'application/json',
      },
    );

    statusCode = upstreamResp.statusCode;

    // Capture any WAF cookies the upstream rotated on this response.
    final cb = onWafCaptured;
    if (cb != null) {
      final fresh = extractWafCookiePairs(upstreamResp.headers['set-cookie']);
      if (fresh.isNotEmpty) cb(fresh);
    }

    if (statusCode == 200) {
      circuit.recordSuccess();
    } else if (statusCode >= 500) {
      circuit.recordFailure();
      if (model != null) modelHealth.recordFailure(model, statusCode);
    }

    final ct = upstreamResp.headers.value('content-type') ?? '';
    final isSse = ct.contains('text/event-stream') || (statusCode == 200 && streaming);

    // Lock the upstream status onto the client response BEFORE any header
    // copy / write; dart:io sends headers on the first write, after which
    // changing statusCode is a no-op.
    clientReq.response.statusCode = statusCode;

    // Copy upstream headers to client (drop hop-by-hop).
    _copyHeaders(upstreamResp.headers, clientReq.response.headers, streaming: isSse);

    if (!isSse) {
      // Buffer the whole body.
      final respBody = <int>[];
      await for (final chunk in upstreamResp) {
        respBody.addAll(chunk);
      }
      // Pull billing / usage from JSON if present.
      if (statusCode == 200) {
        try {
          final parsed = jsonDecode(utf8.decode(respBody));
          if (parsed is Map) {
            _extractUsage(parsed, format, (inp, out, cr, cc, cost) {
              inputTokens = inp;
              outputTokens = out;
              cacheReadTokens = cr;
              cacheCreationTokens = cc;
              costCny = cost;
            });
          }
        } catch (_) {}
      }
      clientReq.response.add(respBody);
      await clientReq.response.close();
      headersSent = true;
      logMsg('PROXY $statusCode (${respBody.length} bytes)');
    } else {
      // Streaming path: write status/headers now and let the SSE pump drive
      // the bytes.
      headersSent = true;
      await pumpSse(
        source: upstreamResp.transform(utf8.decoder).transform(const LineSplitter()),
        emit: (line) {
          try {
            clientReq.response.write(line);
            // Track usage deltas.
            if (line.startsWith('data:')) {
              _extractStreamingDelta(line, format, (inp, out, cr, cc) {
                inputTokens += inp;
                outputTokens += out;
                cacheReadTokens += cr;
                cacheCreationTokens += cc;
              });
            }
          } catch (_) {}
        },
        format: format,
        idleTimeout: idleTimeout,
        onLog: onLog,
      );
      try { await clientReq.response.close(); } catch (_) {}
      logMsg('PROXY $statusCode (stream)');
    }
  } on HttpException catch (e) {
    await sendJsonError(502, 'upstream_error', e.message);
    circuit.recordFailure();
    if (model != null) modelHealth.recordFailure(model, 502);
    logMsg('PROXY ERROR ${e.message}');
  } catch (e) {
    await sendJsonError(502, 'upstream_error', e.toString());
    circuit.recordFailure();
    if (model != null) modelHealth.recordFailure(model, 502);
    logMsg('PROXY ERROR $e');
  } finally {
    onOutcome(ProxyOutcome(
      statusCode: statusCode,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheCreationTokens: cacheCreationTokens,
      costCny: costCny,
      streaming: streaming,
      duration: DateTime.now().difference(startedAt),
    ));
  }
}

void _copyHeaders(HttpHeaders src, HttpHeaders dst, {required bool streaming}) {
  const skip = {
    'transfer-encoding',
    'connection',
    'keep-alive',
    'content-length', // dart:io handles this from the body writes
  };
  src.forEach((name, values) {
    final lname = name.toLowerCase();
    if (skip.contains(lname)) return;
    if (lname == 'set-cookie') return; // never echo upstream cookies to localhost clients
    for (final v in values) {
      dst.add(name, v);
    }
  });
  if (streaming) {
    dst.set('X-Accel-Buffering', 'no');
    dst.set('Cache-Control', 'no-cache');
    dst.set('Connection', 'keep-alive');
  }
}

/// Models that are Claude-family on the upstream. The OpenAI-compatible
/// endpoint emits OpenAI-native `reasoning_effort`, which agentrouter.org
/// routes to a backend that rejects it. For these models we normalize to the
/// Anthropic-native `thinking` block instead.
final claudeModelRegex = RegExp(r'^claude-');

bool looksLikeClaude(String model) {
  final m = claudeModelRegex.firstMatch(model);
  return m != null;
}

/// Map OpenAI `reasoning_effort` ("low"/"medium"/"high"/"none") onto an
/// Anthropic-native `thinking` block, mutating [body] in place.
///
/// Anthropic extended thinking requires `budget_tokens` > 0; we also strip
/// the non-standard field so it is not forwarded verbatim.
///
/// `thinking: {enabled:true,...}` (non-standard) is normalized to
/// `{type:'enabled', budget_tokens}` if present.
///
/// Returns `true` if the body was mutated.
bool normalizeReasoning(String model, Map<String, dynamic> body) {
  if (!looksLikeClaude(model)) return false;
  var changed = false;
  final effort = body['reasoning_effort'];
  if (effort is String) {
    final budget = switch (effort) {
      'low' => 1024,
      'medium' => 4096,
      'high' => 8192,
      'none' => null,
      _ => null,
    };
    if (budget != null) {
      body['thinking'] = {'type': 'enabled', 'budget_tokens': budget};
      changed = true;
    } else if (effort == 'none') {
      // Explicitly requested no reasoning: ensure no thinking block.
      body.remove('thinking');
      changed = true;
    }
    body.remove('reasoning_effort');
    changed = true;
  } else if (body['thinking'] is Map && (body['thinking'] as Map).containsKey('enabled')) {
    // Normalize non-standard {enabled:true,...} to Anthropic official
    // {type:'enabled', budget_tokens} if budget_tokens present.
    final thinking = Map<String, dynamic>.from(body['thinking'] as Map);
    if (thinking['enabled'] == true) {
      thinking.remove('enabled');
      thinking['type'] = 'enabled';
      if (thinking['budget_tokens'] == null) thinking['budget_tokens'] = 1024;
      body['thinking'] = thinking;
      changed = true;
    }
  }
  return changed;
}

/// Pull input/output/cache tokens + total cost from a non-streaming response
/// body. Both Anthropic and OpenAI shapes are accepted.
void _extractUsage(
  Map parsed,
  StreamFormat fmt,
  void Function(int input, int output, int cacheRead, int cacheCreation, double cost) sink,
) {
  int input = 0, output = 0, cacheRead = 0, cacheCreation = 0;
  double cost = 0;

  // Anthropic-style: `usage` at top level.
  final usage = parsed['usage'];
  if (usage is Map) {
    input = (usage['input_tokens'] as num?)?.toInt() ?? 0;
    output = (usage['output_tokens'] as num?)?.toInt() ?? 0;
    cacheRead = (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
    cacheCreation = (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
  }
  // OpenAI-style: `usage.prompt_tokens` / `usage.completion_tokens`.
  if (input == 0 && output == 0 && usage is Map) {
    final pt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    final ct = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
    if (pt > 0 || ct > 0) {
      input = pt;
      output = ct;
    }
  }
  // Anthropic billing block (non-stream only): `billing.request.cost_cny.total`.
  final billing = parsed['billing'];
  if (billing is Map) {
    final request = billing['request'];
    if (request is Map) {
      final costCny = request['cost_cny'];
      if (costCny is Map) {
        final t = costCny['total'];
        if (t is String) cost = double.tryParse(t) ?? 0;
      }
    }
  }

  sink(input, output, cacheRead, cacheCreation, cost);
}

/// Accumulate streaming usage deltas. Anthropic sends deltas in
/// `message_delta` / `message_start`; OpenAI sends a single terminal usage.
void _extractStreamingDelta(
  String line,
  StreamFormat fmt,
  void Function(int input, int output, int cacheRead, int cacheCreation) sink,
) {
  if (!line.startsWith('data:')) return;
  final payload = line.substring(5).trim();
  if (payload.isEmpty || payload == '[DONE]' || payload == 'null') return;
  try {
    final parsed = jsonDecode(payload);
    if (parsed is! Map) return;
    int input = 0, output = 0, cacheRead = 0, cacheCreation = 0;
    final usage = parsed['usage'];
    if (usage is Map) {
      input = (usage['input_tokens'] as num?)?.toInt() ?? 0;
      output = (usage['output_tokens'] as num?)?.toInt() ?? 0;
      cacheRead = (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
      cacheCreation = (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
    }
    if (input == 0 && output == 0 && usage is Map) {
      final pt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
      final ct = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
      if (pt > 0 || ct > 0) {
        input = pt;
        output = ct;
      }
    }
    sink(input, output, cacheRead, cacheCreation);
  } catch (_) {}
}
