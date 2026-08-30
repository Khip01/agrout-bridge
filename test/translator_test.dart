import 'package:test/test.dart';

import 'package:agrout_bridge/src/services/translator.dart';

void main() {
  group('primarySubtag', () {
    test('strips region', () {
      expect(primarySubtag('zh-CN'), 'zh');
      expect(primarySubtag('en-US'), 'en');
      expect(primarySubtag('ID'), 'id');
      expect(primarySubtag('id'), 'id');
      expect(primarySubtag(''), '');
    });
  });

  group('isGatewaySupported', () {
    test('CN/EN/FR/DE/RU are supported', () {
      for (final c in ['en', 'zh', 'zh-CN', 'fr', 'de', 'ru', 'EN']) {
        expect(isGatewaySupported(c), isTrue, reason: c);
      }
    });
    test('Indonesian and others are not', () {
      for (final c in ['id', 'ja', 'ko', 'es', 'ms', 'jv']) {
        expect(isGatewaySupported(c), isFalse, reason: c);
      }
    });
  });

  group('languageDisplayName', () {
    test('maps known codes', () {
      expect(languageDisplayName('id'), 'Indonesian');
      expect(languageDisplayName('zh-CN'), 'Chinese');
      expect(languageDisplayName('ja'), 'Japanese');
    });
    test('falls back to the code for unknown', () {
      expect(languageDisplayName('xx'), 'xx');
    });
  });

  group('buildReplyLanguageInstruction', () {
    test('is English and names the original language', () {
      final ins = buildReplyLanguageInstruction('id');
      expect(ins, contains('Respond in Indonesian'));
      expect(ins, contains('autonomously'));
      // Must be English so it does not re-trip the gateway.
      expect(ins, isNot(contains('Balas')));
    });
  });

  group('translateUserMessagesInBody', () {
    // Fake translator: pretends any text containing "halo" is Indonesian and
    // "translates" it by prefixing [EN]; everything else is treated as English
    // passthrough.
    Future<TranslationResult> fakeTranslate(String text) async {
      if (text.toLowerCase().contains('halo')) {
        return TranslationResult(
            detectedLanguage: 'id',
            translatedText: '[EN] $text',
            translated: true);
      }
      return TranslationResult(
          detectedLanguage: 'en', translatedText: text, translated: false);
    }

    test('translates string user content and injects reply instruction', () async {
      final body = {
        'model': 'glm-5.3',
        'messages': [
          {'role': 'system', 'content': 'halo (system stays untouched)'},
          {'role': 'assistant', 'content': 'halo (assistant untouched)'},
          {'role': 'user', 'content': 'halo tolong bantu'},
        ],
      };
      final changed = await translateUserMessagesInBody(body, fakeTranslate);
      expect(changed, isTrue);
      final msgs = body['messages'] as List;
      // system + assistant preserved
      expect(msgs[0]['content'], 'halo (system stays untouched)');
      expect(msgs[1]['content'], 'halo (assistant untouched)');
      // user translated + instruction appended
      final userContent = msgs[2]['content'] as String;
      expect(userContent, startsWith('[EN] halo tolong bantu'));
      expect(userContent, contains('Respond in Indonesian'));
    });

    test('leaves an all-English request unchanged', () async {
      final body = {
        'messages': [
          {'role': 'user', 'content': 'please list files'},
        ],
      };
      final changed = await translateUserMessagesInBody(body, fakeTranslate);
      expect(changed, isFalse);
      expect((body['messages'] as List)[0]['content'], 'please list files');
    });

    test('translates OpenAI-style content parts list', () async {
      final body = {
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'halo dunia'},
              {'type': 'text', 'text': 'second part'},
            ],
          },
        ],
      };
      final changed = await translateUserMessagesInBody(body, fakeTranslate);
      expect(changed, isTrue);
      final parts = (body['messages'] as List)[0]['content'] as List;
      expect(parts[0]['text'], startsWith('[EN] halo dunia'));
      // Instruction appended to the last text part.
      expect(parts.last['text'], contains('Respond in Indonesian'));
    });

    test('injects instruction only on the last user message', () async {
      final body = {
        'messages': [
          {'role': 'user', 'content': 'halo satu'},
          {'role': 'assistant', 'content': 'ok'},
          {'role': 'user', 'content': 'halo dua'},
        ],
      };
      await translateUserMessagesInBody(body, fakeTranslate);
      final msgs = body['messages'] as List;
      expect(msgs[0]['content'], '[EN] halo satu'); // no instruction
      expect(msgs[0]['content'], isNot(contains('Respond in')));
      expect(msgs[2]['content'], contains('Respond in Indonesian'));
    });

    test('no messages array is a no-op', () async {
      final body = {'model': 'x'};
      expect(await translateUserMessagesInBody(body, fakeTranslate), isFalse);
    });
  });
}
