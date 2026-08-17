import 'dart:convert';
import 'dart:io';

/// A single AgentRouter identity held by the bridge.
///
/// The credential is the chat API key (`sk-...` from the agentrouter.org
/// dashboard). AgentRouter sign-in is OAuth-only and the bridge cannot
/// capture the provider session cookie automatically (GitHub rejects an
/// unregistered `redirect_uri`), so a profile is API-key only. Session
/// tokens and account-info enrichment were removed: they never fed the
/// proxy path, and quota/usage is available from the OpenAI-style billing
/// endpoints with the API key alone.
///
/// `wafCookies` holds the live WAF session cookies (`acw_tc` plus any
/// rotated siblings) so the proxy does not have to re-warm after restart.
/// `modelCache` is the most recent successful `/v1/models` response
/// (per-key model permissions); the local proxy merges this with the
/// static fallback list before serving `/v1/models`. `apiKeyAt` is when the
/// current [apiKey] was stored (falls back to [createdAt] for legacy rows).
class Profile {
  final String id;
  final String name;
  final String apiKey;
  final DateTime createdAt;
  final DateTime? apiKeyAt;
  final Map<String, String> wafCookies;
  final List<String> modelCache;

  Profile({
    required this.id,
    required this.name,
    required this.apiKey,
    required this.createdAt,
    this.apiKeyAt,
    this.wafCookies = const {},
    this.modelCache = const [],
  });

