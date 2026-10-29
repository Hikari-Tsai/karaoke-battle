import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/lyrics.dart';

void main() {
  test('parses manual captions and joins multi-line cues', () {
    const vtt = '''WEBVTT
Kind: captions
Language:  ja

00:00:16.592 --> 00:00:20.346
食べなくちゃ　食べなくちゃ

00:00:20.346 --> 00:00:24.262
嫌なこと
忘れさせて？

1:02.000 --> 1:05.500
[音楽]

00:01:10.000 --> 00:01:12.000
Tom &amp; Jerry
''';
    final lines = parseVtt(vtt);
    expect(lines.length, 3);
    expect(lines[0].start, closeTo(16.592, 1e-9));
    expect(lines[0].end, closeTo(20.346, 1e-9));
    expect(lines[1].text, '嫌なこと 忘れさせて？');
    expect(lines[2].text, 'Tom & Jerry');
  });

  test('collapses rolling automatic captions', () {
    const vtt = '''WEBVTT
Kind: captions
Language: en

00:00:01.000 --> 00:00:03.000 align:start position:0%

hello<00:00:01.500><c> world</c>

00:00:03.000 --> 00:00:03.010 align:start position:0%
hello world


00:00:03.010 --> 00:00:05.000 align:start position:0%
hello world
how<00:00:03.500><c> are</c><00:00:04.000><c> you</c>

00:00:05.000 --> 00:00:05.010 align:start position:0%
how are you

''';
    final lines = parseVtt(vtt);
    expect(lines.map((l) => l.text).toList(), ['hello world', 'how are you']);
    expect(lines[0].end, lessThanOrEqualTo(lines[1].start));
  });

  test('line lookup by time', () {
    final t = LyricTrack(lang: 'ja', auto: false, lines: const [LyricLine(1, 2, 'a'), LyricLine(3, 4, 'b')]);
    expect(t.indexAt(0.5), -1);
    expect(t.indexAt(1.5), 0);
    expect(t.indexAt(2.5), -1);
    expect(t.indexAt(3.0), 1);
    expect(t.nextAfter(2.5), 1);
    expect(t.nextAfter(3.5), -1);
  });

  test('plan prefers the song language and adds the UI language as translation', () {
    final p = planSubtitles(manual: ['zh-TW', 'en', 'ja', 'ko', 'live_chat'], auto: ['ja'], songLanguage: 'ja', uiLanguage: 'zh');
    expect(p.primary, 'ja');
    expect(p.secondary, 'zh-TW');
    expect(p.manual, containsAll(['ja', 'zh-TW', 'en', 'ko']));
    expect(p.manual, isNot(contains('live_chat')));
    expect(p.auto, isNull);
  });

  test('no translation when the UI language matches the song', () {
    final p = planSubtitles(manual: ['zh-TW', 'ja'], auto: const [], songLanguage: 'zh', uiLanguage: 'zh');
    expect(p.primary, 'zh-TW');
    expect(p.secondary, isNull);
  });

  test('falls back to the original-language automatic captions', () {
    final p = planSubtitles(manual: const ['live_chat'], auto: ['en', 'ja-orig', 'zh-Hant'], songLanguage: 'zh', uiLanguage: 'zh');
    expect(p.manual, isEmpty);
    expect(p.auto, 'ja-orig');
    expect(p.primary, 'ja-orig');
  });

  test('nothing to download', () {
    expect(planSubtitles(manual: const [], auto: const [], songLanguage: 'ja', uiLanguage: 'zh').isEmpty, isTrue);
  });

  test('lyrics json round trip and default tracks', () {
    final l = Lyrics(tracks: [
      LyricTrack(lang: 'ja', auto: false, lines: const [LyricLine(1, 2, 'a')]),
      LyricTrack(lang: 'zh-TW', auto: false, lines: const [LyricLine(1, 2, '甲')]),
    ], primary: 'ja', secondary: 'zh-TW');
    final r = Lyrics.fromJson(l.toJson());
    expect(r.primaryTrack!.lang, 'ja');
    expect(r.secondaryTrack!.lines.first.text, '甲');
    r.secondary = 'ja';
    expect(r.secondaryTrack, isNull);
  });
}
