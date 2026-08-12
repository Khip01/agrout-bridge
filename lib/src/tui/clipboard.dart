import 'dart:io';

/// Cross-platform clipboard writer with graceful fallback to OSC 52.
///
/// Order:
///   Linux:  wl-copy > xclip > OSC 52
///   macOS:  pbcopy > OSC 52
///   Windows: clip > OSC 52
///
/// Returns true if a real system clipboard was updated, false if it fell
/// back to OSC 52 (terminal-dependent) or failed silently.
class Clipboard {
  static Future<bool> copy(String text) async {
    try {
      if (Platform.isLinux) {
        if (await _run(['wl-copy'], stdinData: text)) return true;
        if (await _run(['xclip', '-selection', 'clipboard'], stdinData: text)) return true;
      } else if (Platform.isMacOS) {
        if (await _run(['pbcopy'], stdinData: text)) return true;
      } else if (Platform.isWindows) {
        if (await _run(['clip'], stdinData: text)) return true;
      }
    } catch (_) {}
    osc52(text);
    return false;
  }

  static Future<bool> _run(List<String> cmd, {required String stdinData}) async {
    try {
      final p = await Process.start(cmd.first, cmd.sublist(1));
      p.stdin.write(stdinData);
      p.stdin.close();
      return await p.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Emit an OSC 52 escape to the terminal. Only works in terminals that
  /// explicitly enable it (xterm.js, WezTerm, recent alacritty, others).
  static void osc52(String text) {
    try {
      final encoded = _b64(text);
      final esc = '\x1b]52;c;$encoded\x07';
      stdout.write(esc);
    } catch (_) {}
  }

  static String _b64(String s) {
    return _Base64.encode(s.codeUnits);
  }
}

class _Base64 {
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  static String encode(List<int> bytes) {
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i += 3) {
      final b0 = bytes[i];
      final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out.write(_alphabet[b0 >> 2]);
      out.write(_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
      out.write(i + 1 < bytes.length ? _alphabet[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=');
      out.write(i + 2 < bytes.length ? _alphabet[b2 & 0x3f] : '=');
    }
    return out.toString();
  }
}
