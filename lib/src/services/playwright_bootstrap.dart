import 'dart:io';

import 'package:playwright_dart/playwright_dart.dart' as pw;

/// Lazily prepares the Playwright runtime only when the user actually asks
/// for browser automation (first `Shift+D`), never at bridge startup.
///
/// Sequence (matches the verified spike):
/// 1. `PlaywrightDart.create()` downloads + assembles the driver, which
///    bundles its own Node binary (~50-80 MB, one-time).
/// 2. We then write the `.browsers-installed` marker into the driver dir so
///    playwright_dart's internal `ensureBrowsersInstalled()` short-circuits
///    and never downloads the bundled Chromium/Firefox/WebKit (the browser we
///    drive is the user's own install, reused via `executablePath`).
class PlaywrightBootstrap {
  /// Short human string describing what is downloaded on first use, for the
  /// install-confirmation dialog.
  static String describeDownload() {
    return 'Playwright driver + bundled Node (~50-80 MB, once). '
        'Your installed browser binary is reused; no browser bundle download.';
  }

  /// Weaved driver dir name (version may differ per playwright_dart release).
  static String? _latestDriverDir() {
    final home = Platform.environment['HOME'] ?? '/root';
    final base =
        '$home${Platform.pathSeparator}.playwright-dart${Platform.pathSeparator}driver';
    final dir = Directory(base);
    if (!dir.existsSync()) return null;
    final dirs = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return dirs.isEmpty ? null : dirs.first.path;
  }

  /// Ensure the runtime is ready. Downloads the driver on first call (blocking
  /// while it assembles, typically tens of seconds to a few minutes), then
  /// marks browsers as installed so playwright_dart never fetches browser
  /// bundles. Safe to call repeatedly; idempotent.
  static Future<void> ensure({void Function(String status)? onProgress}) async {
    // 1. If a driver dir already exists (previous run), just seed markers.
    final existing = _latestDriverDir();
    if (existing != null) {
      _mark(existing);
      return;
    }

    onProgress?.call('Assembling Playwright driver (first run, one-time)...');
    final pw.Playwright playwright = await pw.PlaywrightDart.create();
    await playwright.stop();

    final fresh = _latestDriverDir();
    if (fresh != null) _mark(fresh);
  }

  /// Write the `.browsers-installed` marker so playwright_dart skips its own
  /// browser downloads. Must run AFTER the driver dir exists (which the
  /// downloader creates on first `PlaywrightDart.create()`).
  static void _mark(String driverDir) {
    final marker = File('${driverDir}${Platform.pathSeparator}.browsers-installed');
    if (!marker.existsSync()) marker.writeAsStringSync('done');
  }
}