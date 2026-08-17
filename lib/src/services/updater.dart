import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import '../models/version.dart';

class UpdateResult {
  final bool success;
  final String? message;
  UpdateResult({required this.success, this.message});
  factory UpdateResult.ok(String msg) => UpdateResult(success: true, message: msg);
  factory UpdateResult.fail(String msg) => UpdateResult(success: false, message: msg);
}

/// Injectable HTTP fetcher signature. Tests inject a stub that points at a
/// local HttpServer; production calls the default implementation which uses
/// dart:io [HttpClient].
typedef UpdaterHttpFetch = Future<({int statusCode, String body})> Function(
  String url,
  Map<String, String> headers,
);

/// Self-update: discover the latest stable tag for `Khip01/agrout-bridge`,
/// compare to `bridgeVersion`, download the tarball asset, remove the
/// existing npm global install, and re-run `npm install -g`.
class Updater {
  static const _owner = 'Khip01';
  static const _repo = 'agrout-bridge';
  static const _apiBase = 'https://api.github.com';
  static const _dlBase = 'https://github.com/$_owner/$_repo/releases/download';

  /// `latest.json` mirrors the newest stable release tag. It is served by
  /// plain-file endpoints (raw.githubusercontent.com first, then the jsDelivr
  /// CDN) instead of the rate-limited GitHub API, so the check can refresh
  /// quickly and reflect release deletions without hitting API limits.
  ///
  /// Order matters: raw.githubusercontent.com always serves the freshly-pushed
  /// `main` file, so it is the authoritative source. jsDelivr is only a
  /// fallback: a CDN might lag behind a push (briefly hiding a new release)
  /// or, worse, carry a copy of a DELETED release (a phantom update). The raw
  /// source must win both ways, so it is checked first and a later failure
  /// falls through to jsDelivr rather than letting a mirror outbid it.
  static const _latestJsonSources = [
    'https://raw.githubusercontent.com/$_owner/$_repo/main/latest.json',
    'https://cdn.jsdelivr.net/gh/$_owner/$_repo@main/latest.json',
  ];

  /// Short TTL so a stale cache can never keep a new release hidden for long:
  /// after a release the badge appears within a minute, and removals/re-rolls
  /// clear quickly too. The primary source is a plain file (no GitHub API
  /// rate limit), so refetching is cheap.
  static const _cacheTtlMs = 60 * 1000; // 1 minute

  /// Suffixes that mark a tag as a prerelease (filtered out by the updater).
  static const _prereleaseMarkers = [
    '-rc', '-beta', '-alpha', '-preview', '-dev',
  ];

  final UpdaterHttpFetch _httpFetch;

  Updater({UpdaterHttpFetch? httpFetch}) : _httpFetch = httpFetch ?? _realHttpFetch;

