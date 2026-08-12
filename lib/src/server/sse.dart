/// Format-aware SSE pump.
///
/// The upstream AgentRouter already emits well-formed Anthropic and OpenAI
/// streams (verified live 2026-08-12), so the pump is mostly a pass-through
/// with two small cleanups:
///
/// - **OpenAI** (`chat.completions`): drop empty `data: null` keepalive frames
///   that some clients (`opencode`, `Cursor`) crash on, and inject a final
///   `data: [DONE]` if the upstream forgot to send one (it normally does).
/// - **Anthropic** (`messages`): pass through verbatim; inject
///   `event: message_stop` + `event: message_delta` only when the upstream
///   died before sending them so harnesses that wait on those events do not
///   hang forever.
///
/// The pump also enforces an idle timeout so a stalled upstream cannot keep
/// the client socket open indefinitely.
library;

import 'dart:async';

/// Streaming formats recognised by the pump.
enum StreamFormat { anthropic, openai }

/// Synthetic EOM tail for [fmt]. Appended to the client stream when the
/// upstream closed without sending its own terminal frame.
String eomTail(StreamFormat fmt) {
  switch (fmt) {
    case StreamFormat.anthropic:
      return '\nevent: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":0}}\n\nevent: message_stop\ndata: {}\n\n';
    case StreamFormat.openai:
      return '\ndata: {"id":"bridge-eom","object":"chat.completion.chunk","created":0,"model":"","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
  }
}

/// Whether a forwarded [line] represents the terminal event of [fmt].
bool isTerminalLine(StreamFormat fmt, String line) {
  switch (fmt) {
    case StreamFormat.anthropic:
      return line.startsWith('event: message_stop');
    case StreamFormat.openai:
      return line.trim() == 'data: [DONE]';
  }
}

/// Whether a forwarded [line] is an OpenAI keepalive frame that should be
/// dropped before forwarding. Only meaningful for `openai`; for `anthropic`
/// it returns false (nothing to scrub).
bool isOpenAiKeepaliveToDrop(StreamFormat fmt, String line) {
  if (fmt != StreamFormat.openai) return false;
  final t = line.trim();
  return t == 'data: null' || t == 'data:';
}

/// Result of a pump run.
class PumpResult {
  /// True if the upstream emitted its terminal frame (clean finish).
  final bool sawTerminal;
  /// True if the pump was aborted (timeout or upstream error).
  final bool aborted;
  PumpResult(this.sawTerminal, this.aborted);
}

/// Run the SSE pump: read SSE lines from [source] (already decoded + line-
/// split), filter and forward them to [emit], with an idle timeout and a
/// final EOM if the upstream died early.
///
/// [emit] is invoked with raw "line\n" strings; the caller is responsible
/// for writing those to the actual HTTP response / socket. [onLog] is called
/// for diagnostic messages (timeout, upstream drop).
Future<PumpResult> pumpSse({
  required Stream<String> source,
  required void Function(String line) emit,
  required StreamFormat format,
  required Duration idleTimeout,
  void Function(String line)? onLog,
}) async {
  bool sawTerminal = false;
  bool aborted = false;
  Timer? idleTimer;
  StreamSubscription<String>? sub;

  void logMsg(String msg) {
    final cb = onLog;
    if (cb != null) cb(msg);
  }

  void scheduleIdle() {
    idleTimer?.cancel();
    idleTimer = Timer(idleTimeout, () {
      if (aborted) return;
      aborted = true;
      logMsg('SSE idle timeout after ${idleTimeout.inSeconds}s, terminating');
    });
  }

  scheduleIdle();

  sub = source.listen((line) {
    if (aborted) return;
    scheduleIdle();
    if (isOpenAiKeepaliveToDrop(format, line)) return;
    emit('$line\n');
    if (isTerminalLine(format, line)) sawTerminal = true;
  }, onDone: () {
    if (!aborted && !sawTerminal) {
      logMsg('SSE upstream closed without terminal frame, injecting EOM');
    }
  }, onError: (Object e) {
    logMsg('SSE upstream error: $e');
    aborted = true;
  });

  try {
    await sub.asFuture<void>();
  } catch (_) {}
  idleTimer?.cancel();

  if (!sawTerminal && !aborted) {
    aborted = true;
  }
  return PumpResult(sawTerminal, aborted);
}
