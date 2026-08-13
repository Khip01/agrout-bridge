// Tests that the bridge auto-increments its listen port when the
// configured port is already bound by another process, and stays put
// when the port is free. Uses high pseudo-random ports to avoid clashing
// with anything on the default 8318 or leftover binds from prior runs.
import 'dart:io';
import 'dart:math';

import 'package:agrout_bridge/src/models/profile.dart';
import 'package:agrout_bridge/src/server/server_controller.dart';
import 'package:test/test.dart';

void main() {
  late ProfileStore profiles;
  late ConfigStore configStore;
  late String tmpHome;
  final rng = Random.secure();

  // Pick a high port unlikely to be in use; we override it per-test anyway.
  int _freshPort() => 18000 + rng.nextInt(10000);

  setUp(() {
    tmpHome = Directory.systemTemp.createTempSync('agrout_test').path;
    configDirOverride = tmpHome;
    profiles = ProfileStore()..load();
    configStore = ConfigStore()..load();
  });

  tearDown(() {
    configDirOverride = null;
    try {
      Directory(tmpHome).deleteSync(recursive: true);
    } catch (_) {}
  });

  test('auto-increments to next free port when default is taken', () async {
    final base = _freshPort();
    // Occupy `base` with a raw socket so the HttpServer bind sees it as
    // in-use (not Dart's "shared flag" error).
    final blocker = await ServerSocket.bind(
      InternetAddress('127.0.0.1'),
      base,
    );
    configStore.config.serverPort = base;
    configStore.save();

    final controller = ServerController(
      profiles: profiles,
      configStore: configStore,
    );
    final bound = await controller.start();

    expect(bound, base + 1, reason: 'should pick base+1 since base is occupied');
    expect(controller.status().port, bound);
    expect(configStore.config.serverPort, bound, reason: 'config persisted');

    await controller.stop();
    blocker.close();
  });

  test('uses configured port when it is free', () async {
    final base = _freshPort();
    configStore.config.serverPort = base;
    configStore.save();

    final controller = ServerController(
      profiles: profiles,
      configStore: configStore,
    );
    final bound = await controller.start();

    expect(bound, base);
    expect(controller.status().port, base);
    await controller.stop();
  });
}
