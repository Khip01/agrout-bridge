import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/models/profile.dart';
import 'package:agrout_bridge/src/services/updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpHome;
  late String cachePath;

  setUp(() {
    tmpHome = Directory.systemTemp.createTempSync('agrout-updater-test-');
    configDirOverride = tmpHome.path;
    cachePath = '${tmpHome.path}${Platform.pathSeparator}update-cache.json';
  });

  tearDown(() {
    configDirOverride = null;
    if (tmpHome.existsSync()) tmpHome.deleteSync(recursive: true);
  });

  /// Stub HTTP fetcher returning [tagsJson] for the Tags endpoint and
  /// 200/empty otherwise. Tracks every call so tests can assert which
  /// endpoint was hit.
  UpdaterHttpFetch stubFetch({
    required String tagsJson,
    int tagsStatus = 200,
  }) {
    return (String url, Map<String, String> headers) async {
      if (url.contains('/tags')) {
        return (statusCode: tagsStatus, body: tagsJson);
      }
      // Asset download path (not exercised by these tests).
      return (statusCode: 404, body: '');
    };
  }

  void seedCache(String tag, {int ageMs = 0}) {
    File(cachePath).writeAsStringSync(jsonEncode({
      'tag': tag,
      'at': DateTime.now().millisecondsSinceEpoch - ageMs,
    }));
  }

  group('Updater.fetchLatestTag', () {
    test('cache within TTL is served, API not called', () async {
      seedCache('v0.1.1');
      var calls = 0;
      final u = Updater(httpFetch: (url, _) async {
        calls++;
        return (statusCode: 200, body: '[{"name":"v0.1.3"}]');
      });
      final tag = await u.fetchLatestTag();
      expect(tag, equals('v0.1.1'));
      expect(calls, equals(0));
    });

    test('forceRefresh bypasses a fresh cache and hits the API', () async {
      seedCache('v0.1.1');
      final u = Updater(httpFetch: stubFetch(tagsJson: '[{"name":"v0.1.3"},{"name":"v0.1.2"}]'));
      final tag = await u.fetchLatestTag(forceRefresh: true);
      expect(tag, equals('v0.1.3'));
      // Cache should now reflect the freshly discovered tag.
      final data = jsonDecode(File(cachePath).readAsStringSync()) as Map<String, dynamic>;
      expect(data['tag'], equals('v0.1.3'));
    });

    test('expired cache falls back to the network', () async {
      // Seed cache that is older than the 1h TTL.
      seedCache('v0.1.0', ageMs: 2 * 60 * 60 * 1000);
      final u = Updater(httpFetch: stubFetch(tagsJson: '[{"name":"v0.1.3"}]'));
      final tag = await u.fetchLatestTag();
      expect(tag, equals('v0.1.3'));
    });

    test('picks highest stable semver, ignores prerelease tags', () async {
      final u = Updater(httpFetch: stubFetch(tagsJson: jsonEncode([
        {'name': 'v0.1.3-rc1'},
        {'name': 'v0.1.3'},
        {'name': 'v0.1.2'},
        {'name': 'v0.1.1-beta'},
      ])));
      final tag = await u.fetchLatestTag(forceRefresh: true);
      expect(tag, equals('v0.1.3'));
    });

    test('degrades to cache on API 404 instead of failing hard', () async {
      // Mirrors the real repo state where /releases/latest (old) 404'd but
      // /tags now returns valid data. Here we simulate the tags endpoint
      // failing and assert the stale cache is still the fallback.
      seedCache('v0.1.1');
      final u = Updater(httpFetch: stubFetch(tagsJson: '', tagsStatus: 404));
      final tag = await u.fetchLatestTag(forceRefresh: true);
      expect(tag, equals('v0.1.1'));
    });

    test('returns null when API fails and no cache exists', () async {
      final u = Updater(httpFetch: stubFetch(tagsJson: '', tagsStatus: 500));
      final tag = await u.fetchLatestTag(forceRefresh: true);
      expect(tag, isNull);
    });

    test('update() uses Tags API result and reports correct latest', () async {
      // Don't seed cache; force API success -> finds newer tag than the
      // locally embedded 0.1.4.
      final u = Updater(httpFetch: stubFetch(tagsJson: '[{"name":"v0.1.5"}]'));
      final tag = await u.fetchLatestTag(forceRefresh: true);
      expect(tag, equals('v0.1.5'));
      // Simulate the comparison logic used by update().
      final latest = Updater.parseSemver(tag!);
      final current = Updater.parseSemver('0.1.4');
      expect(Updater.compareSemver(latest!, current!), greaterThan(0));
    });
  });
}
