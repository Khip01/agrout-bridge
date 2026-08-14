import 'dart:io';

import 'package:test/test.dart';

import 'package:agrout_bridge/src/models/profile.dart';

String _newTempDir() {
  final root = Directory.systemTemp.createTempSync('agrout-test-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root.path;
}

void _useTempDir(String path) {
  configDirOverride = path;
  addTearDown(() => configDirOverride = null);
}

void main() {
  group('AppConfig', () {
    test('default values when no config.json exists', () {
      _useTempDir(_newTempDir());

      final cfg = AppConfig();
      expect(cfg.serverPort, 8318);
      expect(cfg.listenAddress, '127.0.0.1');
      expect(cfg.activeProfileId, isNull);
      expect(cfg.proxyAuthToken, '');
      expect(cfg.trimSystemPrompt, isFalse);
    });

    test('roundtrip via toJson / fromJson', () {
      final cfg = AppConfig(serverPort: 9100, listenAddress: '0.0.0.0', activeProfileId: 'a', proxyAuthToken: 'secret', trimSystemPrompt: true);
      final restored = AppConfig.fromJson(cfg.toJson());
      expect(restored.serverPort, 9100);
      expect(restored.listenAddress, '0.0.0.0');
      expect(restored.activeProfileId, 'a');
      expect(restored.proxyAuthToken, 'secret');
      expect(restored.trimSystemPrompt, isTrue);
    });

    test('ConfigStore.save + load roundtrip persists to 0600 on unix', () {
      _useTempDir(_newTempDir());

      final store = ConfigStore()..load();
      store.config.serverPort = 8421;
      store.config.proxyAuthToken = 'tok';
      store.save();

      final reloaded = ConfigStore()..load();
      expect(reloaded.config.serverPort, 8421);
      expect(reloaded.config.proxyAuthToken, 'tok');

      if (!Platform.isWindows) {
        final mode = File('${configDir()}${Platform.pathSeparator}config.json').statSync().mode;
        // 0o777 = 511, 0o600 = 384 (decimal)
        expect(mode & 511, 384, reason: 'config.json must be owner-only');
      }
    });
  });

  group('Profile', () {
    test('json roundtrip preserves all fields', () {
      final p = Profile(
        id: 'p1',
        name: 'work',
        apiKey: 'sk-test',
        authToken: 'sess',
        authTokenAt: DateTime.utc(2026, 8, 1),
        createdAt: DateTime.utc(2026, 1, 1),
        wafCookies: {'acw_tc': 'abc'},
        modelCache: ['claude-opus-4-8'],
        accountInfo: {'username': 'me'},
      );
      final r = Profile.fromJson(p.toJson());
      expect(r.id, 'p1');
      expect(r.name, 'work');
      expect(r.apiKey, 'sk-test');
      expect(r.authToken, 'sess');
      expect(r.authTokenAt, DateTime.utc(2026, 8, 1));
      expect(r.createdAt, DateTime.utc(2026, 1, 1));
      expect(r.wafCookies['acw_tc'], 'abc');
      expect(r.modelCache, ['claude-opus-4-8']);
      expect(r.accountInfo!['username'], 'me');
    });

    test('copyWith(clearAuthToken: true) drops the session token', () {
      final p = Profile(
        id: 'p1',
        name: 'n',
        apiKey: 'k',
        authToken: 'tok',
        authTokenAt: DateTime.now(),
        createdAt: DateTime.now(),
      );
      final cleared = p.copyWith(clearAuthToken: true);
      expect(cleared.authToken, isNull);
      expect(cleared.authTokenAt, isNull);
    });
  });

  group('ProfileStore', () {
    test('add + byName + byId + remove', () {
      _useTempDir(_newTempDir());

      final store = ProfileStore()..load();
      final p = store.add(name: 'work', apiKey: 'sk-a');
      expect(store.byName('work')!.id, p.id);
      expect(store.byId(p.id)!.apiKey, 'sk-a');
      expect(store.all.length, 1);

      expect(() => store.add(name: 'work', apiKey: 'sk-b'), throwsStateError);
      expect(store.remove(p.id), isTrue);
      expect(store.all, isEmpty);
    });

    test('persists across reload with 0600 permissions on unix', () {
      _useTempDir(_newTempDir());

      final store = ProfileStore()..load();
      store.add(name: 'home', apiKey: 'sk-home');

      final reloaded = ProfileStore()..load();
      expect(reloaded.byName('home'), isNotNull);
      expect(reloaded.byName('home')!.apiKey, 'sk-home');

      if (!Platform.isWindows) {
        final mode = File('${configDir()}${Platform.pathSeparator}profiles.json').statSync().mode;
        expect(mode & 511, 384, reason: 'profiles.json must be owner-only');
      }
    });

    test('upsert with mutated wafCookies writes through', () {
      _useTempDir(_newTempDir());

      final store = ProfileStore()..load();
      final p = store.add(name: 'a', apiKey: 'sk-a');
      store.upsert(p.copyWith(wafCookies: {'acw_tc': 'cookie1'}));

      final reloaded = ProfileStore()..load();
      expect(reloaded.byId(p.id)!.wafCookies['acw_tc'], 'cookie1');
    });
  });
}
