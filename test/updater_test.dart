import 'dart:convert';
import 'dart:io';

import 'package:agrout_bridge/src/models/profile.dart';
import 'package:agrout_bridge/src/services/updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpHome;
  late HttpServer apiServer;
  late int apiHits;
  late String latestTagToReturn;

  setUp(() async {
    apiHits = 0;
    latestTagToReturn = 'v9.9.9';

    tmpHome = Directory.systemTemp.createTempSync('agrout-updater-test-');
    configDirOverride = tmpHome.path;

    apiServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Updater.setApiBaseForTest('http://127.0.0.1:${apiServer.port}');
    apiServer.listen((req) async {
      apiHits++;
      final resp = req.response;
      if (req.uri.path.endsWith('/releases/latest')) {
        resp.headers.set('Content-Type', 'application/json');
        resp.write(jsonEncode({'tag_name': latestTagToReturn}));
      } else {
        resp.statusCode = 404;
      }
      await resp.close();
    });
  });

  tearDown(() async {
    await apiServer.close(force: true);
    configDirOverride = null;
    Updater.resetApiBaseForTest();
    if (tmpHome.existsSync()) tmpHome.deleteSync(recursive: true);
  });

  test('explicit update always hits the API and refreshes the cache', () async {
    // Seed the cache with an older tag, simulating a previous successful
    // `update` run from within the 1-hour TTL window.
    final updater = Updater();
    File('${tmpHome.path}${Platform.pathSeparator}update-cache.json')
        .writeAsStringSync(jsonEncode({
      'tag': 'v0.1.1',
      'at': DateTime.now().millisecondsSinceEpoch,
    }));

    latestTagToReturn = 'v0.1.2';
    final tag = await updater.fetchLatestTag(forceRefresh: true);

    expect(tag, equals('v0.1.2'),
        reason: 'forceRefresh must bypass the local cache');
    expect(apiHits, equals(1),
        reason: 'the GitHub API must be hit even with a fresh cache');

    final cached = File('${tmpHome.path}${Platform.pathSeparator}update-cache.json');
    expect(cached.existsSync(), isTrue);
    final data = jsonDecode(cached.readAsStringSync()) as Map<String, dynamic>;
    expect(data['tag'], equals('v0.1.2'),
        reason: 'cache must be refreshed with the real latest tag');
  });

  test('non-forced read serves from cache when fresh', () async {
    final updater = Updater();
    File('${tmpHome.path}${Platform.pathSeparator}update-cache.json')
        .writeAsStringSync(jsonEncode({
      'tag': 'v0.1.2',
      'at': DateTime.now().millisecondsSinceEpoch,
    }));

    final tag = await updater.fetchLatestTag();

    expect(tag, equals('v0.1.2'));
    expect(apiHits, equals(0),
        reason: 'within TTL the local cache should be served');
  });

  test('expired cache falls back to the network', () async {
    final updater = Updater();
    File('${tmpHome.path}${Platform.pathSeparator}update-cache.json')
        .writeAsStringSync(jsonEncode({
      'tag': 'v0.1.0',
      'at': DateTime.now().millisecondsSinceEpoch - (2 * 60 * 60 * 1000),
    }));

    latestTagToReturn = 'v0.1.2';
    final tag = await updater.fetchLatestTag();

    expect(tag, equals('v0.1.2'));
    expect(apiHits, equals(1));
  });
}
