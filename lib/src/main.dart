import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide LogEntry, Clipboard;

import 'models/profile.dart';
import 'models/version.dart';
import 'services/api_client.dart';
import 'services/login.dart';
import 'services/log_store.dart';
import 'services/updater.dart';
import 'server/server_controller.dart';
import 'tui/app.dart';

const _usage = '''agrout-bridge  v$bridgeVersion

Usage:
  agrout-bridge run                        Start the bridge in TUI mode
  agrout-bridge run --server               Start the bridge in headless server mode
  agrout-bridge profile add <name> [key]   Add an AgentRouter API key profile
  agrout-bridge profile list               List configured profiles
  agrout-bridge profile use <name>         Set the active profile
  agrout-bridge profile remove <name>      Delete a profile
  agrout-bridge profile login              Open local sign-in link to capture session token
  agrout-bridge profile logout             Clear the stored session token
  agrout-bridge profile whoami             Show account info for the active profile
  agrout-bridge update                     Download and install latest stable release
  agrout-bridge help                       Show this help screen
  agrout-bridge -v, --version              Print version string
''';

void _printUsage() => stdout.write(_usage);
void _printUsageErr() => stderr.write(_usage);

Future<void> main(List<String> args) async {
  final noArgs = args.isEmpty;
  final showHelp = noArgs || args.contains('help') || args.contains('--help') || args.contains('-h');

  if (args.contains('--version') || args.contains('-v')) {
    stdout.writeln('agrout-bridge v$bridgeVersion');
    return;
  }

  if (showHelp) {
    _printUsage();
    return;
  }

  final cmd = args.first;
  final rest = args.length > 1 ? args.sublist(1) : <String>[];

  try {
    switch (cmd) {
      case 'run':
        await _runCommand(rest);
        return;
      case 'profile':
        await _profileCommand(rest);
        return;
      case 'update':
        await _updateCommand();
        return;
      default:
        _printUsageErr();
        exit(1);
    }
  } catch (e, st) {
    stderr.writeln('Error: $e');
    stderr.writeln(st);
    exit(1);
  }
}

void _loadStores(ProfileStore profiles, ConfigStore config) {
  config.load();
  profiles.load();
  if (config.config.activeProfileId == null && profiles.all.isNotEmpty) {
    config.config.activeProfileId = profiles.all.first.id;
    config.save();
  }
}

Future<void> _runCommand(List<String> args) async {
  final profiles = ProfileStore();
  final config = ConfigStore();
  _loadStores(profiles, config);

  final isServer = args.contains('--server');
  final controller = ServerController(profiles: profiles, configStore: config);
  final boundPort = await controller.start();
  await controller.refreshModels();

  if (isServer) {
    stdout.writeln('agrout-bridge running headless on http://${config.config.listenAddress}:$boundPort');
    stdout.writeln('Press Ctrl+C to stop.');
    final completer = Completer<void>();
    ProcessSignal.sigint.watch().listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    ProcessSignal.sigterm.watch().listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    await controller.stop();
    // Headless must exit explicitly: the active ProcessSignal.watch()
    // subscriptions keep the event loop alive after the server closes, and
    // leaving the process running would orphan it (holding no port but never
    // terminating). TUI mode intentionally skips exit() to let nocterm
    // restore the terminal first; headless has no such constraint.
    exit(0);
  }

  // TUI mode.
  final app = AgroutApp(
    profileStore: profiles,
    configStore: config,
    proxyServer: controller,
  );
  await runApp(app);
  // Mirrors commandcode-bridge: do not `exit(0)` here. The TUI calls
  // `shutdownApp(0)` which asks nocterm to restore the terminal and end
  // the process naturally. Calling `exit()` from outside the TUI would
  // race with the alternate-screen restore and re-introduce the
  // mouse-tracking leak.
  await controller.stop();
}

Future<void> _profileCommand(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('profile: missing subcommand (add | list | use | remove | login | logout | whoami)');
    exit(1);
  }
  final profiles = ProfileStore();
  final config = ConfigStore();
  _loadStores(profiles, config);

  final sub = args.first;
  final rest = args.length > 1 ? args.sublist(1) : <String>[];
  switch (sub) {
    case 'add':
      await _profileAdd(profiles, config, rest);
      return;
    case 'list':
      _profileList(profiles, config);
      return;
    case 'use':
      await _profileUse(profiles, config, rest);
      return;
    case 'remove':
      await _profileRemove(profiles, config, rest);
      return;
    case 'login':
      await _profileLogin(profiles, config);
      return;
    case 'logout':
      await _profileLogout(profiles);
      return;
    case 'whoami':
      await _profileWhoami(profiles);
      return;
    default:
      stderr.writeln('profile: unknown subcommand "$sub"');
      exit(1);
  }
}

String? _prompt(String label, {bool hidden = false}) {
  stdout.write('$label: ');
  if (hidden) {
    // dart:io stdin does not expose raw mode without external packages.
    // Best-effort: turn echo off for this TTY using stty if available.
    try {
      Process.runSync('stty', ['-echo']);
    } catch (_) {}
    final line = stdin.readLineSync();
    try {
      Process.runSync('stty', ['echo']);
    } catch (_) {}
    stdout.writeln();
    return line?.trim();
  }
  return stdin.readLineSync()?.trim();
}

