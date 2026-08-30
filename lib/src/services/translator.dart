import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a single translate call.
class TranslationResult {
  /// The BCP-47-ish source language code the translation engine detected
  /// (e.g. `id`, `en`, `zh-CN`, `ja`). Empty when detection failed.
  final String detectedLanguage;

  /// The English translation of the input. Equal to the input when the source
  /// was already English (or when translation failed and we fell back).
  final String translatedText;

  /// True when translation actually happened (source was a non-supported
  /// language and the text was rewritten).
  final bool translated;

  const TranslationResult({
    required this.detectedLanguage,
    required this.translatedText,
    required this.translated,
  });
}

/// Languages AgentRouter's gateway accepts in `user`-role messages without a
/// `content-blocked` rejection (verified 2026-08-30). Anything else in a user
/// message must be translated to English before forwarding. Matched on the
/// primary subtag only (`zh-CN` -> `zh`).
const Set<String> kGatewaySupportedLanguages = {'en', 'zh', 'fr', 'de', 'ru'};

/// Human-readable names for the reply-language instruction, keyed by the
/// primary language subtag returned by the detector. Falls back to the raw
/// code when unknown.
const Map<String, String> _languageNames = {
  'id': 'Indonesian',
  'en': 'English',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'fr': 'French',
  'de': 'German',
  'ru': 'Russian',
  'es': 'Spanish',
  'pt': 'Portuguese',
  'it': 'Italian',
  'nl': 'Dutch',
  'ar': 'Arabic',
  'hi': 'Hindi',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'ms': 'Malay',
  'tr': 'Turkish',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'jv': 'Javanese',
  'su': 'Sundanese',
  'tl': 'Filipino',
};

/// Normalizes a detector language code to its primary subtag, lowercased.
/// `zh-CN` -> `zh`, `en-US` -> `en`, `ID` -> `id`.
String primarySubtag(String code) {
  final c = code.trim().toLowerCase();
  if (c.isEmpty) return c;
  final dash = c.indexOf(RegExp(r'[-_]'));
  return dash == -1 ? c : c.substring(0, dash);
}

/// Human-readable language name for a detector code, for the reply-language
/// injection. Unknown codes return the code itself.
String languageDisplayName(String code) {
  final sub = primarySubtag(code);
  return _languageNames[sub] ?? (code.isEmpty ? 'the user' + "'s language" : code);
}

/// True when a message written in [detectedCode] would be accepted by the
/// gateway as-is (no translation needed).
bool isGatewaySupported(String detectedCode) =>
    kGatewaySupportedLanguages.contains(primarySubtag(detectedCode));

/// Translates arbitrary text to English and reports the detected source
/// language, using Google's keyless `translate_a/single` endpoint. This is the
/// same endpoint the web widget uses; it needs no API key. All network errors
/// are swallowed and reported as a non-translated passthrough so a translation
/// outage never blocks a proxied request.
class Translator {
  Translator({HttpClient? client, Duration? timeout})
      : _client = client ?? HttpClient(),
        _timeout = timeout ?? const Duration(seconds: 8);

  final HttpClient _client;
  final Duration _timeout;

  static const _endpoint =
      'https://translate.googleapis.com/translate_a/single';

  /// Detect + translate [text] to English. Returns a passthrough result
  /// (`translated: false`, original text) on any failure or empty input.
  Future<TranslationResult> toEnglish(String text) async {
    if (text.trim().isEmpty) {
      return TranslationResult(
          detectedLanguage: '', translatedText: text, translated: false);
    }
    try {
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'client': 'gtx',
        'sl': 'auto',
        'tl': 'en',
        'dt': 't',
        'q': text,
      });
      final req = await _client.getUrl(uri).timeout(_timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final resp = await req.close().timeout(_timeout);
      if (resp.statusCode != 200) {
        return TranslationResult(
            detectedLanguage: '', translatedText: text, translated: false);
      }
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      return _parse(raw, text);
    } catch (_) {
      return TranslationResult(
          detectedLanguage: '', translatedText: text, translated: false);
    }
  }

  /// Parse the `translate_a/single` response shape:
  /// `[[["<translated>","<orig>",...], ...], null, "<detected>", ...]`.
  TranslationResult _parse(String raw, String original) {
    try {
      final data = jsonDecode(raw);
      if (data is! List || data.isEmpty) {
        return TranslationResult(
            detectedLanguage: '', translatedText: original, translated: false);
      }
      // Detected language: data[2] (may also appear at data[8][0][0]).
      var detected = '';
      if (data.length > 2 && data[2] is String) {
        detected = data[2] as String;
      }
      // Concatenate all sentence segments in data[0][*][0].
      final segments = data[0];
      final buffer = StringBuffer();
      if (segments is List) {
        for (final seg in segments) {
          if (seg is List && seg.isNotEmpty && seg[0] is String) {
            buffer.write(seg[0] as String);
          }
        }
      }
      final translatedText =
          buffer.isEmpty ? original : buffer.toString();
      final supported = isGatewaySupported(detected);
      // Only mark as "translated" when we actually replaced non-supported
      // text with a different English rendering.
      final didTranslate =
          !supported && detected.isNotEmpty && translatedText != original;
      return TranslationResult(
        detectedLanguage: detected,
        translatedText: didTranslate ? translatedText : original,
        translated: didTranslate,
      );
    } catch (_) {
      return TranslationResult(
          detectedLanguage: '', translatedText: original, translated: false);
    }
  }

  void close() {
    try {
      _client.close(force: true);
    } catch (_) {}
  }
}

