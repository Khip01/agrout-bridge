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
  bool trimSystemPrompt = false,
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
          // Trim oversized system messages (Opencode/Claude Code emit a very
          // large system prompt with memory/skills/journal blocks) to avoid
          // tripping agentrouter.org's input content filter / quota. Mirrors
          // the approach used by Lyravein's agentrouter-bridge.
          //
          // Disabled by default: the trim removes the English instruction
          // anchor the content filter actually judges, and empirical testing
          // shows it neither reduces content-blocked nor raises the upstream
          // 504 prefill ceiling. Enable only via config.trimSystemPrompt for
          // legacy behavior.
          if (trimSystemPrompt) {
            trimSystemMessages(body);
          }
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
          // Neutralize base64-encoded content (WebFetch markdown data URIs,
          // file-read media blobs) before forwarding. Large accumulated base64
          // trips agentrouter.org's content filter with a hard
          // `content-blocked` even though the rest of the request is clean.
          // Scrub always runs so both OpenAI and Anthropic paths are covered.
          if (scrubBase64Payload(body)) {
            bodyBytes
              ..clear()
              ..addAll(utf8.encode(jsonEncode(body)));
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
        // Spoof the Claude Code client UA so agentrouter.org's
        // client-fingerprint layer accepts the request (only this UA is
        // whitelisted; other clients get 401 unauthorized_client_detected).
        'User-Agent': 'opencode/1.0',
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
          // Drop upstream content-filter / billing lines that would otherwise
          // terminate the stream for the client (mirrors Lyravein's approach).
          // These lines appear mid-stream when agentrouter.org's gate or the
          // backend emits a soft block / budget summary that should not abort
          // the whole chat. Dropping them lets the rest of the stream through.
          final low = line.toLowerCase();
          if (line.startsWith('data:') &&
              (low.contains('content_blocked') ||
               low.contains('sensitive_words') ||
               low.contains('billing.summary') ||
               low.trim() == 'data: null')) {
            onLog?.call('sse filtered: ${line.substring(0, line.length > 80 ? 80 : line.length)}');
            return;
          }
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

/// Base64 data URIs, e.g. `data:image/png;base64,iVBOR...`. WebFetch and
/// file-read tool results commonly embed logo/font bytes as base64 data URIs;
/// a large accumulated base64 payload trips agentrouter.org's content filter
/// (measured threshold ~2.2k chars per request). We replace the whole URI
/// with a short placeholder before forwarding.
final _base64DataUriRegex = RegExp(r'data:[^,]{1,128};base64,[A-Za-z0-9+/=]+');

/// Long bare base64 runs (>= 200 chars) not wrapped in a data URI. Encoded
/// blobs of this size read as obfuscated content to the upstream filter, so
/// collapse them to a placeholder. 200 chars per run keeps any realistic
/// request far below the measured ~2.2k aggregate trigger.
final _longBase64RunRegex = RegExp(r'[A-Za-z0-9+/]{200,}={0,2}');

const _base64Placeholder = '[base64 data stripped by bridge]';

String _scrubBase64String(String input) {
  var out = input;
  out = out.replaceAll(_base64DataUriRegex, _base64Placeholder);
  out = out.replaceAll(_longBase64RunRegex, _base64Placeholder);
  return out;
}

dynamic _scrubBase64Value(dynamic value) {
  if (value is String) return _scrubBase64String(value);
  if (value is List) {
    for (var i = 0; i < value.length; i++) {
      value[i] = _scrubBase64Value(value[i]);
    }
    return value;
  }
  if (value is Map) {
    for (final k in value.keys.toList()) {
      value[k] = _scrubBase64Value(value[k]);
    }
    return value;
  }
  return value;
}

/// Remove base64-encoded content from the request body in place so the
/// forwarded payload stays under agentrouter.org's content-filter threshold.
/// Returns `true` if any string was mutated.
///
/// This is safe for both OpenAI and Anthropic shapes because it walks every
/// JSON string value (system, user, assistant, tool results, content blocks,
/// tool call inputs) without assuming a particular schema. Plain text,
/// URLs, JSON tool arguments and short tokens are left untouched.
bool scrubBase64Payload(Map<String, dynamic> body) {
  final before = jsonEncode(body);
  for (final k in body.keys.toList()) {
    body[k] = _scrubBase64Value(body[k]);
  }
  return jsonEncode(body) != before;
}

/// Max character length for a single system message before trimming.
const _maxSystemChars = 8000;

/// Tags that OpenCode/Claude Code inject into the system message which carry
/// large variable context (memories, available skills, journal entries,
/// instructions). These are the biggest contributors to oversized system
/// prompts and the most likely false-positive content-filter triggers, so we
/// strip them. Mirrors Lyravein's agentrouter-bridge sanitization.
final _systemStripTags = RegExp(
  r'<memory_blocks>[\s\S]*?</memory_blocks>|'
  r'<available_skills>[\s\S]*?</available_skills>|'
  r'<memory_instructions>[\s\S]*?</memory_instructions>|'
  r'<journal_instructions>[\s\S]*?</journal_instructions>',
  dotAll: true,
);

/// Trim oversized system messages in [body.messages] so the forwarded request
/// stays within agentrouter.org's input filter tolerance. Strips the large
/// dev-injected context tags and hard-caps any remaining system message at
/// [_maxSystemChars]. Only `role == 'system'` messages are touched; all
/// user/assistant content is forwarded verbatim.
void trimSystemMessages(Map<String, dynamic> body) {
  final msgs = body['messages'];
  if (msgs is! List) return;
  var changed = false;
  for (final m in msgs) {
    if (m is! Map) continue;
    if (m['role'] != 'system') continue;
    final content = m['content'];
    if (content is! String) continue;
    final stripped = content.replaceAll(_systemStripTags, '');
    if (stripped != content) {
      changed = true;
      m['content'] = stripped;
    }
    if ((m['content'] as String).length > _maxSystemChars) {
      changed = true;
      m['content'] = (m['content'] as String).substring(0, _maxSystemChars) +
          '\n\n[system prompt trimmed by bridge to reduce content-filter false positives]';
    }
  }
  if (changed) {
    body['messages'] = msgs;
  }
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
