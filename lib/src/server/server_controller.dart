/// Local HTTP proxy server.
///
/// Routes:
///   GET  /health, /api/health   -> JSON status (no auth)
///   GET  /v1/models, /models    -> live model list, unhealthy filtered (no auth)
///   GET  /v1/token              -> returns active profile's API key (no auth, localhost-only by default)
///   GET  /info                  -> bridge info + config (no auth)
///   POST /v1/messages, /messages -> Anthropic proxy (spoof + WAF)
///   POST /v1/chat/completions   -> OpenAI proxy (spoof + WAF)
///
/// If [AppConfig.proxyAuthToken] is set, the proxy requires
/// `Authorization: Bearer <token>` or `X-Proxy-Token: <token>` on all
/// upstream routes (health + models stay open so 9Router/OpenCode can
/// import without sending auth headers).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import '../models/version.dart';
import '../services/api_client.dart';
import '../services/usage_store.dart';
import '../services/waf.dart';
import 'circuit.dart';
import 'proxy.dart';
import 'sse.dart';

/// Snapshot of server state exposed to the TUI.
class ServerStatus {
  final String listenAddress;
  final int port;
  final bool running;
  final int activeStreams;
  final Map<String, String> wafCookies;
  final Map<String, dynamic> circuit;
  final Map<String, dynamic> modelHealth;
  final int modelCount;
  final String? activeProfileId;
  final DateTime startedAt;
  ServerStatus({
    required this.listenAddress,
    required this.port,
    required this.running,
    required this.activeStreams,
    required this.wafCookies,
    required this.circuit,
    required this.modelHealth,
    required this.modelCount,
    required this.activeProfileId,
    required this.startedAt,
  });
}

class ServerController {
  final ProfileStore profiles;
  final ConfigStore configStore;
  final AgentRouterClient client;
  final CircuitBreaker circuit = CircuitBreaker();
  final ModelHealth modelHealth = ModelHealth();

  HttpServer? _server;
  int _activeStreams = 0;
  final DateTime _startedAt = DateTime.now();
  int _modelCacheVersion = 0;
  List<String> _modelCache = [];

  ServerController({required this.profiles, required this.configStore})
      : client = AgentRouterClient();

  /// Current server status snapshot. Cheap to call; used by the TUI tick.
  ServerStatus status() => ServerStatus(
        listenAddress: configStore.config.listenAddress,
        port: configStore.config.serverPort,
        running: _server != null,
        activeStreams: _activeStreams,
        wafCookies: _activeProfileSnapshot()?.wafCookies ?? const {},
        circuit: circuit.snapshot(),
        modelHealth: modelHealth.snapshot(),
        modelCount: _modelCache.length,
        activeProfileId: configStore.config.activeProfileId,
        startedAt: _startedAt,
      );

  /// Start the server. Idempotent: if a server is already running, returns.
  ///
  /// If the configured [serverPort] is already in use, the bridge will
  /// automatically try the next free port (serverPort+1, +2, ...) up to
  /// `serverPort + maxPortAttempts`, so a stale process on 8318 does not
  /// block startup. The bound port is persisted into the config store so
  /// /info, the TUI and logs report the actual listen port.
  static const maxPortAttempts = 25;

  Future<int> start() async {
    if (_server != null) return _server!.port;
    final addr = InternetAddress(configStore.config.listenAddress);
    int candidate = configStore.config.serverPort;
    HttpServer? server;
    var tries = 0;
    while (tries < maxPortAttempts) {
      try {
        server = await HttpServer.bind(addr, candidate);
        break;
      } on SocketException {
        // Any bind failure (port in use, shared-flag conflict, etc.) ->
        // treat as "port unavailable" and move to the next candidate.
        // Dart surfaces port conflicts under several different messages
        // depending on the platform and whether a peer listener exists, so
        // we do not narrow on a substring here.
        tries += 1;
        if (candidate == configStore.config.serverPort) {
          // ignore: avoid_print
          print('port $candidate in use, retrying nearby');
        }
        candidate += 1;
        continue;
      }
    }
    if (server == null) {
      throw SocketException(
          'no free port in range ${configStore.config.serverPort}..'
          '${configStore.config.serverPort + maxPortAttempts - 1}');
    }
    _server = server;
    if (candidate != configStore.config.serverPort) {
      // Persist the actual bound port so /info + TUI reflect reality.
      try {
        configStore.config.serverPort = candidate;
        configStore.save();
      } catch (_) {}
    }
    _server!.listen(_handle, onError: (e) {
      // ignore: avoid_print
      print('server error: $e');
    });
    return _server!.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
    client.close();
  }

  /// Refresh the local model cache by calling /v1/models live. Called by
  /// the TUI on `[r]` and at startup if a profile is active.
  Future<List<String>> refreshModels() async {
    final profile = _activeProfileSnapshot();
    if (profile == null) return _modelCache;
    try {
      // Make sure we have at least a fresh warmup.
      final warm = await client.warmup(existingCookies: profile.wafCookies);
      final models = await client.fetchModels(apiKey: profile.apiKey, cookies: warm.cookies);
      _modelCache = modelHealth.filter(models);
      _modelCacheVersion++;
      _persistProfileWaf(profile.id, warm.cookies, models);
      return _modelCache;
    } catch (_) {
      return _modelCache;
    }
  }

  int get modelCacheVersion => _modelCacheVersion;

  /// The most recent model id list returned by `/v1/models` (or the static
  /// fallback). Used by the TUI's Models page.
  List<String> get modelIds => List.unmodifiable(_modelCache);

