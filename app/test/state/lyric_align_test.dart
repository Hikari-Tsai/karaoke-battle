import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/lyric_align.dart';
import 'package:karaoke_battle/state/whisper_tokenizer.dart';

void main() {
  test('units and syllables', () {
    expect(String.fromCharCodes(comparableUnits('Ｈｅｌｌｏ，世界！カタカナ')), 'hello世界かたかな');
    expect(syllableCount('我們不說再見'), 6);
    expect(syllableCount('ちょっと待って'), 6); // ちょ っ と 待 っ て: small ょ joins, っ is a mora
    expect(syllableCount('Hello beautiful world'), 2 + 3 + 1);
    expect(splitLyricLines(' a \n\n b\r\n'), ['a', 'b']);
  });

  test('notes: lines take runs of notes split at rests, intro notes left out', () {
    // Intro ad-lib (2 notes), then 4 + 3 notes with a rest between.
    final on = [0.0, 0.5, 10.0, 10.5, 11.0, 11.5, 14.0, 14.5, 15.0];
    final off = [0.4, 0.9, 10.4, 10.9, 11.4, 11.9, 14.4, 14.9, 15.4];
    final got = alignToNotes(['一二三四', '五六七'], on, off);
    expect(got.map((l) => (l.start, l.end)), [(10.0, 11.9), (14.0, 15.4)]);
    expect(got.map((l) => l.text), ['一二三四', '五六七']);
  });

  test('segments: lines land on the recognised text, unmatched ones in between', () {
    const segs = [
      TimedText(5, 8, '我聽見雨滴落在青青草地'),
      TimedText(9, 12, '我听见远方下课钟声响起'), // Simplified, partly different characters
      TimedText(20, 23, '可是我没有听见你的声音'),
    ];
    final got = alignToSegments(['我聽見雨滴落在青青草地', '我聽見遠方下課鐘聲響起', '啦啦啦', '可是我沒有聽見你的聲音'], segs);
    expect(got[0].start, 5);
    expect(got[0].end, 8);
    expect(got[1].start, closeTo(9, 0.6));
    expect(got[2].start, greaterThanOrEqualTo(got[1].end));
    expect(got[2].end, lessThanOrEqualTo(got[3].start));
    expect(got[3].start, 20);
    // Snapping to a note onset within 0.4 s.
    final snapped = alignToSegments(['我聽見雨滴落在青青草地'], segs.sublist(0, 1), onsets: [4.8, 6.0]);
    expect(snapped.single.start, 4.8);
  });

  test('recognised text is cut into phrases of a sensible length', () {
    expect(splitPhrases('寫歌，用旋律調整光圈，每一句都對準笑靨'), ['寫歌 用旋律調整光圈', '每一句都對準笑靨']);
    expect(splitPhrases('食べなくちゃ 食べなくちゃ 嫌なことを忘れさせて'), ['食べなくちゃ 食べなくちゃ', '嫌なことを忘れさせて']);
    expect(splitPhrases('I love you though I hate you'), ['I love you though I hate you']);
    expect(echoesPrompt('日本語の歌詞です。', '以下は日本語の歌詞です。'), isTrue);
    expect(echoesPrompt('食べなくちゃ', '以下は日本語の歌詞です。'), isFalse);
  });

  test('known hallucinations are recognised, lyrics are not', () {
    expect(isLikelyHallucination('作词 李宗盛'), isTrue);
    expect(isLikelyHallucination('作曲：周杰倫'), isTrue);
    expect(isLikelyHallucination('字幕由 Amara.org 社群提供'), isTrue);
    expect(isLikelyHallucination('ご視聴ありがとうございました'), isTrue);
    expect(isLikelyHallucination('Thanks for watching!'), isTrue);
    expect(isLikelyHallucination('我聽見雨滴落在青青草地'), isFalse);
    expect(isLikelyHallucination('曲終人散'), isFalse);
  });

  test('tokenizer round trip on a tiny byte-level vocabulary', () {
    // Bytes of "ab" map to themselves; one merge "a b" -> "ab".
    final tok = WhisperTokenizer({'a': 0, 'b': 1, 'ab': 2, 'Ġ': 3}, {'<|endoftext|>': 50257, '<|zh|>': 50260}, [('a', 'b')]);
    expect(tok.encode('ab'), [2]);
    expect(tok.encode('ba'), [1, 0]);
    expect(tok.decode([2, 50257, 0]), 'aba');
    expect(tok.special('<|zh|>'), 50260);
  });
}
