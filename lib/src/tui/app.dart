import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide LogEntry, Clipboard;

import '../models/profile.dart';
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

enum _Panel { main, help, quit, login, portConfig }

enum _InfoPage { profile, usage, models, proxy }

class AppState extends State<AgroutApp> {
  late final _profiles = component.profileStore;
  late final _config = component.configStore;
  late final _proxy = component.proxyServer;

  _Panel _panel = _Panel.main;
  _InfoPage _infoPage = _InfoPage.profile;
  bool _showLog = false;
  bool _logFullscreen = false;
  String _status = '';
  Timer? _statusTimer;
  Timer? _pageRefreshTimer;

  int _selectedModelIndex = 0;
  bool _loadingModels = false;

  final _portCtrl = TextEditingController();
  bool _portScanDone = false;
  final Map<int, bool> _portStatus = {};

  String? _loginUrl;
  Timer? _loginExpiry;
  bool _loginBusy = false;
  String? _loginMessage;

  final _infoScrollCtrl = ScrollController();
  final _logScrollCtrl = ScrollController();
  int _lastLogVersion = -1;
  int _lastModelVersion = -1;

  static const _pageNames = ['Profile', 'Usage & Cost', 'Models', 'Proxy Config'];

  @override
  void initState() {
    super.initState();
    LogStore.init();
    LogStore.info('agrout-bridge starting...');
    _startPageRefresh();
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
    _pageRefreshTimer?.cancel();
    _pageRefreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (_panel == _Panel.main && _showLog && _lastLogVersion != LogStore.version) {
        _lastLogVersion = LogStore.version;
        setState(() {});
        return;
      }
      if (_lastModelVersion != _proxy.modelCacheVersion) {
        _lastModelVersion = _proxy.modelCacheVersion;
        setState(() {});
        return;
      }
      if (_infoPage == _InfoPage.proxy || _infoPage == _InfoPage.usage) {
        setState(() {});
      }
    });
  }

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
      if (e.logicalKey == LogicalKey.keyF) { _logFullscreen = !_logFullscreen; setState(() {}); return true; }
      if (e.logicalKey == LogicalKey.keyC && e.isShiftPressed) { LogStore.clear(); _lastLogVersion = LogStore.version; _setStatus('Cleared all log entries', duration: 3); setState(() {}); return true; }
      if (e.logicalKey == LogicalKey.keyO && e.isShiftPressed) { LogStore.clearBeforeToday(); _lastLogVersion = LogStore.version; _setStatus('Cleared entries before today', duration: 3); setState(() {}); return true; }
    }
    if (_infoPage == _InfoPage.models && e.logicalKey == LogicalKey.enter) {
      _copySelectedModel();
      return true;
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
    _infoScrollCtrl.jumpTo(0);
    setState(() {});
  }

  void _doRefresh() async {
    if (_loadingModels) return;
    _loadingModels = true;
    _setStatus('Refreshing model list from agentrouter.org...');
    try {
      final n = await _proxy.refreshModels();
      _lastModelVersion = _proxy.modelCacheVersion;
      _setStatus('Data refreshed: $n model(s)', duration: 3);
    } finally {
      _loadingModels = false;
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
          Text(' agrout-bridge', style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
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
    return '${p.name}${p.isLoggedIn ? " (logged-in)" : ""}';
  }

  // ── Body: switches between panels and main split ─────────────────
  Component _buildBody() {
    if (_panel == _Panel.help) return _helpPanel();
    if (_panel == _Panel.quit) return _quitPanel();
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
      _kv('Logged in', p == null ? '-' : (p.isLoggedIn ? 'yes' : 'no')),
      if (p?.isLoggedIn == true) ...[
        _kv('Auth token at', p!.authTokenAt?.toIso8601String().substring(0, 19) ?? '-'),
        if (p.accountInfo != null) ...[
          _section('Account info'),
          _kv('Username', p.accountInfo!['username']?.toString() ?? '-'),
          _kv('Email', p.accountInfo!['email']?.toString() ?? '-'),
          _kv('Group', p.accountInfo!['group']?.toString() ?? '-'),
          _kv('Quota', p.accountInfo!['quota']?.toString() ?? '-'),
          _kv('Used', p.accountInfo!['used_quota']?.toString() ?? '-'),
        ],
      ],
      _section('Available profiles'),
      ..._profiles.all.map((pr) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 0),
            child: Text('${pr.id == id ? "*" : " "} ${pr.name}${pr.isLoggedIn ? " (logged-in)" : ""}', style: const TextStyle(color: Colors.grey)),
          )),
      if (_profiles.all.isEmpty)
        Text('No profiles. Run `agrout-bridge profile add <name> <key>` then restart.', style: TextStyle(color: Colors.grey)),
    ];
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

  List<Component> _modelHeaderRows() => [_section('Models (live /v1/models)')];

  List<Component> _buildModelRows() {
    final s = _proxy.status();
    if (s.modelCount == 0) {
      return [Padding(padding: const EdgeInsets.all(2), child: Text('No models yet — press [r] to fetch', style: TextStyle(color: Colors.grey)))];
    }
    final m = _proxy.modelIds;
    if (m.isEmpty) return const [];
    return m.asMap().entries.map((entry) {
      final i = entry.key;
      final id = entry.value;
      final selected = i == _selectedModelIndex;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 0),
        child: Text('${selected ? '>' : ' '} $id', style: TextStyle(color: selected ? Colors.cyan : Colors.grey)),
      );
    }).toList();
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(children: [
        Text(' ${_status.isEmpty ? "Idle" : _status}', style: TextStyle(color: _status.isEmpty ? Colors.grey : _notifColor())),
      ]),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────
  Component _buildFooter() {
    final hint = _panel == _Panel.main
        ? '[1-4] page | [r] refresh | [o]/[a] copy endpoint | [p] port | [l] login | [h] help | [q] quit | [Ctrl+L] log'
        : (_panel == _Panel.login ? '[c] copy URL | [Esc] close' : '[Esc] back');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Text(' $hint', style: TextStyle(color: Colors.grey)),
    );
  }

  // ── Log side panel ────────────────────────────────────────────────
  Component _logPanel({required bool fullscreen}) {
    final entries = LogStore.latestFirst.take(200).toList();
    _lastLogVersion = LogStore.version;
    final listChildren = <Component>[];
    String? lastDate;
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    for (final entry in entries) {
      final ds = '${entry.timestamp.year}-${entry.timestamp.month.toString().padLeft(2, '0')}-${entry.timestamp.day.toString().padLeft(2, '0')}';
      if (ds != lastDate) {
        lastDate = ds;
        final dn = dayNames[(entry.timestamp.weekday - 1).clamp(0, 6)];
        listChildren.add(Text('${"─" * 12} $dn ${"─" * 12}', style: const TextStyle(color: Colors.grey)));
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
      ]),
      Container(height: 1, color: Colors.grey),
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
    add('  [1] Profile       - active profile, key, login state, account info');
    add('  [2] Usage & Cost  - request counts, success rate, tokens, cost, per-model');
    add('  [3] Models        - live model list (press Enter to copy id)');
    add('  [4] Proxy Config  - port, endpoints, circuit, WAF cookies');
    add('');
    add('Actions:', Colors.cyan);
    add('  [r]       Refresh models + WAF');
    add('  [o]       Copy OpenAI endpoint URL');
    add('  [a]       Copy Anthropic endpoint URL');
    add('  [Enter]   Copy selected model id (Models page)');
    add('');
    add('Log controls:', Colors.cyan);
    add('  [Ctrl+L]  Toggle log side panel');
    add('  [f]       Toggle log fullscreen / sidebar');
    add('  [Shift+C] Clear all log entries');
    add('  [Shift+O] Clear entries before today');
    add('');
    add('Other:', Colors.cyan);
    add('  [p]  Port configuration panel');
    add('  [l]  Open login URL (captures session token)');
    add('  [h]  Help');
    add('  [q]  Quit');

    return Padding(padding: const EdgeInsets.all(2), child: ListView(controller: _infoScrollCtrl, children: lines));
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
    final activeId = _config.config.activeProfileId;
    if (activeId == null) {
      _setStatus('No active profile. Run `profile add` first.', duration: 4);
      return;
    }
    final p = _profiles.byId(activeId);
    if (p == null) {
      _setStatus('Active profile not found.', duration: 4);
      return;
    }
    _panel = _Panel.login;
    _pageRefreshTimer?.cancel();
    _loginBusy = true;
    _loginMessage = 'Starting local sign-in server...';
    _startLoginServer(p);
    setState(() {});
  }

  Future<void> _startLoginServer(profile) async {
    try {
      final client = AgentRouterClient();
      final flow = LoginFlow(client);
      final url = await flow.start(onResult: (outcome) async {
        if (outcome.success) {
          applyLoginOutcome(profile, outcome, _profiles);
          _loginMessage = 'Login berhasil${outcome.username != null ? " sebagai ${outcome.username}" : ""}';
          _setStatus(_loginMessage!, duration: 4);
          LogStore.success(_loginMessage!);
          _loginBusy = false;
          if (mounted) setState(() {});
        } else {
          _loginMessage = 'Login gagal: ${outcome.message ?? 'unknown'}';
          _setStatus(_loginMessage!, duration: 4);
          LogStore.warning(_loginMessage!);
          _loginBusy = false;
          if (mounted) setState(() {});
        }
      });
      _loginUrl = url;
      _loginMessage = 'Open URL in browser, then return here.';
      _loginBusy = false;
      _loginExpiry?.cancel();
      _loginExpiry = Timer(const Duration(minutes: 10), _closeLoginPanel);
      LogStore.info('Login flow ready: $url');
      if (mounted) setState(() {});
    } catch (e) {
      _loginMessage = 'Failed to start login server: $e';
      _loginBusy = false;
      if (mounted) setState(() {});
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
    return Center(child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Local sign-in link', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
        const SizedBox(height: 1),
        Text(_loginBusy ? 'Starting...' : (_loginUrl ?? '(unavailable)'), style: const TextStyle(color: Colors.green)),
        const SizedBox(height: 1),
        Text(_loginMessage ?? '', style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 1),
        const Text('[c] copy URL   [Esc] close', style: TextStyle(color: Colors.grey)),
      ]),
    ));
  }
}

extension on ServerStatus {
  // no-op extension to keep imports tidy if the type ever needs helpers.
}
