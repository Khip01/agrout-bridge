import 'dart:io';

import 'package:playwright_dart/playwright_dart.dart' as pw;

import '../models/profile.dart';
import 'daily_claim.dart';
import 'playwright_bootstrap.dart';

/// Outcome of a browser-assisted daily claim attempt.
class DailyClaimAttempt {
  final bool success;
  final String message;
  final String? sessionCookie;
  final String? newApiUserId;
  final double? quotaBefore;
  final double? quotaAfter;

  const DailyClaimAttempt({
    required this.success,
    required this.message,
    this.sessionCookie,
    this.newApiUserId,
    this.quotaBefore,
    this.quotaAfter,
  });
}

/// Drives the user's own browser binary (via Playwright from `playwright_dart`)
/// through the AgentRouter GitHub-OAuth claim flow.
///
/// Design decisions:
/// - We use a DEDICATED automation profile under the bridge config dir, never
///   the user's daily profile. Chromium refuses to automate a profile that is
///   in use by the running browser (and Chrome documents that automating the
///   default profile is unsupported), so the dedicated profile avoids the
///   single-instance lock and the policy wall.
/// - We point Playwright at the user's already-installed browser binary via
///   `executablePath`, so no large Playwright browser bundle is downloaded.
/// - GitHub login is required only ONCE per profile lifetime (session is then
///   remembered for ~30 days); subsequent claims reuse the session and just
///   complete the OAuth authorize step.
class DailyClaimBrowser {
  final DailyClaimConfig _config;

  DailyClaimBrowser(this._config);

  String get profileDir {
    final base = _config.profileDir ??
        '${configDirOverride ?? _defaultConfigDir()}${Platform.pathSeparator}browser';
    return base;
  }

  /// Run the claim flow. [surface] true shows the browser window so the user
  /// can watch (and complete any 2FA / GitHub login); false runs headless.
  /// [executablePath] points at the detected browser binary.
  Future<DailyClaimAttempt> claim({
    required String executablePath,
    required bool surface,
    void Function(String status)? onProgress,
  }) async {
    Directory(profileDir).createSync(recursive: true);
    await PlaywrightBootstrap.ensure(
        onProgress: onProgress ??
            (msg) => stdout.writeln('  [daily] $msg'));
    final pw.Playwright playwright = await pw.PlaywrightDart.create();
    try {
      final pw.BrowserType type = playwright.chromium;
      final ctx = await type.launchPersistentContext(
        profileDir,
        launchOptions: pw.LaunchOptions(
          executablePath: executablePath,
          headless: !surface,
        ),
        contextOptions: pw.ContextOptions(),
      );
      try {
        final page = ctx.pages.isNotEmpty ? ctx.pages.first : await ctx.newPage();
        await page.goto('https://agentrouter.org/login');
        onProgress?.call('Login page loaded, starting GitHub sign-in...');

        // Click "Continue with GitHub" (text on the login page). The page
        // fetches its own OAuth state and redirects to GitHub; clicking the
        // real button keeps the request signed exactly like the browser UI.
        await page
            .getByText(
                RegExp(r'GitHub.*继续|Continue.*GitHub|Sign in with GitHub'))
            .click(timeout: 60000);

        onProgress?.call('Opening GitHub login for the first time...');
        // First run: the bridge profile has no GitHub session, so GitHub
        // shows its login page. In surface mode the user signs in there once.
        onProgress?.call('Sign in to GitHub in the opened window if asked. '
            'This only happens once.');
        try {
          await page.waitForURL(
              pw.RouteMatcher.regex(RegExp(r'agentrouter\.org')),
              timeout: 180000);
        } catch (_) {
          // Either the browser was closed by the user or GitHub login was not
          // finished before the timeout. No session was captured.
          return const DailyClaimAttempt(
            success: false,
            message: 'GitHub sign-in was not finished. On the first run you '
                'must log in to GitHub in the opened window (including 2FA '
                'if enabled), then let it return to AgentRouter.',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 3));
        // Best-effort: pull the session cookie.
        String? session;
        String? uid;
        try {
          final cookieList = await ctx.cookies(urls: ['https://agentrouter.org']);
          for (final c in cookieList) {
            if (c.name == 'session') session = c.value;
          }
        } catch (_) {}
        try {
          final userRaw =
              (await page.evaluate("() => localStorage.getItem('user')"))
                  ?.toString();
          if (userRaw != null) {
            final parsed =
                RegExp(r'"id"\s*:\s*(\d+)').firstMatch(userRaw);
            if (parsed != null) uid = parsed.group(1);
          }
        } catch (_) {}
        final ok = session != null;
        return DailyClaimAttempt(
          success: ok,
          message: ok ? 'claim completed, session captured' : 'no session cookie found',
          sessionCookie: session,
          newApiUserId: uid,
        );
      } finally {
        await ctx.close();
      }
    } finally {
      await playwright.stop();
    }
  }

  static String _defaultConfigDir() {
    final home = Platform.environment['HOME'] ?? '/root';
    return '$home${Platform.pathSeparator}.config${Platform.pathSeparator}agrout-bridge';
  }
}