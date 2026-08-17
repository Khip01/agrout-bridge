import 'dart:io';

import 'api_client.dart';

/// Which provider the user signed up to AgentRouter with. The daily-claim
/// dialog asks this first, then shows the matching OAuth authorize URL.
enum DailyProvider { github, linuxdo }

/// Builds the AgentRouter OAuth login URL for a provider, and opens it in the
/// user's default browser.
///
/// AgentRouter's login page calls `GET /api/oauth/state?mode=login` (public)
/// to obtain a fresh `state`, reads the OAuth client ids from `GET /api/status`
/// (also public), and then redirects to the provider's authorize endpoint.
/// The bridge rebuilds that exact URL so the same flow runs without a browser
/// session of its own: opening the URL in the user's already-logged-in
/// provider browser completes the sign-in (and the daily claim) in one click.
class DailyClaim {
  final AgentRouterClient client;

  DailyClaim(this.client);

  /// Fallback when the live state/client-id fetch fails: the plain login page
  /// still offers both providers, so the user can claim manually.
  static const fallbackUrl = 'https://agentrouter.org/login';

  /// GitHub authorize URL, mirroring the frontend's `v7()` builder.
  static String githubUrl(String clientId, String state) =>
      'https://github.com/login/oauth/authorize?client_id=$clientId&state=$state&scope=user:email';

  /// LinuxDO authorize URL, mirroring the frontend's `w7()` builder.
  static String linuxdoUrl(String clientId, String state) =>
      'https://connect.linux.do/oauth2/authorize?'
      'response_type=code&client_id=$clientId&state=$state';

  /// Build the authorize URL for [provider]. Never throws: any network or
  /// shape error falls back to [fallbackUrl].
  Future<String> buildUrl(DailyProvider provider) async {
    try {
      final state = await client.fetchOauthState();
      final status = await client.fetchStatus();
      final data = status['data'];
      final cfg = data is Map ? Map<String, dynamic>.from(data) : const <String, dynamic>{};
      switch (provider) {
        case DailyProvider.github:
          final id = cfg['github_client_id']?.toString() ?? '';
          if (id.isEmpty) return fallbackUrl;
          return githubUrl(id, state);
        case DailyProvider.linuxdo:
          final id = cfg['linuxdo_client_id']?.toString() ?? '';
          if (id.isEmpty) return fallbackUrl;
          return linuxdoUrl(id, state);
      }
    } catch (_) {
      return fallbackUrl;
    }
  }
}

/// Open [url] in the platform's default browser. Returns true when the open
/// command launched successfully (fire-and-forget; the browser owns the tab).
Future<bool> openInBrowser(String url) async {
  try {
    final List<String> cmd;
    if (Platform.isLinux) {
      cmd = ['xdg-open', url];
    } else if (Platform.isMacOS) {
      cmd = ['open', url];
    } else if (Platform.isWindows) {
      cmd = ['cmd', '/c', 'start', '', url];
    } else {
      return false;
    }
    final p = await Process.start(cmd.first, cmd.sublist(1));
    return await p.exitCode == 0;
  } catch (_) {
    return false;
  }
}
