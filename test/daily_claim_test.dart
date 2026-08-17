import 'package:test/test.dart';

import 'package:agrout_bridge/src/services/daily_claim.dart';

void main() {
  group('DailyClaim URL builders', () {
    test('githubUrl builds the authorize URL with client id + state', () {
      final url = DailyClaim.githubUrl('abc123', 'state-token');
      expect(url, 'https://github.com/login/oauth/authorize?'
          'client_id=abc123&state=state-token&scope=user:email');
    });

    test('linuxdoUrl builds the connect.linux.do authorize URL', () {
      final url = DailyClaim.linuxdoUrl('client-x', 'state-y');
      expect(url, 'https://connect.linux.do/oauth2/authorize?'
          'response_type=code&client_id=client-x&state=state-y');
    });

    test('fallbackUrl points at the plain login page', () {
      expect(DailyClaim.fallbackUrl, 'https://agentrouter.org/login');
    });
  });
}