  Profile copyWith({
    String? name,
    String? apiKey,
    DateTime? apiKeyAt,
    Map<String, String>? wafCookies,
    List<String>? modelCache,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      apiKey: apiKey ?? this.apiKey,
      createdAt: createdAt,
      apiKeyAt: apiKeyAt ?? this.apiKeyAt,
      wafCookies: wafCookies ?? this.wafCookies,
      modelCache: modelCache ?? this.modelCache,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apiKey': apiKey,
        'createdAt': createdAt.toIso8601String(),
        if (apiKeyAt != null) 'apiKeyAt': apiKeyAt!.toIso8601String(),
        'wafCookies': wafCookies,
        'modelCache': modelCache,
      };

  factory Profile.fromJson(Map<String, dynamic> json) {
    final waf = (json['wafCookies'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? <String, String>{};
    final cache = (json['modelCache'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    return Profile(
      id: json['id'] as String,
      name: json['name'] as String,
      apiKey: json['apiKey'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      apiKeyAt: json['apiKeyAt'] != null ? DateTime.parse(json['apiKeyAt'] as String) : null,
      wafCookies: waf,
      modelCache: cache,
    );
  }
}

/// Persistent app-level config: port, listen address, active profile id,
/// optional inbound auth token. Persisted to `config.json` (mode 0600).
class AppConfig {
  static const defaultPort = 8318;
  static const defaultListenAddress = '127.0.0.1';

  int serverPort;
  String listenAddress;
  String? activeProfileId;
  String proxyAuthToken;

  /// Strip oversized system-prompt context blocks before forwarding.
  ///
  /// Defaults to `false`. Empirical testing against agentrouter.org's input
  /// content filter (2026-08) shows the filter judges the presence of a
  /// coherent English instruction block in the system message, not the
  /// language mix of the whole payload. Trimming the system prompt removes
  /// that anchor and can cause `content-blocked` rejections, and it does not
  /// measurably raise the upstream 504 prefill ceiling. Leave it off unless
  /// a specific deployment needs the old v0.1.6 behavior.
  bool trimSystemPrompt;

  /// Local date (`YYYY-MM-DD`) of the last day the user marked the AgentRouter
  /// daily claim as done. When it no longer matches today, the TUI shows the
  /// `Daily Claim!` badge again until `[Shift+M]` / the claim dialog marks the
  /// new day as done.
  String? dailyClaimDoneDate;

  AppConfig({
    this.serverPort = defaultPort,
    this.listenAddress = defaultListenAddress,
    this.activeProfileId,
    this.proxyAuthToken = '',
    this.trimSystemPrompt = false,
    this.dailyClaimDoneDate,
  });

  Map<String, dynamic> toJson() => {
        'serverPort': serverPort,
        'listenAddress': listenAddress,
        if (activeProfileId != null) 'activeProfileId': activeProfileId,
        'proxyAuthToken': proxyAuthToken,
        'trimSystemPrompt': trimSystemPrompt,
        if (dailyClaimDoneDate != null) 'dailyClaimDoneDate': dailyClaimDoneDate,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        serverPort: json['serverPort'] as int? ?? defaultPort,
        listenAddress: json['listenAddress'] as String? ?? defaultListenAddress,
        activeProfileId: json['activeProfileId'] as String?,
        proxyAuthToken: json['proxyAuthToken'] as String? ?? '',
        trimSystemPrompt: json['trimSystemPrompt'] as bool? ?? false,
        dailyClaimDoneDate: json['dailyClaimDoneDate'] as String?,
      );
}

String _homeDir() {
  if (Platform.isWindows) {
    return Platform.environment['USERPROFILE'] ?? r'C:\Users\Default';
  }
  return Platform.environment['HOME'] ?? '/root';
}

/// Test-only override for the config directory. When non-null, [configDir]
/// returns this path verbatim. Production code never sets it.
String? configDirOverride;

String configDir() {
  if (configDirOverride != null) return configDirOverride!;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'] ?? r'C:\Users\Default\AppData\Roaming';
    return '$appData${Platform.pathSeparator}agrout-bridge';
  }
  return '${_homeDir()}${Platform.pathSeparator}.config${Platform.pathSeparator}agrout-bridge';
}

String _profilesPath() => '${configDir()}${Platform.pathSeparator}profiles.json';
String _configPath() => '${configDir()}${Platform.pathSeparator}config.json';

void _ensureConfigDir() {
  final dir = Directory(configDir());
  if (!dir.existsSync()) dir.createSync(recursive: true);
}

/// Atomically write JSON content to [path] with mode 0600 (owner-only).
/// On Windows the chmod is a no-op (NTFS permissions are handled by the OS).
void writeSecretJson(String path, Object content) {
  _ensureConfigDir();
  final tmp = File('$path.tmp');
  tmp.writeAsStringSync(jsonEncode(content), flush: true);
  if (!Platform.isWindows) {
    // chmod the temp before rename so the final file inherits the mode.
    // rename(2) preserves the inode (and its mode) on the same filesystem.
    Process.runSync('chmod', ['600', tmp.path]);
  }
  tmp.renameSync(path);
}

class ConfigStore {
  AppConfig _config = AppConfig();
  String? _error;

  AppConfig get config => _config;
  String? get error => _error;

  void load() {
    final file = File(_configPath());
    if (!file.existsSync()) {
      _config = AppConfig();
      _error = null;
      return;
    }
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _config = AppConfig.fromJson(data);
      _error = null;
    } catch (e) {
      _config = AppConfig();
      _error = 'Failed to parse config: $e';
    }
  }

  void save() {
    writeSecretJson(_configPath(), _config.toJson());
  }
}

class ProfileStore {
  final Map<String, Profile> _byId = {};
  String? _error;

  String? get error => _error;
  List<Profile> get all => _byId.values.toList(growable: false);

  Profile? byId(String id) => _byId[id];
  Profile? byName(String name) {
    for (final p in _byId.values) {
      if (p.name == name) return p;
    }
    return null;
  }

  void load() {
    final file = File(_profilesPath());
    if (!file.existsSync()) {
      _error = null;
      return;
    }
    try {
      final data = jsonDecode(file.readAsStringSync());
      final list = data is List
          ? data
          : (data is Map && data['profiles'] is List)
              ? data['profiles'] as List
              : <dynamic>[];
      _byId.clear();
      for (final entry in list) {
        final p = Profile.fromJson((entry as Map).cast<String, dynamic>());
        _byId[p.id] = p;
      }
      _error = null;
    } catch (e) {
      _error = 'Failed to parse profiles: $e';
    }
  }

  void save() {
    writeSecretJson(_profilesPath(), _byId.values.map((p) => p.toJson()).toList());
  }

  /// Add a new profile. Throws [StateError] if the name or id is already taken.
  Profile add({required String name, required String apiKey}) {
    if (byName(name) != null) throw StateError('Profile "$name" already exists');
    final id = _generateId(name);
    if (_byId.containsKey(id)) throw StateError('Profile id collision: $id');
    final profile = Profile(
      id: id,
      name: name,
      apiKey: apiKey,
      createdAt: DateTime.now(),
      apiKeyAt: DateTime.now(),
    );
    _byId[profile.id] = profile;
    save();
    return profile;
  }

  /// Upsert helper for callers that have already mutated a profile via
  /// [Profile.copyWith]. Persists immediately and returns the stored profile.
  Profile upsert(Profile profile) {
    _byId[profile.id] = profile;
    save();
    return profile;
  }

  /// Remove by id. Returns true if a profile was removed.
  bool remove(String id) {
    final removed = _byId.remove(id);
    if (removed == null) return false;
    save();
    return true;
  }

  static int _seq = 0;
  static String _generateId(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final seq = (++_seq).toRadixString(36);
    final id = base.isEmpty ? '$stamp-$seq' : '$base-$stamp-$seq';
    return id;
  }
}