  Profile? _activeProfileSnapshot() {
    final id = configStore.config.activeProfileId;
    if (id == null) return null;
    return profiles.byId(id);
  }

  void _persistProfileWaf(String id, Map<String, String> cookies, List<String> models) {
    final p = profiles.byId(id);
    if (p == null) return;
    final updated = p.copyWith(wafCookies: cookies, modelCache: models);
    profiles.upsert(updated);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;

    // Open endpoints
    if (method == 'GET' && (path == '/health' || path == '/api/health')) {
      _respondHealth(req);
      return;
    }
    if (method == 'GET' && (path == '/v1/models' || path == '/models')) {
      await _respondModels(req);
      return;
    }
    if (method == 'GET' && path == '/info') {
      _respondInfo(req);
      return;
    }
    if (method == 'GET' && path == '/v1/token') {
      _respondToken(req);
      return;
    }

    // Proxy endpoints (require profile + optional auth). Fire-and-forget:
    // each handler owns the response lifecycle (writes, closes) and a
    // top-level await would block the server from accepting new connections
    // while a slow upstream is in flight.
    if (method == 'POST' && (path == '/v1/messages' || path == '/messages')) {
      unawaited(_proxyAnthropic(req));
      return;
    }
    if (method == 'POST' && path == '/v1/chat/completions') {
      unawaited(_proxyOpenAi(req));
      return;
    }

    // Unknown route
    req.response.statusCode = 404;
    req.response.write(jsonEncode({'error': {'code': 'not_found', 'message': 'Route $method $path not found'}}));
    await req.response.close();
  }

  bool _requireProxyAuth(HttpRequest req) {
    final token = configStore.config.proxyAuthToken;
    if (token.isEmpty) return true;
    final bearer = RegExp(r'^Bearer\s+(.+)$', caseSensitive: false).firstMatch(req.headers.value('authorization') ?? '');
    final candidates = [
      req.headers.value('x-proxy-token'),
      if (bearer != null) bearer.group(1),
    ];
    for (final c in candidates) {
      if (c != null && _constantTimeEqual(c, token)) return true;
    }
    return false;
  }

  bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  void _respondHealth(HttpRequest req) {
    final s = status();
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'ok': true,
      'upstream': 'agentrouter.org:443',
      'listen': '${s.listenAddress}:${s.port}',
      'running': s.running,
      'activeStreams': s.activeStreams,
      'wafCookies': s.wafCookies.keys.toList(),
      'circuit': s.circuit,
      'modelHealth': s.modelHealth,
      'modelCount': _modelCache.length,
      'activeProfile': s.activeProfileId,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
    }));
    req.response.close();
  }

  void _respondInfo(HttpRequest req) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'name': 'agrout-bridge',
      'version': bridgeVersion,
      'listenAddress': configStore.config.listenAddress,
      'serverPort': configStore.config.serverPort,
      'activeProfileId': configStore.config.activeProfileId,
      'proxyAuthEnabled': configStore.config.proxyAuthToken.isNotEmpty,
    }));
    req.response.close();
  }

  void _respondToken(HttpRequest req) {
    final profile = _activeProfileSnapshot();
    if (profile == null) {
      req.response.statusCode = 404;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': {'code': 'no_active_profile', 'message': 'No active profile configured'}}));
      req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({'token': profile.apiKey, 'profile': profile.name}));
    req.response.close();
  }

  Future<void> _respondModels(HttpRequest req) async {
    if (!_requireProxyAuth(req)) {
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': {'code': 'unauthorized', 'message': 'Invalid or missing proxy auth token'}}));
      await req.response.close();
      return;
    }
    if (_modelCache.isEmpty) {
      await refreshModels();
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'object': 'list',
      'data': _modelCache.map((id) => {
            'id': id,
            'object': 'model',
            'created': 1626777600,
            'owned_by': 'custom',
          }).toList(),
    }));
    await req.response.close();
  }

  Future<void> _proxyAnthropic(HttpRequest req) async {
    await _proxyPassthrough(req, StreamFormat.anthropic);
  }

  Future<void> _proxyOpenAi(HttpRequest req) async {
    await _proxyPassthrough(req, StreamFormat.openai);
  }

  Future<void> _proxyPassthrough(HttpRequest req, StreamFormat fmt) async {
    if (!_requireProxyAuth(req)) {
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': {'code': 'unauthorized', 'message': 'Invalid or missing proxy auth token'}}));
      await req.response.close();
      return;
    }
    final profile = _activeProfileSnapshot();
    if (profile == null) {
      req.response.statusCode = 503;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'error': {'code': 'no_active_profile', 'message': 'No active profile configured'}}));
      await req.response.close();
      return;
    }
    _activeStreams++;
    try {
      await proxyRequest(
        clientReq: req,
        upstream: client,
        authHeader: 'Bearer ${profile.apiKey}',
        cookies: profile.wafCookies,
        format: fmt,
        circuit: circuit,
        modelHealth: modelHealth,
        onWafCaptured: (fresh) {
          // Persist refreshed WAF cookies into the active profile.
          final merged = mergeWafCookies(profile.wafCookies, fresh);
          profiles.upsert(profile.copyWith(wafCookies: merged));
        },
        onOutcome: (o) {
          UsageStore().record(o);
        },
        onLog: (msg) {
          // ignore: avoid_print
          print('[${DateTime.now().toIso8601String()}] $msg');
        },
      );
    } finally {
      _activeStreams--;
    }
  }
}
