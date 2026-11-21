import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/genre_names.dart';

void main() {
  test('genres in the UI language, English when there is no name for it', () {
    expect(genreName('Mandopop', 'zh'), '華語流行');
    expect(genreName('Mandopop', 'ja'), 'マンドポップ');
    expect(genreName('Mandopop', 'en'), 'Mandopop');
    expect(genreName('Ballad', 'zh'), '抒情');
    expect(genreName('Ballad', 'ja'), 'バラード');
    expect(genreName('Breakcore', 'zh'), 'Breakcore', reason: 'no common Chinese name');
    expect(genreName('Breakcore', 'ja'), 'ブレイクコア');
    expect(genreName('Some New Genre', 'zh'), 'Some New Genre', reason: 'not listed');
  });
}
