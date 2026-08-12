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

/// Self-update: fetch latest GitHub Release tag for `Khip01/agrout-bridge`,
/// compare to `bridgeVersion`, download the tarball asset, remove the
/// existing npm global install, and re-run `npm install -g`.
class Updater {
  static const _owner = 'Khip01';
  static const _repo = 'agrout-bridge';
  // Mutable to allow tests to stub the API endpoint with a local HttpServer.
  // Production callers never override these.
  static String _apiBase = 'https://api.github.com';
  static String _dlBase = 'https://github.com/$_owner/$_repo/releases/download';
  static const _cacheTtlMs = 60 * 60 * 1000; // 1 hour

  /// Test-only override for the API base URL. Production never calls this.
  static void setApiBaseForTest(String base) {
    _apiBase = base;
    _dlBase = '$base';
  }

  /// Test-only reset to the production API base URL.
  static void resetApiBaseForTest() {
    _apiBase = 'https://api.github.com';
    _dlBase = 'https://github.com/$_owner/$_repo/releases/download';
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

  void clearCache() {
    try {
      final f = File('${configDir()}${Platform.pathSeparator}update-cache.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Fetch the latest tag from GitHub. When [forceRefresh] is true, the local
  /// cache is bypassed and refreshed on success. The explicit `update` command
  /// always passes `forceRefresh: true` so a user running `agrout-bridge update`
  /// twice within the cache TTL window always sees the real latest tag.
  Future<String?> fetchLatestTag({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _readCache();
      if (cached != null) return cached;
    }
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse('$_apiBase/repos/$_owner/$_repo/releases/latest'));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'agrout-bridge-cli');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        client.close(force: true);
        return forceRefresh ? null : _readCache();
      }
      final raw = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final tag = data['tag_name'] as String?;
      if (tag != null) _writeCache(tag);
      return tag;
    } catch (_) {
      return forceRefresh ? null : _readCache();
    }
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
      return UpdateResult.ok('Updated to $tag. Restart the bridge to apply.');
    } finally {
      try { tmpDir.deleteSync(recursive: true); } catch (_) {}
    }
  }
}