/// Builds the flexible reply-language instruction appended to the last user
/// message after translation. Keeps the model agentic (act, use tools, be
/// concise) and pins the reply language to [originalLanguageCode] so the
/// answer comes back in the user's own language, not English.
///
/// The instruction itself is English so it never re-trips the gateway.
String buildReplyLanguageInstruction(String originalLanguageCode) {
  final lang = languageDisplayName(originalLanguageCode);
  return '\n\n[System note: The message above was auto-translated to English '
      'for compatibility. Respond in $lang (the user\'s original language). '
      'Keep acting autonomously: use tools, make edits, and complete the task '
      'as instructed rather than only describing it. Do not mention this '
      'translation note.]';
}

/// Rewrites the `user`-role messages of a chat request body in place so every
/// user message is in a gateway-supported language, and appends a
/// reply-language instruction (built from the dominant translated language) to
/// the final user message. Handles both the OpenAI (`messages[].content` is a
/// string or a list of `{type:'text', text}` parts) and Anthropic
/// (`messages[].content` is a string or list of content blocks) shapes.
///
/// Only `role == 'user'` messages are touched: the gateway does not check
/// `system`, `assistant`, or tool content. Returns `true` if anything was
/// changed. Never throws; on any failure the body is left as-is.
///
/// [translate] takes a plain string and returns its [TranslationResult]. It is
/// injected so the proxy can share a single [Translator] and so tests can stub
/// it without network access.
Future<bool> translateUserMessagesInBody(
  Map<String, dynamic> body,
  Future<TranslationResult> Function(String text) translate,
) async {
  final msgs = body['messages'];
  if (msgs is! List) return false;

  var changed = false;
  String? lastTranslatedLang; // original language of the last translated user msg
  int? lastUserIndex;

  for (var i = 0; i < msgs.length; i++) {
    final m = msgs[i];
    if (m is! Map) continue;
    if (m['role'] != 'user') continue;
    lastUserIndex = i;

    final content = m['content'];
    if (content is String) {
      final res = await translate(content);
      if (res.translated) {
        m['content'] = res.translatedText;
        changed = true;
        lastTranslatedLang = res.detectedLanguage;
      }
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        // OpenAI: {type:'text', text:'...'}. Anthropic: {type:'text', text:'...'}.
        if (part['type'] == 'text' && part['text'] is String) {
          final res = await translate(part['text'] as String);
          if (res.translated) {
            part['text'] = res.translatedText;
            changed = true;
            lastTranslatedLang = res.detectedLanguage;
          }
        }
      }
    }
  }

  // Append the reply-language instruction to the final user message so the
  // model answers in the user's original language.
  if (changed && lastTranslatedLang != null && lastUserIndex != null) {
    final instruction = buildReplyLanguageInstruction(lastTranslatedLang);
    final m = msgs[lastUserIndex] as Map;
    final content = m['content'];
    if (content is String) {
      m['content'] = content + instruction;
    } else if (content is List && content.isNotEmpty) {
      // Append to the last text part, or add a new text part.
      Map? lastText;
      for (final part in content) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          lastText = part;
        }
      }
      if (lastText != null) {
        lastText['text'] = (lastText['text'] as String) + instruction;
      } else {
        content.add({'type': 'text', 'text': instruction.trimLeft()});
      }
    }
  }

  return changed;
}
