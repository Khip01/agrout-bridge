import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide LogEntry, Clipboard;

import '../models/profile.dart';
import '../models/version.dart';
import '../services/api_client.dart';
import '../services/login.dart';
import '../services/log_store.dart';
import '../services/usage_store.dart';
import '../server/server_controller.dart';
import 'clipboard.dart';

/// Top-level TUI for `agrout-bridge`. Mirrors the commandcode-bridge layout:
/// header / 4 info pages / log side panel / status bar / footer, with
/// context-scoped keymap (login + port-config + help + quit panels).
class AgroutApp extends StatefulComponent {
  final ProfileStore profileStore;
  final ConfigStore configStore;
  final ServerController proxyServer;
  AgroutApp({required this.profileStore, required this.configStore, required this.proxyServer});

  @override
  State<AgroutApp> createState() => AppState();
}

enum _Panel { main, help, quit, login, portConfig, deleteConfirm }

enum _InfoPage { profile, usage, models, proxy }

/// Which clear action is awaiting Y/N confirmation in the log panel.
enum _ClearScope { none, all, beforeToday }

/// Login-screen lifecycle used to color-code the sign-in dialog.
/// Mirrors a tiny state machine:
///   idle   → waiting for the user to paste/confirm a key (URL is bright,
///            Copy URL is the focused action)
///   success → the API key validated and was stored (green, focus Esc)
///   failed   → key rejected / error (red, show reason, focus Copy URL)
enum _LoginState { idle, loading, success, failed }

class AppState extends State<AgroutApp> {
  late final _profiles = component.profileStore;
  late final _config = component.configStore;
  late final _proxy = component.proxyServer;

  _Panel _panel = _Panel.main;
  _InfoPage _infoPage = _InfoPage.profile;
  bool _showLog = false;
  bool _logFullscreen = false;
  _ClearScope _confirmClear = _ClearScope.none;
  String _status = '';
  Timer? _statusTimer;
  Timer? _pageRefreshTimer;

  int _selectedModelIndex = 0;
  int _selectedProfileIndex = 0;

  Profile? _pendingDeleteProfile;
  bool _loadingModels = false;

  Map<String, dynamic>? _billing;
  bool _loadingBilling = false;

  final _portCtrl = TextEditingController();
  bool _portScanDone = false;
  final Map<int, bool> _portStatus = {};

  String? _loginUrl;
  Timer? _loginExpiry;
  String? _loginMessage;

  /// State machine for the sign-in dialog color coding.
  _LoginState _loginState = _LoginState.idle;
  /// Reason text shown in red when `_loginState == _LoginState.failed`.
  String? _loginError;

  final _infoScrollCtrl = ScrollController();
  final _logScrollCtrl = ScrollController();
  int _lastLogVersion = -1;
  int _lastModelVersion = -1;
  int _lastUsageVersion = 0; // UsageStore.version advances on every record()
  DateTime? _lastRefreshAt; // last foreground refresh timestamp

  static const _pageNames = ['Profile', 'Usage & Cost', 'Models', 'Proxy Config'];

