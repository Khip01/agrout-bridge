import 'package:test/test.dart';

import 'package:agrout_bridge/src/services/waf.dart';

void main() {
  group('extractWafCookiePairs', () {
    test('parses single Set-Cookie string', () {
      final pairs = extractWafCookiePairs('acw_tc=abc123; path=/; HttpOnly; Max-Age=1800');
      expect(pairs, ['acw_tc=abc123']);
    });

    test('parses list of Set-Cookie headers', () {
      final pairs = extractWafCookiePairs([
        'acw_tc=abc; path=/; HttpOnly; Max-Age=1800',
        'acw_sc__v2=xyz; path=/; HttpOnly',
        'session=leaked; path=/',  // not a WAF cookie, must be dropped
        'cdn_sec_tc=qwe; path=/; Max-Age=1800',
      ]);
      expect(pairs, containsAll(['acw_tc=abc', 'acw_sc__v2=xyz', 'cdn_sec_tc=qwe']));
      expect(pairs.length, 3);
    });

    test('skips empty / expired cookies', () {
      final pairs = extractWafCookiePairs([
        'acw_tc=; max-age=0',  // expired/cleared
        'acw_tc',  // no `=`
        'acw_tc=',  // empty value
        'other=foo',  // non-WAF name
      ]);
      expect(pairs, isEmpty);
    });

    test('returns empty for null input', () {
      expect(extractWafCookiePairs(null), isEmpty);
    });
  });

  group('mergeWafCookies', () {
    test('adds new names', () {
      final merged = mergeWafCookies({}, ['acw_tc=foo']);
      expect(merged, {'acw_tc': 'foo'});
    });

    test('replaces existing names', () {
      final merged = mergeWafCookies({'acw_tc': 'old'}, ['acw_tc=new']);
      expect(merged['acw_tc'], 'new');
    });

    test('preserves unrelated names', () {
      final merged = mergeWafCookies({'acw_tc': 'a', 'cdn_sec_tc': 'b'}, ['acw_tc=z']);
      expect(merged, {'acw_tc': 'z', 'cdn_sec_tc': 'b'});
    });

    test('does not mutate input map', () {
      final input = {'acw_tc': 'a'};
      mergeWafCookies(input, ['acw_tc=b']);
      expect(input['acw_tc'], 'a');
    });
  });

  group('serializeCookieHeader', () {
    test('returns null for empty map', () {
      expect(serializeCookieHeader(null), isNull);
      expect(serializeCookieHeader({}), isNull);
    });

    test('joins pairs with `; `', () {
      expect(serializeCookieHeader({'acw_tc': 'a', 'cdn_sec_tc': 'b'}), 'acw_tc=a; cdn_sec_tc=b');
    });
  });

  group('isWafBlockStatus', () {
    test('true for 401/403/405', () {
      expect(isWafBlockStatus(401), isTrue);
      expect(isWafBlockStatus(403), isTrue);
      expect(isWafBlockStatus(405), isTrue);
    });

    test('false for 200 / 4xx other than 401/403/405 / 5xx', () {
      expect(isWafBlockStatus(200), isFalse);
      expect(isWafBlockStatus(400), isFalse);
      expect(isWafBlockStatus(404), isFalse);
      expect(isWafBlockStatus(429), isFalse);
      expect(isWafBlockStatus(500), isFalse);
    });
  });
}
