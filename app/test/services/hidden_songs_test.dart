import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('songs hidden from the library are remembered until shown again', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    var notified = 0;
    settings.addListener(() => notified++);
    expect(settings.hiddenSongs, isEmpty);

    await settings.setSongHidden('a', true);
    await settings.setSongHidden('b', true);
    await settings.setSongHidden('a', true); // twice is still once
    expect((await AppSettings.load()).hiddenSongs, {'a', 'b'});
    expect(notified, 3, reason: 'the library list redraws');

    await settings.setSongHidden('a', false);
    expect((await AppSettings.load()).hiddenSongs, {'b'});
  });
}
