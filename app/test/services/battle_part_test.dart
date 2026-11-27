import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('battles start on part A unless changed; B and the whole song are kept', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    expect(s.battlePart, 'a');
    await s.setBattlePart('b');
    expect((await AppSettings.load()).battlePart, 'b');
    await s.setBattlePart('whole');
    expect(s.battlePart, 'whole');
    await s.setBattlePart('nonsense');
    expect(s.battlePart, 'a');
    SharedPreferences.setMockInitialValues({'battle_part': 'x'});
    expect((await AppSettings.load()).battlePart, 'a', reason: 'an unknown value reads as A');
  });
}
