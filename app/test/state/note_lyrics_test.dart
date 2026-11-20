import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/note_lyrics.dart';

void main() {
  test('a character per note when they match', () {
    expect(lyricsForNotes([1.0, 1.5], [const LyricLine(0.9, 3, '晴天，')]), ['晴', '天']);
  });

  test('held syllables show the hold mark; fewer notes take several', () {
    expect(lyricsForNotes([1, 2, 3, 4], [const LyricLine(0.9, 5, '你好')]), ['你', lyricHold, '好', lyricHold]);
    expect(lyricsForNotes([1, 2], [const LyricLine(0.9, 5, '故事的小黃花')]), ['故事的', '小黃花']);
  });

  test('notes outside every line have no lyric; each note belongs to one line', () {
    final lines = [const LyricLine(1, 2, 'あい'), const LyricLine(2, 3, 'うえ')];
    expect(lyricsForNotes([0.2, 1.1, 1.6, 2.1, 2.6, 3.5], lines), [null, 'あ', 'い', 'う', 'え', null]);
  });

  test('units: small kana and ー join the syllable before, words stay whole', () {
    expect(lyricUnits('きょうはラーメン！'), ['きょ', 'う', 'は', 'ラー', 'メ', 'ン']);
    expect(lyricUnits("Don't stop, believin'"), ["Don't", 'stop', "believin'"]);
    expect(lyricsForNotes([1, 2, 3], [const LyricLine(0.9, 4, 'Let it go')]), ['Let', 'it', 'go']);
    expect(lyricUnits('사랑해 love'), ['사', '랑', '해', 'love']);
  });

  test('no lyrics: nothing to show', () {
    expect(lyricsForNotes([1, 2], const []), [null, null]);
  });
}
