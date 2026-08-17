import 'dart:io';

/// Daily-claim feature configuration, stored centrally in `config.json` so
/// every parameter lives in one place instead of being hardcoded across the
/// codebase.
///
/// AgentRouter awards a quota bonus the first time the account signs in each
/// UTC day (login is the check-in). The bridge cannot observe that directly
/// without a session cookie, so it detects the claim from the account's own
/// activity log (`/api/log/self`, entry `type=4` "签到成功") and, as a
/// fallback, from a positive quota movement on the billing subscription.
class DailyClaimConfig {
  /// Whether the daily-claim feature is enabled at all.
  bool enabled;

  /// The expected daily reward amount in USD, used as the center of the
  /// detection window (e.g. 25.0 for a "$25/day" site).
  double expectedAmount;

  /// Width of the detection window around [expectedAmount]. An observed
  /// increase inside `[expectedAmount - tolerance, expectedAmount + tolerance]`
  /// counts as a daily claim; anything outside does not, so a stray $1 or $50
  /// income is never mistaken for the daily reward.
  double tolerance;

  /// Detection source preference: `log` (authoritative, requires a stored
  /// session cookie) or `quota` (billing subscription delta, cookie-less).
  String mode;

  /// Browser engine used for the automation. When `null`, no browser has been
  /// configured yet and the claim falls back to manual (copy URL + mark done).
  String? browser;

  /// User-data-dir of the browser profile used for the automation (a
  /// dedicated `~/.config/agrout-bridge/browser/` profile, never the user's
  /// daily browser).
  String? profileDir;

  /// Timestamp (YYYY-MM-DD) of the last confirmed claim per API key id.
  /// Keyed by credential id so each key tracks its own daily state.
  final Map<String, String> lastClaimDate;

  DailyClaimConfig({
    this.enabled = true,
    this.expectedAmount = 25.0,
    this.tolerance = 2.0,
    this.mode = 'quota',
    this.browser,
    this.profileDir,
    Map<String, String>? lastClaimDate,
  }) : lastClaimDate = lastClaimDate ?? {};

  bool get isConfigured => browser != null && profileDir != null;

  /// True when the given credential has a confirmed claim recorded for today
  /// (using the local date, matching how AgentRouter resets the bonus).
  bool claimedToday(String credentialId) {
    return lastClaimDate[credentialId] == _today();
  }

  /// Record that [credentialId] claimed today.
  void markClaimed(String credentialId) {
    lastClaimDate[credentialId] = _today();
  }

  /// Reset the claim marker for [credentialId] so the badge reappears.
  void clearClaimed(String credentialId) {
    lastClaimDate.remove(credentialId);
  }

  static String _today() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'expectedAmount': expectedAmount,
        'tolerance': tolerance,
        'mode': mode,
        if (browser != null) 'browser': browser,
        if (profileDir != null) 'profileDir': profileDir,
        'lastClaimDate': lastClaimDate,
      };

  factory DailyClaimConfig.fromJson(Map<String, dynamic> json) {
    final last = (json['lastClaimDate'] as Map?)
            ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
        <String, String>{};
    return DailyClaimConfig(
      enabled: json['enabled'] as bool? ?? true,
      expectedAmount: (json['expectedAmount'] as num?)?.toDouble() ?? 25.0,
      tolerance: (json['tolerance'] as num?)?.toDouble() ?? 2.0,
      mode: json['mode'] as String? ?? 'quota',
      browser: json['browser'] as String?,
      profileDir: json['profileDir'] as String?,
      lastClaimDate: last,
    );
  }
}

/// A browser detected on the host, ready to be offered in the setup dialog.
class DetectedBrowser {
  /// Stable machine id (e.g. `brave`, `chromium`, `zen`, `firefox`).
  final String id;
  final String displayName;

  /// Path to the browser binary, if found. `null` when the data directory
  /// exists but the binary is not on PATH.
  final String? binaryPath;

  /// Base user-data-dir for this browser on this platform, or `null` when the
  /// browser is not installed.
  final String? dataDir;

  const DetectedBrowser({
    required this.id,
    required this.displayName,
    this.binaryPath,
    this.dataDir,
  });

  bool get installed => dataDir != null;
}

