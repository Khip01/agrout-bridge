import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';

enum LogLevel { debug, info, success, warning, error }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;
  LogEntry(this.level, this.message, [DateTime? timestamp])
      : timestamp = timestamp ?? DateTime.now();
  Map<String, dynamic> toJson() => {
        'ts': timestamp.toIso8601String(),
        'level': level.name,
        'message': message,
      };
  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        LogLevel.values.byName(j['level'] as String),
        j['message'] as String,
        DateTime.parse(j['ts'] as String),
      );
}

class LogStore {
  static const int maxEntries = 2000;
  static final Queue<LogEntry> _entries = Queue();
  static String? _path;
  static int _version = 0;
  static int get version => _version;

  static String get path => _path ?? '${configDir()}${Platform.pathSeparator}logs.jsonl';

  static void init() {
    _entries.clear();
    final dir = Directory(configDir());
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _path = '${configDir()}${Platform.pathSeparator}logs.jsonl';
    _loadFromFile();
    _version++;
  }

  static void _loadFromFile() {
    if (_path == null) return;
    final f = File(_path!);
    if (!f.existsSync()) return;
    try {
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        _entries.add(LogEntry.fromJson(jsonDecode(line) as Map<String, dynamic>));
      }
    } catch (_) {}
  }

  static void _append(LogEntry e) {
    if (_path == null) return;
    try {
      File(_path!).writeAsStringSync('${jsonEncode(e.toJson())}\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static void _rewrite() {
    if (_path == null) return;
    try {
      final body = _entries.map((e) => jsonEncode(e.toJson())).join('\n');
      File(_path!).writeAsStringSync('$body\n');
    } catch (_) {}
  }

  static void add(LogLevel l, String msg) {
    final e = LogEntry(l, msg);
    _entries.add(e);
    _append(e);
    if (_entries.length > maxEntries) {
      _entries.removeFirst();
      _rewrite();
    }
    _version++;
  }

  static void debug(String m) => add(LogLevel.debug, m);
  static void info(String m) => add(LogLevel.info, m);
  static void success(String m) => add(LogLevel.success, m);
  static void warning(String m) => add(LogLevel.warning, m);
  static void error(String m) => add(LogLevel.error, m);

  static List<LogEntry> get entries => _entries.toList(growable: false);
  static List<LogEntry> get latestFirst => _entries.toList().reversed.toList();

  static void clear() {
    _entries.clear();
    if (_path != null) {
      try { File(_path!).writeAsStringSync(''); } catch (_) {}
    }
    _version++;
  }

  static void clearBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _entries.removeWhere((e) => e.timestamp.isBefore(today));
    _rewrite();
    _version++;
  }

  /// Number of entries older than 00:00 local time today. Used by the TUI to
  /// decide whether the "clear old entries" action has anything to do.
  static int countBeforeToday() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _entries.where((e) => e.timestamp.isBefore(today)).length;
  }
}
