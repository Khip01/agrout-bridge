// Tests that the bridge auto-increments its listen port when the
// default (8318) is already bound by another process, and that it stays
// on the default port when it is free.
import 'dart:io';

import 'package:agrout_bridge/src/models/profile.dart';
import 'package:agrout_bridge/src/server/server_controller.dart';
import 'package:test/test.dart';

void main() {
  late ProfileStore profiles;
  late ConfigStore configStore;
  late String tmpHome;

  setUp(() {
    tmpHome = Directory.systemTemp.createTempSync('agrout_test').path;
    configDirOverride = tmpHome;
    profiles = ProfileStore()..load();
    configStore = ConfigStore()..load();
  });

  tearDown(() {
    configDirOverride = null;
  });

  test('auto-increments to next free port when default is taken', () async {
    // Occupy the configured port with a raw socket so the HttpServer bind
    // sees it as "Address already in use" (not Dart's "shared flag" error,
    // which only appears when two non-shared HttpServer.binds race the same
    // address/port pair).
    final blocker = await ServerSocket.bind(InternetAddress('127.0.0.1'), 8318);
    configStore.config.serverPort = 8318;
    configStore.save();

    final controller = ServerController(profiles: profiles, configStore: configStore);
    final bound = await controller.start();

    expect(bound, greaterThan(8318));
    expect(bound, 8319, reason: 'should pick 8319 since 8318 is occupied');
    // status() reflects the actual bound port (driven by persisted config).
    expect(controller.status().port, bound);

    // The persisted config was updated so /info + TUI report reality.
    expect(configStore.config.serverPort, bound);

    await controller.stop();
    blocker.close();
  });

  test('uses default port when it is free', () async {
    configStore.config.serverPort = 8318;
    configStore.save();

    final controller = ServerController(profiles: profiles, configStore: configStore);
    final bound = await controller.start();

    expect(bound, 8318);
    expect(controller.status().port, 8318);
    await controller.stop();
  });
}