/// Registry of browsers with their per-platform data directories.
///
/// The list intentionally covers the popular Chromium-family browsers plus
/// Firefox-based ones (Zen). Firefox/Zen need the WebDriver BiDi path, which
/// `playwright_dart` drives automatically; Chromium-family browsers use CDP
/// under the hood. Detection only reports browsers whose data directory
/// exists on this machine, so the setup dialog never lists every browser on
/// earth.
class BrowserRegistry {
  static const _specs = <Map<String, Object>>[
    {
      'id': 'brave',
      'name': 'Brave',
      'linux': '.config/BraveSoftware/Brave-Browser',
      'mac': 'Library/Application Support/BraveSoftware/Brave-Browser',
      'win': r'AppData\Local\BraveSoftware\Brave-Browser',
    },
    {
      'id': 'chrome',
      'name': 'Google Chrome',
      'linux': '.config/google-chrome',
      'mac': 'Library/Application Support/Google/Chrome',
      'win': r'AppData\Local\Google\Chrome\User Data',
    },
    {
      'id': 'chromium',
      'name': 'Chromium',
      'linux': '.config/chromium',
      'mac': 'Library/Application Support/Chromium',
      'win': r'AppData\Local\Chromium\User Data',
    },
    {
      'id': 'edge',
      'name': 'Microsoft Edge',
      'linux': '.config/microsoft-edge',
      'mac': 'Library/Application Support/Microsoft Edge',
      'win': r'AppData\Local\Microsoft\Edge\User Data',
    },
    {
      'id': 'opera',
      'name': 'Opera',
      'linux': '.config/opera',
      'mac': 'Library/Application Support/com.operasoftware.Opera',
      'win': r'AppData\Local\Opera Software\Opera Stable',
    },
    {
      'id': 'vivaldi',
      'name': 'Vivaldi',
      'linux': '.config/vivaldi',
      'mac': 'Library/Application Support/Vivaldi',
      'win': r'AppData\Local\Vivaldi\User Data',
    },
    {
      'id': 'zen',
      'name': 'Zen (Firefox)',
      'linux': '.zen',
      'mac': 'Library/Application Support/zen',
      'win': r'AppData\Roaming\zen',
    },
    {
      'id': 'firefox',
      'name': 'Firefox',
      'linux': '.mozilla/firefox',
      'mac': 'Library/Application Support/Firefox',
      'win': r'AppData\Roaming\Mozilla\Firefox',
    },
  ];

  /// Detect browsers whose data directory exists on this machine.
  /// [homeDir] is injectable for tests; production passes the real HOME.
  static List<DetectedBrowser> detect({String? homeDir}) {
    final home = homeDir ?? _home();
    final result = <DetectedBrowser>[];
    for (final spec in _specs) {
      final dataDir = _dataDir(spec, home);
      if (dataDir == null) continue;
      result.add(DetectedBrowser(
        id: spec['id']! as String,
        displayName: spec['name']! as String,
        binaryPath: _findBinary(spec['id']! as String),
        dataDir: dataDir,
      ));
    }
    return result;
  }

  static String? _dataDir(Map<String, Object> spec, String home) {
    final key = Platform.isWindows
        ? 'win'
        : Platform.isMacOS
            ? 'mac'
            : 'linux';
    final rel = spec[key]! as String;
    final path = '$home${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}';
    return Directory(path).existsSync() ? path : null;
  }

  static String? _findBinary(String id) {
    final names = switch (id) {
      'brave' => ['brave', 'brave-browser'],
      'chrome' => ['google-chrome', 'google-chrome-stable', 'chrome'],
      'chromium' => ['chromium', 'chromium-browser'],
      'edge' => ['microsoft-edge', 'microsoft-edge-stable'],
      'opera' => ['opera'],
      'vivaldi' => ['vivaldi'],
      'zen' => ['zen'],
      'firefox' => ['firefox'],
      _ => <String>[],
    };
    final pathEnv = Platform.environment['PATH'] ?? '';
    // PATH entries are separated with ':' on Unix and ';' on Windows, which
    // is NOT the same as [Platform.pathSeparator] ('/'), so split carefully.
    final pathSep = Platform.isWindows ? ';' : ':';
    for (final dir in pathEnv.split(pathSep)) {
      for (final name in names) {
        final candidate = dir.isEmpty
            ? name
            : '$dir${Platform.pathSeparator}'
                '${Platform.isWindows ? '$name.exe' : name}';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  static String _home() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? r'C:\Users\Default';
    }
    return Platform.environment['HOME'] ?? '/root';
  }
}