  static Future<({int statusCode, String body})> _realHttpFetch(
    String url,
    Map<String, String> headers,
  ) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      return (statusCode: resp.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  /// Read the cached latest tag if it is younger than [_cacheTtlMs].
  String? _readCache() {
    try {
      final f = File('${configDir()}${Platform.pathSeparator}update-cache.json');
      if (!f.existsSync()) return null;
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final at = (data['at'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - at > _cacheTtlMs) return null;
      return data['tag'] as String?;
    } catch (_) {
      return null;
    }
  }

  void _writeCache(String tag) {
    try {
      final dir = Directory(configDir());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('${configDir()}${Platform.pathSeparator}update-cache.json').writeAsStringSync(jsonEncode({
        'tag': tag,
        'at': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  /// Invalidate the local version cache. The next `update` will refetch.
  void clearCache() {
    try {
      final f = File('${configDir()}${Platform.pathSeparator}update-cache.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static const _apiHeaders = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'agrout-bridge-cli',
  };

  /// Fetch the latest stable tag for the bridge.
  ///
  /// Resolution order:
  ///   1. `latest.json` from a CDN (jsDelivr), falling back to
  ///      raw.githubusercontent.com. These are plain file CDNs, not the
  ///      rate-limited GitHub API, so fetching is cheap and the tag reflects
  ///      the latest *published* release. Deleting a release only requires
  ///      updating `latest.json` (or it naturally stays behind and the CDN
  ///      cache expires), so the badge is dynamic instead of being pinned to
  ///      a long TTL dead cache entry.
  ///   2. The GitHub **Tags API** (`/repos/.../tags`), which is deliberately
  ///      used over `/releases/latest` because releases/latest is flaky (404s
  ///      when no release object is marked `isLatest`) while tags + assets
  ///      are always present. Prerelease tags are filtered; the highest
  ///      stable semver wins.
  ///
  /// When [forceRefresh] is true, the local cache is bypassed and updated on
  /// success. The explicit `update` command always passes `forceRefresh: true`
  /// so it always reflects real upstream truth, never a stale cache entry.
  /// On network or CDN failure we fall back down the chain and, finally, to
  /// the local cache rather than hard-failing.
  Future<String?> fetchLatestTag({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _readCache();
      if (cached != null) return cached;
    }
    final tag = await _fetchLatestStableTag();
    if (tag != null) {
      _writeCache(tag);
      return tag;
    }
    // CDN/API/network failure: degrade gracefully to the cache so callers
    // can still report last-known state instead of erroring.
    return _readCache();
  }

  /// Determine the latest stable tag: try the CDN `latest.json` first, then
  /// the GitHub Tags API as a fallback. Returns `null` when nothing could be
  /// determined (network error, non-200, empty).
  Future<String?> _fetchLatestStableTag() async {
    final fromFile = await _fetchLatestTagFromCdns();
    if (fromFile != null) return fromFile;
    return _fetchLatestFromTagsApi();
  }

  /// Try each `latest.json` mirror in order and return its first semver-valid
  /// tag, or `null` if every source failed.
  ///
  /// raw.githubusercontent.com is checked first because it always serves the
  /// freshly-pushed `main` file; jsDelivr is only a fallback when the raw
  /// source fails. A mirror is never allowed to OUTBID the raw source:
  /// otherwise a lagging jsDelivr copy of a DELETED release would keep showing
  /// a phantom "update available" forever. Deletions are reflected by lowering
  /// `latest.json`, and that lower value must win immediately.
  Future<String?> _fetchLatestTagFromCdns() async {
    for (final url in _latestJsonSources) {
      try {
        final r = await _httpFetch(url, const {
          'Accept': 'application/json',
          'User-Agent': 'agrout-bridge-cli',
        });
        if (r.statusCode != 200) continue;
        final data = jsonDecode(r.body);
        if (data is! Map<String, dynamic>) continue;
        final rawTag = (data['tag'] ?? data['version']) as String?;
        if (rawTag == null || _isPrereleaseTag(rawTag)) continue;
        final parsed = parseSemver(rawTag);
        if (parsed == null) continue;
        return rawTag;
      } catch (_) {
        // Try the next source.
        continue;
      }
    }
    return null;
  }

  /// Query the GitHub Tags API and return the highest stable semver tag, or
  /// `null` if it could not be determined.
  Future<String?> _fetchLatestFromTagsApi() async {
    try {
      final r = await _httpFetch('$_apiBase/repos/$_owner/$_repo/tags?per_page=100', _apiHeaders);
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      if (data is! List) return null;
      final tags = <String>[];
      for (final t in data) {
        if (t is Map && t['name'] is String) tags.add(t['name'] as String);
      }
      String? best;
      List<int>? bestV;
      for (final t in tags) {
        if (_isPrereleaseTag(t)) continue;
        final v = parseSemver(t);
        if (v == null) continue;
        if (best == null || compareSemver(v, bestV!) > 0) {
          best = t;
          bestV = v;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  static bool _isPrereleaseTag(String tag) {
    final lower = tag.toLowerCase();
    for (final m in _prereleaseMarkers) {
      if (lower.contains(m)) return true;
    }
    return false;
  }

  static List<int>? parseSemver(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(v.trim());
    if (m == null) return null;
    return [int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)];
  }

  static int compareSemver(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  String? _findNpm() {
    try {
      final which = Process.runSync(Platform.isWindows ? 'where' : 'which', ['npm']);
      if (which.exitCode != 0) return null;
      final out = (which.stdout as String).trim();
      return out.isEmpty ? null : out.split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  String? _resolveGlobalInstallPath() {
    try {
      final root = Process.runSync('npm', ['root', '-g']);
      if (root.exitCode != 0) return null;
      final base = (root.stdout as String).trim();
      if (base.isEmpty) return null;
      return '$base${Platform.pathSeparator}$_repo';
    } catch (_) {
      return null;
    }
  }

  String? _cleanExistingInstall() {
    final target = _resolveGlobalInstallPath();
    if (target == null) return null;
    try {
      final dir = Directory(target);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// Perform the update. Returns a result describing the outcome; caller is
  /// expected to display [message] and exit non-zero on `success == false`.
  Future<UpdateResult> update() async {
    final tag = await fetchLatestTag(forceRefresh: true);
    if (tag == null) return UpdateResult.fail('Failed to check latest version from GitHub');

    final latest = parseSemver(tag);
    final current = parseSemver(bridgeVersion);
    if (latest == null || current == null) {
      return UpdateResult.fail('Cannot parse version (current: $bridgeVersion, latest: $tag)');
    }
    if (compareSemver(latest, current) <= 0) {
      return UpdateResult.ok('Already up to date (latest: $tag).');
    }

    final assetUrl = '$_dlBase/$tag/agrout-bridge-$tag.tgz';
    final tmpDir = Directory.systemTemp.createTempSync('agrout-install-');
    final tgzPath = '${tmpDir.path}${Platform.pathSeparator}agrout-bridge-$tag.tgz';

    try {
      print('Downloading from $assetUrl...');
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(assetUrl));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          return UpdateResult.fail('Download failed: HTTP ${resp.statusCode}');
        }
        final sink = File(tgzPath).openWrite();
        await resp.pipe(sink);
      } finally {
        client.close(force: true);
      }
      print('Downloaded agrout-bridge-$tag.tgz');

      final cleaned = _cleanExistingInstall();
      if (cleaned != null) print('Removed previous install at $cleaned');

      final npm = _findNpm();
      if (npm == null) {
        return UpdateResult.fail('npm not found in PATH. Is Node.js installed?');
      }

      print('Installing...');
      final result = await Process.run(npm, ['install', '-g', tgzPath]);
      if (result.exitCode != 0) {
        return UpdateResult.fail('npm install failed:\n${result.stderr}');
      }
      // Drop the stale cache so the next startup cannot show an "update
      // available" badge pointing at the tag we just installed.
      clearCache();
      return UpdateResult.ok('Updated to $tag. Restart the bridge to apply.');
    } finally {
      try { tmpDir.deleteSync(recursive: true); } catch (_) {}
    }
  }
}