  @override
  void initState() {
    super.initState();
    LogStore.init();
    LogStore.info('agrout-bridge starting...');
    _startPageRefresh();
    unawaited(_refreshBilling());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pageRefreshTimer?.cancel();
    _loginExpiry?.cancel();
    _portCtrl.dispose();
    _infoScrollCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _startPageRefresh() {
    // Refresh every second. Header (uptime + profile) and footer (stream
    // count) update in real-time; page body content uses dirty checks to
    // avoid unnecessary re-render when nothing changed. This mirrors the
    // commandcode-bridge refresh model (1s tick, version-gated body).
    _pageRefreshTimer?.cancel();
    _pageRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _panel != _Panel.main) return;

      bool contentChanged = false;
      if (_showLog && _lastLogVersion != LogStore.version) {
        _lastLogVersion = LogStore.version;
        contentChanged = true;
      }
      if (_lastModelVersion != _proxy.modelCacheVersion) {
        _lastModelVersion = _proxy.modelCacheVersion;
        contentChanged = true;
      }
      final usageVersion = UsageStore().version;
      if (_infoPage == _InfoPage.usage && _lastUsageVersion != usageVersion) {
        _lastUsageVersion = usageVersion;
        contentChanged = true;
      }

      // Uptime lives in the header which re-renders on every setState, so we
      // always call setState to tick the clock. The body ListView is rebuilt
      // but nocterm batches the render, matching commandcode-bridge's clean
      // header/uptime update pattern.
      if (contentChanged || _lastStatusTick != _tickSeconds()) {
        _lastStatusTick = _tickSeconds();
        setState(() {});
      }
    });
  }

  int _lastStatusTick = 0;
  int _tickSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _setStatus(String msg, {int? duration}) {
    _statusTimer?.cancel();
    _status = msg;
    setState(() {});
    if (duration != null && duration > 0) {
      _statusTimer = Timer(Duration(seconds: duration), () {
        if (mounted) {
          _status = '';
          setState(() {});
        }
      });
    }
  }

  Color _notifColor() {
    final m = _status.toLowerCase();
    if (m.startsWith('copied') || m.startsWith('login berhasil')) return Colors.green;
    if (m.startsWith('login gagal') || m.startsWith('failed') || m.contains('invalid') || m.contains('in use')) return Colors.red;
    if (m.contains('clear') || m.contains('warning') || m.contains('confirm')) return Colors.yellow;
    return Colors.cyan;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _onKey,
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
          _buildStatusBar(),
          _buildFooter(),
        ],
      ),
    );
  }

  bool _onKey(KeyboardEvent e) {
    if (_panel == _Panel.help) {
      if (e.logicalKey == LogicalKey.escape ||
          e.logicalKey == LogicalKey.keyH ||
          e.logicalKey == LogicalKey.enter ||
          e.logicalKey == LogicalKey.space) {
        _panel = _Panel.main;
        _startPageRefresh();
        setState(() {});
        return true;
      }
      return false;
    }
    if (_panel == _Panel.quit) {
      if (e.logicalKey == LogicalKey.keyY || e.logicalKey == LogicalKey.enter || (e.logicalKey == LogicalKey.keyC && e.isControlPressed)) {
        _doQuit();
        return true;
      }
      if (e.logicalKey == LogicalKey.keyN || e.logicalKey == LogicalKey.escape) {
        _panel = _Panel.main;
        _startPageRefresh();
        setState(() {});
        return true;
      }
      return false;
    }
    if (_panel == _Panel.deleteConfirm) {
      if (e.logicalKey == LogicalKey.keyY || e.logicalKey == LogicalKey.enter) {
        _confirmDeleteProfile();
        return true;
      }
      if (e.logicalKey == LogicalKey.keyN || e.logicalKey == LogicalKey.escape) {
        _cancelDeleteProfile();
        return true;
      }
      return false;
    }
    if (_panel == _Panel.login) {
      // Login panel: [c] copy URL, [Esc] close (and stop server).
      if (e.logicalKey == LogicalKey.keyC && !e.isControlPressed) {
        final url = _loginUrl;
        if (url != null) {
          unawaited(Clipboard.copy(url));
          _setStatus('Copied login URL to clipboard', duration: 3);
        }
        return true;
      }
      if (e.logicalKey == LogicalKey.escape) {
        _closeLoginPanel();
        return true;
      }
      return false;
    }
    if (_panel == _Panel.portConfig) {
      if (e.logicalKey == LogicalKey.escape) {
        _panel = _Panel.main;
        _startPageRefresh();
        setState(() {});
        return true;
      }
      if (e.logicalKey == LogicalKey.enter) {
        _doSetPort();
        return true;
      }
      return false;
    }
    // Main panel keymap.
    if (e.logicalKey == LogicalKey.keyC && e.isControlPressed) {
      _setStatus('Use [q] to quit', duration: 3);
      return true;
    }
    if (e.logicalKey == LogicalKey.keyL && e.isControlPressed) {
      _showLog = !_showLog;
      if (_showLog) _logFullscreen = false;
      _lastLogVersion = LogStore.version;
      setState(() {});
      return true;
    }
    if (_logicalKeyChar(e) == '1') { _setPage(_InfoPage.profile); return true; }
    if (_logicalKeyChar(e) == '2') { _setPage(_InfoPage.usage); return true; }
    if (_logicalKeyChar(e) == '3') { _setPage(_InfoPage.models); return true; }
    if (_logicalKeyChar(e) == '4') { _setPage(_InfoPage.proxy); return true; }
    if (e.logicalKey == LogicalKey.keyR) { _doRefresh(); return true; }
    if (e.logicalKey == LogicalKey.keyO) { _copyEndpoint(openai: true); return true; }
    if (e.logicalKey == LogicalKey.keyA) { _copyEndpoint(openai: false); return true; }
    if (e.logicalKey == LogicalKey.keyP) { _openPortConfig(); return true; }
    if (e.logicalKey == LogicalKey.keyL) { _openLoginPanel(); return true; }
    if (e.logicalKey == LogicalKey.keyH) { _panel = _Panel.help; _pageRefreshTimer?.cancel(); setState(() {}); return true; }
    if (e.logicalKey == LogicalKey.keyQ) { _panel = _Panel.quit; _pageRefreshTimer?.cancel(); setState(() {}); return true; }
    if (_showLog) {
      // Pending clear confirmation takes priority over every other log key.
      if (_confirmClear != _ClearScope.none) {
        if (e.logicalKey == LogicalKey.keyY || e.logicalKey == LogicalKey.enter) {
          _doConfirmClear();
          return true;
        }
        if (e.logicalKey == LogicalKey.keyN || e.logicalKey == LogicalKey.escape) {
          _cancelConfirmClear();
          return true;
        }
        return false;
      }
      if (e.logicalKey == LogicalKey.keyF) { _logFullscreen = !_logFullscreen; setState(() {}); return true; }
      if (e.logicalKey == LogicalKey.keyC && e.isShiftPressed) {
        if (LogStore.entries.isEmpty) {
          _setStatus('Log is already empty', duration: 3);
          return true;
        }
        _confirmClear = _ClearScope.all;
        _setStatus('Clear ALL ${LogStore.entries.length} log entries? [Y]es [N]o', duration: 0);
        setState(() {});
        return true;
      }
      if (e.logicalKey == LogicalKey.keyO && e.isShiftPressed) {
        final n = LogStore.countBeforeToday();
        if (n == 0) {
          _setStatus('No entries older than today', duration: 3);
          return true;
        }
        _confirmClear = _ClearScope.beforeToday;
        _setStatus('Clear $n entries before today? [Y]es [N]o', duration: 0);
        setState(() {});
        return true;
      }
    }
    if (_infoPage == _InfoPage.models && e.logicalKey == LogicalKey.enter) {
      _copySelectedModel();
      return true;
    }

    // Model list navigation, only on the Models page. Mirrors
    // commandcode-bridge: up/down moves the highlight, Enter copies the id.
    if (_infoPage == _InfoPage.models) {
      final models = _proxy.modelIds;
      if (models.isNotEmpty) {
        if (e.logicalKey == LogicalKey.arrowUp && _selectedModelIndex > 0) {
          _selectedModelIndex--;
          _scrollToModel();
          setState(() {});
          return true;
        }
        if (e.logicalKey == LogicalKey.arrowDown &&
            _selectedModelIndex < models.length - 1) {
          _selectedModelIndex++;
          _scrollToModel();
          setState(() {});
          return true;
        }
        if (e.logicalKey == LogicalKey.pageUp) {
          _scrollUp(10);
          return true;
        }
        if (e.logicalKey == LogicalKey.pageDown) {
          _scrollDown(10);
          return true;
        }
      }
    }

    // Profile list navigation, only on the Profile page: up/down moves the
    // highlight, Enter switches the active profile. Mirrors the Models page
    // picker so users can pick which API key the proxy uses.
    if (_infoPage == _InfoPage.profile) {
      final profiles = _profiles.all;
      if (profiles.isNotEmpty) {
        if (e.logicalKey == LogicalKey.arrowUp && _selectedProfileIndex > 0) {
          _selectedProfileIndex--;
          _scrollToProfile();
          setState(() {});
          return true;
        }
        if (e.logicalKey == LogicalKey.arrowDown &&
            _selectedProfileIndex < profiles.length - 1) {
          _selectedProfileIndex++;
          _scrollToProfile();
          setState(() {});
          return true;
        }
        if (e.logicalKey == LogicalKey.enter) {
          _switchActiveProfile();
          return true;
        }
        if (e.logicalKey == LogicalKey.keyD && e.isShiftPressed && !e.isControlPressed) {
          _askDeleteProfile();
          return true;
        }
        if (e.logicalKey == LogicalKey.pageUp) {
          _scrollUp(10);
          return true;
        }
        if (e.logicalKey == LogicalKey.pageDown) {
          _scrollDown(10);
          return true;
        }
      }
    }
    return false;
  }

  String? _logicalKeyChar(KeyboardEvent e) {
    // Map numeric keypresses for the 1-4 page switchers (LogicalKey doesn't
    // expose a string for digit keys directly).
    switch (e.logicalKey) {
      case LogicalKey.digit1: return '1';
      case LogicalKey.digit2: return '2';
      case LogicalKey.digit3: return '3';
      case LogicalKey.digit4: return '4';
      default: return null;
    }
  }

  void _setPage(_InfoPage p) {
    _infoPage = p;
    _selectedModelIndex = 0;
    if (p == _InfoPage.profile) {
      _syncProfileSelectionToActive();
    }
    _infoScrollCtrl.jumpTo(0);
    setState(() {});
  }

  /// Move the profile highlight to the currently active profile when the
  /// Profile page is shown, so Enter/up/down start from the key in use.
  void _syncProfileSelectionToActive() {
    final id = _config.config.activeProfileId;
    final idx = _profiles.all.indexWhere((pr) => pr.id == id);
    _selectedProfileIndex = idx < 0 ? 0 : idx;
  }

  void _scrollUp(int lines) {
    final newOffset = (_infoScrollCtrl.offset - lines * 1.0).clamp(0.0, double.infinity);
    _infoScrollCtrl.jumpTo(newOffset);
  }

  void _scrollDown(int lines) {
    _infoScrollCtrl.jumpTo(_infoScrollCtrl.offset + lines);
  }

  void _scrollToModel() {
    // Approximate: each model row renders on one line; offset by the header.
    final offset = (_selectedModelIndex * 1.0).clamp(0.0, double.infinity);
    _infoScrollCtrl.jumpTo(offset);
  }

  void _scrollToProfile() {
    // Approximate: each profile row renders on one line; offset by the
    // active-profile summary block above the list.
    final offset = (7.0 + _selectedProfileIndex)
        .clamp(0.0, double.infinity);
    _infoScrollCtrl.jumpTo(offset);
  }

  void _switchActiveProfile() {
    final profiles = _profiles.all;
    if (_selectedProfileIndex < 0 || _selectedProfileIndex >= profiles.length) {
      return;
    }
    final target = profiles[_selectedProfileIndex];
    if (target.id == _config.config.activeProfileId) {
      _setStatus('"${target.name}" is already the active profile', duration: 3);
      return;
    }
    _config.config.activeProfileId = target.id;
    _config.save();
    _billing = null;
    _setStatus('Active profile: ${target.name}', duration: 3);
    LogStore.info('Switched active profile to ${target.name}');
    setState(() {});
    // _doRefresh is async void; it guards itself with _loadingModels.
    _doRefresh();
  }

  /// Open the delete-confirmation dialog for the highlighted profile.
  void _askDeleteProfile() {
    final profiles = _profiles.all;
    if (_selectedProfileIndex < 0 || _selectedProfileIndex >= profiles.length) {
      return;
    }
    _pendingDeleteProfile = profiles[_selectedProfileIndex];
    _pageRefreshTimer?.cancel();
    _panel = _Panel.deleteConfirm;
    setState(() {});
  }

  /// User confirmed the delete: remove the profile, fix the active id, reset
  /// the selection, and return to the main panel.
  void _confirmDeleteProfile() {
    final target = _pendingDeleteProfile;
    _pendingDeleteProfile = null;
    _panel = _Panel.main;
    if (target == null) {
      _startPageRefresh();
      setState(() {});
      return;
    }
    final wasActive = target.id == _config.config.activeProfileId;
    _profiles.remove(target.id);
    if (wasActive) {
      _config.config.activeProfileId = _profiles.all.isNotEmpty ? _profiles.all.first.id : null;
      _config.save();
      _billing = null;
    }
    _selectedProfileIndex = 0;
    _setStatus('Deleted profile "${target.name}"', duration: 3);
    LogStore.info('Deleted profile ${target.name}');
    _startPageRefresh();
    setState(() {});
    _doRefresh();
  }

  void _cancelDeleteProfile() {
    _pendingDeleteProfile = null;
    _panel = _Panel.main;
    _startPageRefresh();
    setState(() {});
  }

  void _doRefresh() async {
    if (_loadingModels) return;
    _loadingModels = true;
    _setStatus('Refreshing model list from agentrouter.org...');
    _lastRefreshAt = DateTime.now();
    try {
      final n = await _proxy.refreshModels();
      _lastModelVersion = _proxy.modelCacheVersion;
      _setStatus('Data refreshed: $n model(s)', duration: 3);
    } finally {
      _loadingModels = false;
      _lastRefreshAt = DateTime.now();
      if (mounted) setState(() {});
    }
    unawaited(_refreshBilling());
  }

  Future<void> _refreshBilling() async {
    final id = _config.config.activeProfileId;
    final p = id == null ? null : _profiles.byId(id);
    if (p == null || p.apiKey.isEmpty) {
      _billing = null;
      return;
    }
    if (_loadingBilling) return;
    _loadingBilling = true;
    try {
      final client = AgentRouterClient();
      final today = DateTime.now();
      final start = DateTime(today.year, today.month, today.day - 30);
      String fmt(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final sub = await client.fetchBillingSubscription(apiKey: p.apiKey);
      final usage = await client.fetchBillingUsage(
        apiKey: p.apiKey,
        startDate: fmt(start),
        endDate: fmt(today),
      );
      _billing = {'subscription': sub, 'usage': usage};
    } catch (e) {
      _billing = null;
      _setStatus('Billing fetch failed: $e', duration: 3);
    } finally {
      _loadingBilling = false;
      if (mounted) setState(() {});
    }
  }

  void _copyEndpoint({required bool openai}) {
    final host = '${_config.config.listenAddress}:${_config.config.serverPort}';
    final url = openai ? 'http://$host/v1' : 'http://$host';
    unawaited(Clipboard.copy(url));
    _setStatus('Copied $url to clipboard', duration: 3);
  }

  void _copySelectedModel() {
    final models = _proxy.modelIds;
    if (models.isEmpty) return;
    final idx = _selectedModelIndex.clamp(0, models.length - 1);
    final id = models[idx];
    unawaited(Clipboard.copy(id));
    _setStatus('Copied model id: $id', duration: 3);
  }

  // ── Header ────────────────────────────────────────────────────────
  Component _buildHeader() {
    final port = _config.config.serverPort;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(' agrout-bridge v$bridgeVersion', style: TextStyle(color: Colors.cyan)),
          const Spacer(),
          Text(_activeProfileLabel(), style: const TextStyle(color: Colors.grey)),
          Text('  [${_pageTab(_infoPage)}] ', style: const TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold)),
          Text(_pageNames[_infoPage.index], style: const TextStyle(color: Colors.white)),
          Text('  port $port', style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  String _pageTab(_InfoPage p) => '${p.index + 1}';
  String _activeProfileLabel() {
    final id = _config.config.activeProfileId;
    if (id == null) return 'no profile';
    final p = _profiles.byId(id);
    if (p == null) return 'unknown';
    return p.name;
  }

  // ── Body: switches between panels and main split ─────────────────
  Component _buildBody() {
    if (_panel == _Panel.help) return _helpPanel();
    if (_panel == _Panel.quit) return _quitPanel();
    if (_panel == _Panel.deleteConfirm) return _deleteConfirmPanel();
    if (_panel == _Panel.login) return _loginPanel();
    if (_panel == _Panel.portConfig) return _portConfigPanel();

    final content = _buildContent();
    if (_logFullscreen && _showLog) {
      return Padding(padding: const EdgeInsets.all(1), child: _logPanel(fullscreen: true));
    }
    if (!_showLog) {
      return Padding(padding: const EdgeInsets.all(1), child: content);
    }
    return Row(
      children: [
        Expanded(flex: 1, child: Padding(padding: const EdgeInsets.all(1), child: content)),
        const SizedBox(width: 1),
        Expanded(
          flex: 1,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration: const BoxDecoration(border: BoxBorder(left: BorderSide(color: Colors.grey))),
            child: _logPanel(fullscreen: false),
          ),
        ),
      ],
    );
  }

  Component _buildContent() {
    final rows = <Component>[];
    rows.addAll(_buildInfoRows());
    if (_infoPage == _InfoPage.models) rows.addAll(_buildModelRows());
    if (rows.isEmpty) {
      return Padding(padding: const EdgeInsets.all(2), child: Text('No data', style: TextStyle(color: Colors.grey)));
    }
    return ListView(controller: _infoScrollCtrl, children: rows);
  }

  List<Component> _buildInfoRows() {
    switch (_infoPage) {
      case _InfoPage.profile:
        return _profileRows();
      case _InfoPage.usage:
        return _usageRows();
      case _InfoPage.models:
        return _modelHeaderRows();
      case _InfoPage.proxy:
        return _proxyRows();
    }
  }

  List<Component> _profileRows() {
    final id = _config.config.activeProfileId;
    final p = id == null ? null : _profiles.byId(id);
    return [
      _section('Active profile'),
      _kv('Name', p?.name ?? '(none)'),
      _kv('ID', p?.id ?? '-'),
      _kv('API key', p == null ? '-' : _mask(p.apiKey)),
      _kv('Created', p?.createdAt.toIso8601String().substring(0, 10) ?? '-'),
      _kv('Key added', p == null ? '-' : _fmtFullDate(p.apiKeyAt ?? p.createdAt)),
      if (_billing != null) ...[
        _section('Billing (via API key)'),
        _kv('Soft limit (quota)', _fmtLimit(_billing!['subscription']?['soft_limit_usd'])),
        _kv('Hard limit', _fmtLimit(_billing!['subscription']?['hard_limit_usd'])),
        _kv('Used (last 30d)', _fmtUsed(_billing!['usage']?['total_usage'])),
      ] else if (_loadingBilling)
        Text('Fetching billing...', style: TextStyle(color: Colors.grey)),
      _section('Profiles (up/down select, Enter switch)'),
      ..._profiles.all.asMap().entries.map((entry) {
        final i = entry.key;
        final pr = entry.value;
        final isCurrent = pr.id == id;
        final isSelected = i == _selectedProfileIndex;
        final prefix = isSelected ? '▸ ' : '  ';
        final style = isSelected
            ? const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)
            : const TextStyle(color: Colors.grey);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 0),
          child: Row(children: [
            Text(prefix, style: style),
            Text(pr.name, style: style),
            if (isCurrent)
              Text(' (current)',
                  style: const TextStyle(
                    color: Color(0xFF7FFF00),
                    fontWeight: FontWeight.bold,
                  )),
          ]),
        );
      }),
      if (_profiles.all.isEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 1),
          child: Row(children: [
            const Text('No API key yet. Press ', style: TextStyle(color: Colors.grey)),
            Text('[l]', style: const TextStyle(color: Color(0xFF8BD4BA), fontWeight: FontWeight.bold)),
            const Text(' login to paste your AgentRouter API key.', style: TextStyle(color: Colors.grey)),
          ]),
        ),
    ];
  }

  bool get _hasNoKey => _profiles.all.isEmpty || _profiles.all.every((p) => p.apiKey.isEmpty);

  String _fmtLimit(dynamic v) {
    if (v is! num) return '-';
    if (v >= 100000000) return 'unlimited';
    return v.toStringAsFixed(2);
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  String _fmtFullDate(DateTime dt) {
    final d = dt.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    final ss = d.second.toString().padLeft(2, '0');
    return '${_months[d.month - 1]} ${d.day}, ${d.year} at $hh:$mm:$ss';
  }

  String _fmtUsed(dynamic v) {
    if (v is! num) return '-';
    return v.toStringAsFixed(4);
  }

  List<Component> _usageRows() {
    final u = UsageStore();
    final m = u.perModel;
    return [
      _section('Requests'),
      _kv('Total', '${u.totalRequests}'),
      _kv('Successful', '${u.successRequests}'),
      _kv('Streamed', '${u.streamRequests}'),
      _kv('Success rate', '${(u.successRate * 100).toStringAsFixed(1)}%'),
      _kv('Last model', u.lastModel ?? '-'),
      _kv('Last request', u.lastRequestAt?.toIso8601String().substring(0, 19) ?? '-'),
      _section('Tokens (cumulative)'),
      _kv('Input', '${u.inputTokens}'),
      _kv('Output', '${u.outputTokens}'),
      _kv('Cache read', '${u.cacheReadTokens}'),
      _kv('Cache creation', '${u.cacheCreationTokens}'),
      _kv('Cost (CNY)', u.costCny.toStringAsFixed(4)),
      _section('Per-model breakdown'),
      if (m.isEmpty) Text('No requests yet.', style: TextStyle(color: Colors.grey)),
      ...m.map((stat) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 0),
            child: Text('${stat.model.padRight(28)} n=${stat.count} ok=${stat.successCount} in=${stat.inputTokens} out=${stat.outputTokens} cost=${stat.costCny.toStringAsFixed(4)}', style: const TextStyle(color: Colors.grey)),
          )),
    ];
  }

  List<Component> _modelHeaderRows() {
    final n = _proxy.modelIds.length;
    return [
      _section('Models (live /v1/models)'),
      Padding(
        padding: const EdgeInsets.only(left: 1),
        child: Text(
          n == 0
              ? 'No models cached. Press [r] to fetch from agentrouter.org.'
              : '$n model(s) available on this profile. [up/down] select, [Enter] copy id.',
          style: const TextStyle(color: Colors.grey),
        ),
      ),
      const SizedBox(height: 1),
    ];
  }

  List<Component> _buildModelRows() {
    final s = _proxy.status();
    if (s.modelCount == 0) {
      return [
        Padding(
          padding: const EdgeInsets.all(2),
          child: Text('No models yet, press [r] to fetch',
              style: TextStyle(color: Colors.grey)),
        ),
      ];
    }
    final m = _proxy.modelIds;
    if (m.isEmpty) return const [];

    final rows = <Component>[];
    final health = (s.modelHealth['failures'] as Map?) ?? const {};
    String? group;

    for (var i = 0; i < m.length; i++) {
      final id = m[i];
      final selected = i == _selectedModelIndex;
      final curGroup = _modelFamily(id);

      // Group header per model family (anthropic / openai / other), mirroring
      // commandcode-bridge's provider grouping.
      if (curGroup != group) {
        group = curGroup;
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 1));
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(curGroup,
              style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
        ));
      }

      final fails = health[id];
      final degraded = fails is int && fails > 0;
      final prefix = selected ? '▸ ' : '  ';
      final suffix = degraded ? '  [$fails recent failure(s)]' : '';
      rows.add(Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text('$prefix$id$suffix',
            style: TextStyle(
              color: selected
                  ? Colors.cyan
                  : degraded
                      ? Colors.yellow
                      : Colors.grey,
              fontWeight: selected ? FontWeight.bold : null,
            )),
      ));
    }
    return rows;
  }

  /// Coarse family label used to group the live model list.
  String _modelFamily(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('claude')) return 'Anthropic';
    if (lower.startsWith('gpt') || lower.contains('openai')) return 'OpenAI';
    if (lower.contains('gemini')) return 'Google';
    if (lower.contains('grok')) return 'xAI';
    return 'Other';
  }

  List<Component> _proxyRows() {
    final s = _proxy.status();
    final cookies = s.wafCookies.keys.toList();
    return [
      _section('Server'),
      _kv('Listen', '${s.listenAddress}:${s.port}'),
      _kv('Running', s.running ? 'yes' : 'no'),
      _kv('Active streams', '${s.activeStreams}'),
      _kv('Uptime (s)', '${DateTime.now().difference(s.startedAt).inSeconds}'),
      _section('Circuit breaker'),
      _kv('Open', s.circuit['isOpen'].toString()),
      _kv('Consecutive fails', s.circuit['consecutiveFails'].toString()),
      _section('WAF cookie jar'),
      _kv('Entries', cookies.isEmpty ? '(none)' : cookies.join(', ')),
      _section('Model health'),
      ..._modelHealthText(s.modelHealth),
      _section('Endpoints'),
      _kv('OpenAI', 'http://${s.listenAddress}:${s.port}/v1'),
      _kv('Anthropic', 'http://${s.listenAddress}:${s.port}'),
    ];
  }

  List<Component> _modelHealthText(Map<String, dynamic> snap) {
    final failures = (snap['failures'] as Map?) ?? const {};
    if (failures.isEmpty) return [const Text('  no recorded failures', style: TextStyle(color: Colors.grey))];
    return failures.entries.map((e) => Text('  ${e.key}: ${e.value}', style: const TextStyle(color: Colors.grey))).toList();
  }

  Component _section(String label) => Padding(
        padding: const EdgeInsets.only(top: 1, bottom: 0),
        child: Text(label, style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
      );

  Component _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 0),
        child: Row(children: [
          SizedBox(width: 18, child: Text(' $k', style: TextStyle(color: Colors.grey))),
          Expanded(child: Text(v)),
        ]),
      );

  String _mask(String s) {
    if (s.length <= 10) return 'sk-***';
    return '${s.substring(0, 7)}...${s.substring(s.length - 4)}';
  }

  // ── Status bar ────────────────────────────────────────────────────
  Component _buildStatusBar() {
    final s = _proxy.status();
    final uptime = DateTime.now().difference(s.startedAt);
    final h = uptime.inHours;
    final m = uptime.inMinutes.remainder(60);
    final sec = uptime.inSeconds.remainder(60);
    final upStr = '${h}h ${m}m ${sec}s';
    final streams = s.activeStreams;

    // Left indicator: single source of truth, no duplicated text.
    //   - Stopped    -> red
    //   - Idle       -> grey "Proxy ready" (or transient status message)
    //   - Streaming  -> green/yellow "Streaming N" (replaces "Proxy ready")
    String leftText;
    Color leftColor;
    if (!s.running) {
      leftText = 'Proxy stopped';
      leftColor = Colors.red;
    } else if (streams > 0) {
      leftText = 'Streaming ($streams)';
      leftColor = Colors.yellow;
    } else if (_status.isNotEmpty) {
      leftText = _status;
      leftColor = _notifColor();
    } else {
      leftText = 'Proxy ready';
      leftColor = Colors.green;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(children: [
        Text(' $leftText', style: TextStyle(color: leftColor)),
        const Spacer(),
        Text('  uptime: $upStr', style: const TextStyle(color: Colors.grey)),
        Text('  ${_refreshLabel()}', style: TextStyle(color: _proxyLoadingColor())),
      ]),
    );
  }

  /// Color for the refresh/idle indicator: cyan when idle, yellow while
  /// refreshing from the upstream.
  Color _proxyLoadingColor() => _loadingModels ? Colors.yellow : Colors.grey;

  String _refreshLabel() {
    if (_loadingModels) return 'Refreshing…';
    if (_lastRefreshAt == null) return 'Idle';
    final secs = DateTime.now().difference(_lastRefreshAt!).inSeconds;
    return '${secs}s ago';
  }

  // ── Footer ────────────────────────────────────────────────────────
  Component _buildFooter() {
    final base = TextStyle(color: Colors.grey);
    final navStyle = TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold);
    final actionStyle = TextStyle(color: const Color(0xFF8BD4BA), fontWeight: FontWeight.bold); // soft green
    final cfgStyle = TextStyle(color: const Color(0xFFD19A66)); // amber
    if (_panel != _Panel.main) {
      final hint = _panel == _Panel.login
          ? '[c] copy URL | [Esc] close'
          : _panel == _Panel.deleteConfirm
              ? '[y] confirm  [n] cancel'
              : '[Esc] back';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(' $hint', style: base),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(children: [
        Text('[1-4] ', style: navStyle),
        Text('page  ', style: base),
        Text('[r] ', style: actionStyle),
        Text('refresh  ', style: base),
        Text('[o]/[a] ', style: actionStyle),
        Text('copy endpoint  ', style: base),
        Text('[p] ', style: cfgStyle),
        Text('port  ', style: base),
        if (_hasNoKey)
          Text('[l] ', style: actionStyle)
        else
          Text('[l] ', style: cfgStyle),
        Text('login  ', style: _hasNoKey ? actionStyle : base),
        Text('[h] ', style: base),
        Text('help  ', style: base),
        Text('[q] ', style: base),
        Text('quit  ', style: base),
        Text('[Ctrl+L] ', style: base),
        Text('log', style: base),
        ..._pageScopedFooter(base),
      ]),
    );
  }

  /// Keys that only work on the current page, highlighted so the user sees
  /// there is extra keymap available beyond the global footer keys.
  List<Component> _pageScopedFooter(TextStyle base) {
    final pageStyle = TextStyle(
      color: const Color(0xFFE08BFF), // bright violet, distinct from nav/action/config
      fontWeight: FontWeight.bold,
    );
    switch (_infoPage) {
      case _InfoPage.profile:
        return [
          Text('  |  ', style: base),
          Text('[up/down] ', style: pageStyle),
          Text('pick  ', style: pageStyle),
          Text('[Enter] ', style: pageStyle),
          Text('switch  ', style: pageStyle),
          Text('[Shift+D] ', style: pageStyle),
          Text('delete', style: pageStyle),
        ];
      case _InfoPage.models:
        return [
          Text('  |  ', style: base),
          Text('[up/down] ', style: pageStyle),
          Text('pick  ', style: pageStyle),
          Text('[Enter] ', style: pageStyle),
          Text('copy id', style: pageStyle),
        ];
      case _InfoPage.usage:
      case _InfoPage.proxy:
        return const [];
    }
  }

  // ── Log side panel ────────────────────────────────────────────────
  void _doConfirmClear() {
    switch (_confirmClear) {
      case _ClearScope.beforeToday:
        final n = LogStore.countBeforeToday();
        LogStore.clearBeforeToday();
        _setStatus('Cleared $n entries before today', duration: 3);
        break;
      case _ClearScope.all:
        LogStore.clear();
        _setStatus('Cleared all log entries', duration: 3);
        break;
      case _ClearScope.none:
        break;
    }
    _confirmClear = _ClearScope.none;
    LogStore.info('Log cleared by user');
    _lastLogVersion = LogStore.version;
    setState(() {});
  }

  void _cancelConfirmClear() {
    _confirmClear = _ClearScope.none;
    _setStatus('Clear cancelled', duration: 2);
    setState(() {});
  }

  Component _logPanel({required bool fullscreen}) {
    final entries = LogStore.latestFirst.take(200).toList();
    _lastLogVersion = LogStore.version;
    final listChildren = <Component>[];
    String? lastDate;
    for (final entry in entries) {
      final ds = '${entry.timestamp.year}-${entry.timestamp.month.toString().padLeft(2, '0')}-${entry.timestamp.day.toString().padLeft(2, '0')}';
      if (ds != lastDate) {
        lastDate = ds;
        final label = _dayDividerLabel(entry.timestamp);
        listChildren.add(Text('${"─" * 4} $label ${"─" * 4}', style: const TextStyle(color: Colors.grey)));
      }
      final t = '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';
      listChildren.add(Row(children: [
        Text('[$t]', style: const TextStyle(color: Colors.grey)),
        Text(' [${_logLevel(entry.level)}] ', style: TextStyle(color: _logColor(entry.level))),
        Expanded(child: Text(entry.message)),
      ]));
    }
    return Column(children: [
      Row(children: [
        Text(fullscreen ? ' LOG (fullscreen)' : ' LOG', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan)),
        const Spacer(),
        if (!fullscreen) const Text('[f]ull ', style: TextStyle(color: Colors.grey)),
        const Text('[C]lear ', style: TextStyle(color: Colors.grey)),
        const Text('[O]ld ', style: TextStyle(color: Colors.grey)),
      ]),
      Container(height: 1, color: Colors.grey),
      if (_confirmClear != _ClearScope.none)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0),
          child: Text(
            _confirmClear == _ClearScope.all
                ? ' Clear ALL entries? [Y]es  [N]o'
                : ' Clear entries before today? [Y]es  [N]o',
            style: const TextStyle(color: Color(0xFFFFB347), fontWeight: FontWeight.bold),
          ),
        ),
      Expanded(
        child: Scrollbar(
          controller: _logScrollCtrl,
          thumbVisibility: true,
          thickness: 1,
          thumbColor: Colors.grey,
          child: ListView(controller: _logScrollCtrl, children: listChildren),
        ),
      ),
    ]);
  }

  /// Full-date divider label for the log panel:
  ///   "Today - Sunday, 16 Aug 26"
  ///   "Yesterday - Saturday, 15 Aug 26"
  ///   "Friday, 14 Aug 26"
  String _dayDividerLabel(DateTime ts) {
    const dayNames = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
    ];
    const monthNames = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dn = dayNames[(ts.weekday - 1).clamp(0, 6)];
    final mn = monthNames[(ts.month - 1).clamp(0, 11)];
    final yy = (ts.year % 100).toString().padLeft(2, '0');
    final stamp = '$dn, ${ts.day} $mn $yy';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(ts.year, ts.month, ts.day);
    final diff = today.difference(entryDay).inDays;
    if (diff == 0) return 'Today - $stamp';
    if (diff == 1) return 'Yesterday - $stamp';
    return stamp;
  }

  String _logLevel(LogLevel l) {
    switch (l) {
      case LogLevel.error: return 'ERR';
      case LogLevel.warning: return 'WRN';
      case LogLevel.success: return 'OK';
      case LogLevel.info: return 'INF';
      case LogLevel.debug: return 'DBG';
    }
  }

  Color _logColor(LogLevel l) {
    switch (l) {
      case LogLevel.error: return Colors.red;
      case LogLevel.warning: return Colors.yellow;
      case LogLevel.success: return Colors.green;
      case LogLevel.info: return Colors.cyan;
      case LogLevel.debug: return Colors.grey;
    }
  }

  // ── Help panel ────────────────────────────────────────────────────
  Component _helpPanel() {
    final lines = <Component>[];
    void add(String t, [Color? c]) {
      lines.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 0),
        child: Text(t, style: c != null ? TextStyle(color: c) : null),
      ));
    }

    add('Help', Colors.cyan);
    add('');
    add('Pages:', Colors.cyan);
    add('  [1] Profile       - active profile, key, billing, switch profile');
    add('  [2] Usage & Cost  - request counts, success rate, tokens, cost, per-model');
    add('  [3] Models        - live model list (press Enter to copy id)');
    add('  [4] Proxy Config  - port, endpoints, circuit, WAF cookies');
    add('');
    add('Actions:', Colors.cyan);
    add('  [r]       Refresh models + WAF');
    add('  [o]       Copy OpenAI endpoint URL');
    add('  [a]       Copy Anthropic endpoint URL');
    add('');
    add('Profile page ([1]) only:', Colors.cyan);
    add('  [up/down] Move the profile highlight');
    add('  [Enter]   Switch the active profile');
    add('  [Shift+D] Delete the highlighted profile (asks Y/N)');
    add('  [PgUp/PgDn] Scroll the list by 10 lines');
    add('');
    add('Models page ([3]) only:', Colors.cyan);
    add('  [up/down] Move the model highlight');
    add('  [Enter]   Copy the highlighted model id');
    add('  [PgUp/PgDn] Scroll the list by 10 lines');
    add('');
    add('Log controls:', Colors.cyan);
    add('  [Ctrl+L]  Toggle log side panel');
    add('  [f]       Toggle log fullscreen / sidebar');
    add('  [Shift+C] Clear all log entries (asks Y/N)');
    add('  [Shift+O] Clear entries before today (asks Y/N)');
    add('');
    add('Other:', Colors.cyan);
    add('  [p]  Port configuration panel');
    add('  [l]  Open login URL (paste API key)');
    add('  [h]  Help');
    add('  [q]  Quit');

    return Padding(padding: const EdgeInsets.all(2), child: ListView(controller: _infoScrollCtrl, children: lines));
  }

  // ── Delete-profile confirmation ────────────────────────────────────
  Component _deleteConfirmPanel() {
    final target = _pendingDeleteProfile;
    return Center(child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(border: BoxBorder.all(color: Color(0xFFFF8A8A))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Delete profile?', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFFF8A8A))),
        const SizedBox(height: 1),
        Text('Remove "${target?.name ?? ''}" and its API key?'),
        const SizedBox(height: 1),
        const Text('[y] Yes  [n] No'),
      ]),
    ));
  }

  // ── Quit panel ────────────────────────────────────────────────────
  Component _quitPanel() {
    return Center(child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(border: BoxBorder.all(color: Colors.yellow)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Quit agrout-bridge?', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.yellow)),
        const SizedBox(height: 1),
        Text('Proxy will stop at http://${_config.config.listenAddress}:${_config.config.serverPort}'),
        const SizedBox(height: 1),
        const Text('[y] Yes  [n] No'),
      ]),
    ));
  }

  Future<void> _doQuit() async {
    // Stop the HTTP server first so no in-flight request is left holding
    // a socket, then hand control back to nocterm's shutdown scheduler so
    // the alternate-screen buffer, mouse-tracking, and cursor visibility
    // are restored cleanly. Calling `exit()` directly bypasses all of that
    // and leaves the terminal in the state you observed (mouse still
    // producing escape sequences after quit).
    await _proxy.stop();
    shutdownApp(0);
  }

  // ── Port config panel ─────────────────────────────────────────────
  void _openPortConfig() {
    _portCtrl.text = _config.config.serverPort.toString();
    _portScanDone = false;
    _portStatus.clear();
    _panel = _Panel.portConfig;
    _pageRefreshTimer?.cancel();
    _scanPort(_config.config.serverPort);
    setState(() {});
  }

  Future<void> _scanPort(int port) async {
    _portScanDone = false;
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      _portStatus[port] = true;
    } catch (_) {
      _portStatus[port] = false;
    }
    _portScanDone = true;
    if (mounted) setState(() {});
  }

  Future<void> _doSetPort() async {
    final raw = _portCtrl.text.trim();
    int desired;
    if (raw.isEmpty) {
      desired = AppConfig.defaultPort;
    } else {
      desired = int.tryParse(raw) ?? -1;
    }
    if (desired < 1024 || desired > 65535) {
      _setStatus('Invalid port (1024-65535)', duration: 3);
      return;
    }
    var p = desired;
    // auto-increment scan
    while ((_portStatus[p] == false) && p < 65535) {
      p++;
      await _scanPort(p);
    }
    if (p != desired) {
      _setStatus('Port $desired in use, using $p instead', duration: 4);
    }
    _config.config.serverPort = p;
    _config.save();
    _panel = _Panel.main;
    _startPageRefresh();
    setState(() {});
  }

  Component _portConfigPanel() {
    return Center(child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Port configuration', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
        const SizedBox(height: 1),
        Text('Current: ${_config.config.serverPort}   Enter new port (empty = reset to ${AppConfig.defaultPort})'),
        const SizedBox(height: 1),
        SizedBox(width: 24, child: TextField(controller: _portCtrl, focused: true)),
        const SizedBox(height: 1),
        Text(_portScanDone ? 'Scan: ${_portStatus.entries.map((e) => "${e.key}=${e.value ? "free" : "in-use"}").join(", ")}' : 'Scanning...', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 1),
        const Text('[Enter] save   [Esc] back', style: TextStyle(color: Colors.grey)),
      ]),
    ));
  }

  // ── Login panel (local sign-in URL) ───────────────────────────────
  void _openLoginPanel() {
    // Single-key focus: reuse the active profile, else the first existing
    // profile, else allow a fresh login that creates a profile on success.
    final existing = _config.config.activeProfileId != null
        ? _profiles.byId(_config.config.activeProfileId!)
        : null;
    final fallback = existing ?? (_profiles.all.isNotEmpty ? _profiles.all.first : null);
    // Reset dialog state into the idle state: URL will be highlighted,
    // Copy URL is the focused action, no error text.
    _panel = _Panel.login;
    _pageRefreshTimer?.cancel();
    _loginState = _LoginState.loading;
    _loginError = null;
    _loginMessage = 'Starting local sign-in server...';
    _startLoginServer(fallback);
    setState(() {});
  }

  Future<void> _startLoginServer(Profile? fallback) async {
    try {
      final client = AgentRouterClient();
      final flow = LoginFlow(client);
      final url = await flow.start(onResult: (outcome) async {
        if (outcome.success) {
          if (fallback != null) {
            applyLoginOutcome(fallback, outcome, _profiles);
          } else {
            final created = _profiles.add(
              name: outcome.keyName ?? 'default',
              apiKey: outcome.apiKey!,
            );
            _config.config.activeProfileId = created.id;
            _config.save();
          }
          _loginState = _LoginState.success;
          _loginError = null;
          _loginMessage = 'Login successful';
          // Refresh every page so the new/updated key is loaded everywhere:
          // models, WAF, billing, and the profile summary.
          _lastModelVersion = -1;
          _lastLogVersion = LogStore.version;
          _billing = null;
          _syncProfileSelectionToActive();
          setState(() {});
          _doRefresh();
          unawaited(_refreshBilling());
          _setStatus('API key validated, login successful', duration: 4);
          LogStore.success('Login successful');
        } else {
          _loginState = _LoginState.failed;
          _loginError = outcome.message ?? 'token rejected by agentrouter.org';
          _loginMessage = 'Login failed: ${_loginError}';
          setState(() {});
          _setStatus('Login failed, see dialog for reason', duration: 4);
          LogStore.warning('Login failed: ${_loginError}');
        }
      });
      _loginUrl = url;
      // URL is ready → enter idle state: highlight the URL, enable copy.
      _loginState = _LoginState.idle;
      _loginError = null;
      _loginMessage = 'Open the sign-in URL in a new browser tab, then paste your API key in the form below.';
      _loginExpiry?.cancel();
      _loginExpiry = Timer(const Duration(minutes: 10), _closeLoginPanel);
      LogStore.info('Login flow ready: $url');
      setState(() {});
    } catch (e) {
      _loginState = _LoginState.failed;
      _loginError = 'Failed to start login server: $e';
      _loginMessage = 'Login failed: ${_loginError}';
      setState(() {});
      _setStatus('Login server error, see dialog', duration: 4);
      LogStore.error('Login server failed: $e');
    }
  }

  void _closeLoginPanel() async {
    _loginExpiry?.cancel();
    _loginExpiry = null;
    _loginUrl = null;
    _panel = _Panel.main;
    _startPageRefresh();
    setState(() {});
  }

   Component _loginPanel() {
     // Professional color palette driven by the sign-in state-machine.
     // Uses muted pastels instead of neon - avoids eye strain, stays legible.
     //   idle    -> warm amber (URL is ready, ready-to-action)
     //   success -> soft green (positive, not jarring)
     //   failed  -> warm red (clear error, not screaming)
     //   loading -> soft cyan (neutral activity)
     Color urlColor;
     Color borderColor;
     Color titleColor;
     Color copyColor;   // color of [c] copy URL hint (primary action)
     Color escColor;    // color of [Esc] hint
     Color msgColor;
     String urlText;
     if (_loginState == _LoginState.success) {
       borderColor = const Color(0xFF8BD4BA); // soft green
       titleColor = const Color(0xFF8BD4BA);
       urlColor = const Color(0xFF8BD4BA);
       copyColor = Colors.grey;
       escColor = const Color(0xFF8BD4BA);     // focus Esc - done
       msgColor = const Color(0xFF8BD4BA);
       urlText = 'done';
     } else if (_loginState == _LoginState.failed) {
       borderColor = const Color(0xFFFF8A8A); // warm red (pastel)
       titleColor = const Color(0xFFFF8A8A);
       urlColor = const Color(0xFFFF8A8A);
       copyColor = const Color(0xFFFFB347);              // warm amber - retry action pops
       escColor = Colors.grey;
       msgColor = const Color(0xFFFF8A8A);
       urlText = _loginUrl ?? '(unavailable)';
     } else if (_loginState == _LoginState.loading) {
       borderColor = Colors.grey;
       titleColor = Colors.cyan;
       urlColor = Colors.grey;
       copyColor = Colors.grey;
       escColor = Colors.grey;
       msgColor = Colors.cyan;
       urlText = 'Starting server...';
     } else {
       // idle
       borderColor = const Color(0xFFD19A66); // warm amber
       titleColor = const Color(0xFFD19A66);
       urlColor = const Color(0xFFD19A66);
       copyColor = const Color(0xFFD19A66);  // primary action matches border
       escColor = Colors.grey;
       msgColor = Colors.grey;
       urlText = _loginUrl ?? '(unavailable)';
     }
      return Center(child: SizedBox(
        width: 72, // wrap-content-ish: fits the longest line (URL/message)
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          decoration: BoxDecoration(border: BoxBorder.all(color: borderColor)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Sign in to AgentRouter', style: TextStyle(color: titleColor, fontWeight: FontWeight.bold)),
            const SizedBox(height: 1),
            Text(' Local sign-in link ', style: TextStyle(color: borderColor)),
            const SizedBox(height: 1),
            if (_loginState == _LoginState.loading)
              Text('Starting server...', style: TextStyle(color: Colors.cyan))
            else
             Text(urlText, style: TextStyle(color: urlColor)),
           const SizedBox(height: 1),
           Text(_loginMessage ?? '', style: TextStyle(color: msgColor)),
           if (_loginState == _LoginState.failed && _loginError != null)
             Padding(
               padding: const EdgeInsets.only(top: 1),
               child: Text('Reason: ${_loginError}', style: TextStyle(color: const Color(0xFFFF8A8A), fontStyle: FontStyle.italic)),
             ),
           const SizedBox(height: 1),
           Row(children: [
             Text('[c] copy URL  ', style: TextStyle(color: copyColor)),
             Text('[Esc] close', style: TextStyle(color: escColor)),
           ]),
         ]),
       ),
     ));
   }
 }


