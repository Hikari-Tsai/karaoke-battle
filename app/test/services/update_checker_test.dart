import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/update_checker.dart';

void main() {
  test('parses tags and build/pre-release suffixes', () {
    expect(UpdateChecker.parseVersion('v0.1.1'), [0, 1, 1]);
    expect(UpdateChecker.parseVersion('1.2.3+45'), [1, 2, 3]);
    expect(UpdateChecker.parseVersion('1.2.3-beta.1'), [1, 2, 3]);
    expect(UpdateChecker.parseVersion('2'), [2, 0, 0]);
  });

  test('compares versions numerically', () {
    expect(UpdateChecker.isNewer('v0.1.1', '0.1.0'), isTrue);
    expect(UpdateChecker.isNewer('v0.1.0', '0.1.0'), isFalse);
    expect(UpdateChecker.isNewer('v0.10.0', '0.9.9'), isTrue);
    expect(UpdateChecker.isNewer('v0.1.0', '1.0.0'), isFalse);
    expect(UpdateChecker.compareVersions('1.0.0+7', '1.0.0+3'), 0);
  });

  test('parses the GitHub latest-release payload', () {
    final r = UpdateChecker.parseLatest('{"tag_name":"v0.2.0","name":"v0.2.0","html_url":"https://github.com/Hikari-Tsai/karaoke-battle/releases/tag/v0.2.0"}');
    expect(r.tag, 'v0.2.0');
    expect(r.version, '0.2.0');
    expect(r.url, endsWith('/tag/v0.2.0'));
  });
}