Future<void> _profileAdd(ProfileStore profiles, ConfigStore config, List<String> rest) async {
  if (rest.isEmpty) {
    stderr.writeln('usage: profile add <name> [api-key]');
    exit(1);
  }
  final name = rest[0];
  var key = rest.length > 1 ? rest[1] : null;
  key ??= _prompt('AgentRouter API key', hidden: true);
  if (key == null || key.isEmpty) {
    stderr.writeln('profile add: empty key, aborting');
    exit(1);
  }
  if (!key.startsWith('sk-')) {
    stderr.writeln('warning: key does not start with "sk-"; proceeding anyway');
  }
  final p = profiles.add(name: name, apiKey: key);
  if (config.config.activeProfileId == null) {
    config.config.activeProfileId = p.id;
    config.save();
  }
  stdout.writeln('Added profile "${p.name}" (id ${p.id}).');
}

void _profileList(ProfileStore profiles, ConfigStore config) {
  if (profiles.all.isEmpty) {
    stdout.writeln('No profiles. Add one with `agrout-bridge profile add <name>`.');
    return;
  }
  for (final p in profiles.all) {
    final active = p.id == config.config.activeProfileId ? '*' : ' ';
    final auth = p.isLoggedIn ? 'logged-in' : 'key-only';
    stdout.writeln('$active ${p.name.padRight(20)} ${auth.padRight(11)} created=${p.createdAt.toIso8601String().substring(0, 10)}');
  }
}

Future<void> _profileUse(ProfileStore profiles, ConfigStore config, List<String> rest) async {
  if (rest.isEmpty) {
    stderr.writeln('usage: profile use <name>');
    exit(1);
  }
  final p = profiles.byName(rest[0]);
  if (p == null) {
    stderr.writeln('profile use: no profile named "${rest[0]}"');
    exit(1);
  }
  config.config.activeProfileId = p.id;
  config.save();
  stdout.writeln('Active profile: ${p.name}');
}

Future<void> _profileRemove(ProfileStore profiles, ConfigStore config, List<String> rest) async {
  if (rest.isEmpty) {
    stderr.writeln('usage: profile remove <name>');
    exit(1);
  }
  final p = profiles.byName(rest[0]);
  if (p == null) {
    stderr.writeln('profile remove: no profile named "${rest[0]}"');
    exit(1);
  }
  profiles.remove(p.id);
  if (config.config.activeProfileId == p.id) {
    config.config.activeProfileId = profiles.all.isEmpty ? null : profiles.all.first.id;
    config.save();
  }
  stdout.writeln('Removed profile "${p.name}".');
}

Future<void> _profileLogin(ProfileStore profiles, ConfigStore config) async {
  final activeId = config.config.activeProfileId;
  if (activeId == null) {
    stderr.writeln('profile login: no active profile. Run `profile use <name>` first.');
    exit(1);
  }
  final profile = profiles.byId(activeId);
  if (profile == null) {
    stderr.writeln('profile login: active profile not found');
    exit(1);
  }
  final client = AgentRouterClient();
  final flow = LoginFlow(client);
  final url = await flow.start(onResult: (outcome) async {
    if (outcome.success) {
      applyLoginOutcome(profile, outcome, profiles);
      stdout.writeln('Login successful${outcome.username != null ? ' as ${outcome.username}' : ''}.');
    } else {
      stderr.writeln('Login failed: ${outcome.message ?? 'unknown error'}');
    }
  });
  stdout.writeln('Open this sign-in URL in a new browser tab to authenticate:');
  stdout.writeln('  $url');
  stdout.writeln('The server will auto-close after 10 minutes.');
  // Wait for SIGINT so the user can press Ctrl+C to release the URL.
  final completer = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  await completer.future;
  await flow.stop();
  client.close();
}

Future<void> _profileLogout(ProfileStore profiles) async {
  var touched = 0;
  for (final p in profiles.all) {
    if (p.isLoggedIn) {
      profiles.upsert(p.copyWith(clearAuthToken: true));
      touched++;
    }
  }
  stdout.writeln('Cleared session token from $touched profile(s).');
}

Future<void> _profileWhoami(ProfileStore profiles) async {
  for (final p in profiles.all) {
    if (p.isLoggedIn && p.accountInfo != null) {
      stdout.writeln('Profile: ${p.name}');
      stdout.writeln('  username:   ${p.accountInfo!['username'] ?? '-'}');
      stdout.writeln('  email:      ${p.accountInfo!['email'] ?? '-'}');
      stdout.writeln('  group:      ${p.accountInfo!['group'] ?? '-'}');
      stdout.writeln('  quota:      ${p.accountInfo!['quota'] ?? '-'}');
      stdout.writeln('  used_quota: ${p.accountInfo!['used_quota'] ?? '-'}');
      return;
    }
  }
  stderr.writeln('profile whoami: no logged-in profile. Run `profile login`.');
  exit(1);
}

Future<void> _updateCommand() async {
  LogStore.init();
  stdout.writeln('agrout-bridge v$bridgeVersion');
  stdout.writeln('Checking for stable update...');
  final updater = Updater();
  try {
    final result = await updater.update();
    if (result.success) {
      stdout.writeln(result.message);
      if (result.message != null && result.message!.startsWith('Updated')) {
        stdout.writeln('Restart the bridge to apply.');
      }
    } else {
      stderr.writeln('Update failed: ${result.message}');
      exit(1);
    }
  } finally {
    LogStore.debug('update check complete');
  }
}
