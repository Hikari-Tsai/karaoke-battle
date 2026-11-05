import 'dart:convert';

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

  group('note-driven wipe', () {
    const line = LyricLine(0, 4, 'abc');
    // Notes: three inside the line, one after it, one long before it.
    final on = [-3.0, 0.5, 1.0, 3.0, 6.0];
    final off = [-2.5, 1.0, 2.0, 3.5, 7.0];

    test('equal share per note, fills during the note, holds in gaps', () {
      expect(noteWipeFraction(line, on, off, 0.25), 0);
      expect(noteWipeFraction(line, on, off, 0.75), closeTo(0.5 / 3, 1e-9));
      expect(noteWipeFraction(line, on, off, 1.5), closeTo(1.5 / 3, 1e-9));
      expect(noteWipeFraction(line, on, off, 2.5), closeTo(2 / 3, 1e-9)); // gap: hold
      expect(noteWipeFraction(line, on, off, 3.25), closeTo(2.5 / 3, 1e-9));
      expect(noteWipeFraction(line, on, off, 3.9), 1);
    });

    test('falls back to a linear wipe without notes in the line', () {
      expect(noteWipeFraction(line, const [], const [], 1), closeTo(0.25, 1e-9));
      expect(noteWipeFraction(const LyricLine(10, 12, 'x'), on, off, 11), closeTo(0.5, 1e-9));
    });
  });

  group('imported subtitle files', () {
    test('SRT with an index, comma decimals and override tags', () {
      const srt = '1\r\n00:00:01,000 --> 00:00:03,500\r\n{\\an8}<i>第一行</i>\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\n第二行\r\n第二行續\r\n';
      final l = parseSubtitleFile('song.srt', utf8.encode(srt));
      expect([for (final x in l) (x.start, x.end, x.text)], [(1.0, 3.5, '第一行'), (4.0, 6.0, '第二行 第二行續')]);
    });

    test('LRC: repeated stamps, breaks, offset, word stamps and metadata', () {
      const lrc = '[ti:Song]\n[offset:+500]\n[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:12.00]\n[00:15.00][01:00.00]Chorus\n[00:40.00]Long gap\n';
      final l = parseLrc(lrc);
      expect([for (final x in l) (x.start, x.end, x.text)], [
        (9.5, 11.5, 'Hello world'), // ends at the empty break stamp
        (14.5, 24.5, 'Chorus'), // capped at 10 s
        (39.5, 49.5, 'Long gap'),
        (59.5, 65.5, 'Chorus'), // last line: 6 s
      ]);
    });

    test('BOMs and UTF-16 are decoded; legacy encodings are rejected', () {
      expect(decodeSubtitleBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('歌')]), '歌');
      expect(decodeSubtitleBytes([0xFF, 0xFE, 0x4C, 0x6B]), '歌');
      expect(decodeSubtitleBytes([0xFE, 0xFF, 0x6B, 0x4C]), '歌');
      expect(() => decodeSubtitleBytes([0xBA, 0x71]), throwsA(isA<SubtitleFormatException>().having((e) => e.reason, 'reason', 'encoding')));
      expect(() => parseSubtitleFile('a.txt', utf8.encode('just words')), throwsA(isA<SubtitleFormatException>()));
    });

    test('SRT and LRC written out parse back', () {
      const lines = [LyricLine(1.25, 3.5, 'a'), LyricLine(3.5, 5, 'b'), LyricLine(8, 9.75, 'c')];
      expect([for (final x in parseVtt(toSrt(lines))) (x.start, x.end, x.text)], [(1.25, 3.5, 'a'), (3.5, 5.0, 'b'), (8.0, 9.75, 'c')]);
      expect(toLrc(lines), '[00:01.25]a\n[00:03.50]b\n[00:05.00]\n[00:08.00]c\n[00:09.75]\n');
      expect([for (final x in parseLrc(toLrc(lines))) (x.start, x.end, x.text)], [(1.25, 3.5, 'a'), (3.5, 5.0, 'b'), (8.0, 9.75, 'c')]);
    });

    test('editor times', () {
      expect(formatLyricTime(75.256), '1:15.26');
      expect(formatLyricTime(3725), '1:02:05.00');
      expect(parseLyricTime('1:15.26'), closeTo(75.26, 1e-9));
      expect(parseLyricTime('12,5'), 12.5);
      expect(parseLyricTime('1:02:05'), 3725);
      expect(parseLyricTime('abc'), isNull);
    });
  });

  group('app tracks', () {
    test('keys, edits and the source round-trip', () {
      final yt = LyricTrack(lang: 'zh-TW', auto: false, lines: const [LyricLine(1, 2, '甲')]);
      final lyrics = Lyrics(tracks: [yt], primary: 'zh-TW');
      expect(Lyrics.editKeyFor(yt), 'zh-TW-x-edit');
      expect(lyrics.uniqueKey('zh-TW'), 'zh-TW2');
      final edit = LyricTrack(lang: Lyrics.editKeyFor(yt), auto: false, lines: const [LyricLine(1, 2, '乙')], source: LyricSource.edited);
      lyrics.putPrimary(edit);
      expect(lyrics.primary, 'zh-TW-x-edit');
      expect(Lyrics.editKeyFor(edit), 'zh-TW-x-edit'); // edited in place
      expect(langFamily(edit.lang), 'zh');
      final back = Lyrics.fromJson(jsonDecode(jsonEncode(lyrics.toJson())) as Map<String, dynamic>);
      expect(back.tracks.map((t) => (t.lang, t.source)), [('zh-TW', LyricSource.youtube), ('zh-TW-x-edit', LyricSource.edited)]);
      expect(back.primaryTrack!.lines.single.text, '乙');
    });
  });

  test('timing offset: saved per track, applied when shown, baked by the editor', () {
    final t = LyricTrack(lang: 'ja', auto: false, lines: const [LyricLine(1, 2, 'a', romaji: 'a')], offset: 0.3);
    final lyrics = Lyrics(tracks: [t, LyricTrack(lang: 'en', auto: false, lines: const [LyricLine(1, 2, 'x')])], primary: 'ja', secondary: 'en');
    final shown = lyrics.shifted();
    expect(shown.primaryTrack!.lines.single.start, closeTo(1.3, 1e-9));
    expect(shown.primaryTrack!.lines.single.romaji, 'a');
    expect(shown.primaryTrack!.offset, 0); // not applied twice
    expect(shown.secondaryTrack!.lines.single.start, 1); // its own offset: none
    expect(t.lines.single.start, 1); // the saved lines are unchanged
    final back = Lyrics.fromJson(jsonDecode(jsonEncode(lyrics.toJson())) as Map<String, dynamic>);
    expect(back.primaryTrack!.offset, 0.3);
    expect(back.track('en')!.toJson().containsKey('offset'), isFalse);
    final none = Lyrics(tracks: [LyricTrack(lang: 'ja', auto: false, lines: const [])]);
    expect(identical(none.shifted(), none), isTrue);
  });
}
