import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/rules/rules_screen.dart';

void main() {
  test('scoring document link follows the UI language', () {
    expect(RulesScreen.scoringDocUrl('zh'), endsWith('/docs/SCORING.md'));
    expect(RulesScreen.scoringDocUrl('en'), endsWith('/docs/SCORING.en.md'));
    expect(RulesScreen.scoringDocUrl('ja'), endsWith('/docs/SCORING.ja.md'));
  });
}
