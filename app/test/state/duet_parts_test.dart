// Duet parts: verses back and forth, choruses A B then together.
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/duet_parts.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/song_data.dart';

const a = DuetPart.a, b = DuetPart.b, c = DuetPart.both;

/// Lines of 4 s with 0.5 s between, starting at [from]; a gap of 8 s
/// between [texts] groups.
List<LyricLine> song(List<List<String>> sections) {
  final out = <LyricLine>[];
  var t = 10.0;
  for (final sec in sections) {
    for (final text in sec) {
      out.add(LyricLine(t, t + 4, text));
      t += 4.5;
    }
    t += 8;
  }
  return out;
}

const verse1 = ['走在無人的街道上', '路燈一盞一盞亮起', '想起那年夏天的你', '笑著說要去遠方'];
const verse2 = ['翻開泛黃的日記本', '字跡早已模糊不清', '窗外下著綿綿細雨', '我還在原地等待'];
const chorus3 = ['我們唱吧大聲唱吧', '把所有煩惱都忘掉', '直到天亮也不停'];
const chorus5 = ['飛向那遙遠的天空', '帶著所有夢想出發', '風吹過我們的臉龐', '一起走過每個季節', '永遠不說再見'];

void main() {
  test('verses go back and forth, choruses are A, B, then together', () {
    final lines = song([verse1, chorus3, verse2, chorus3]);
    final plan = planDuet(lines);
    expect(plan.parts.sublist(0, 4), [a, b, a, b]);
    expect(plan.sections.sublist(4, 7), everyElement(DuetSection.chorus));
    expect(plan.parts.sublist(4, 7), [a, b, c]);
    expect(plan.sections.sublist(7, 11), everyElement(DuetSection.verse));
    expect(plan.parts.sublist(11, 14), [a, b, c]);
  });

  test('a five-phrase chorus is A B C C C', () {
    final plan = planDuet(song([verse1, chorus5, verse2, chorus5]));
    expect(plan.parts.sublist(4, 9), [a, b, c, c, c]);
    expect(plan.parts.sublist(13, 18), [a, b, c, c, c]);
  });

  test('a long chorus is dealt in even pieces of at most five', () {
    final long = [...chorus5, ...chorus3, '心跳跟著節拍跳動', '這一刻屬於我們', '再唱一遍給你聽', '最後一句輕輕唱'];
    final plan = planDuet(song([verse1, long, verse2, long]));
    expect(plan.parts.sublist(4, 16), [a, b, c, c, a, b, c, c, a, b, c, c]);
  });

  test('a verse starts with whoever has sung less, so the parts come out even', () {
    final plan = planDuet(song([verse1, chorus5, ['只有一句'], verse2, chorus5]));
    // After the first verse (A 8 s, B 8 s) and the chorus (A, B one each),
    // the one-line verse goes to A; the next verse then starts with B.
    expect(plan.parts[9], a);
    expect(plan.parts.sublist(10, 14), [b, a, b, a]);
  });

  test('short lines join into one phrase and share a part', () {
    // Half-phrase subtitles: 2 s each, right after one another.
    final lines = [
      for (final (i, t) in ['把沒說的話', '都寫成旋律', '把每個音符', '都藏著絮語'].indexed) LyricLine(10.0 + 2 * i, 12.0 + 2 * i, t),
    ];
    final plan = planDuet(lines);
    expect(plan.phrases, [0, 0, 1, 1]);
    expect(plan.parts, [a, a, b, b]);
  });

  test('a singer sings their own lines and the together ones', () {
    final plan = planDuet(song([verse1, chorus3, verse2, chorus3]));
    expect(plan.linesOf(a), containsAll([0, 2, 4, 6]));
    expect(plan.linesOf(a), isNot(contains(1)));
    expect(plan.linesOf(b), containsAll([1, 3, 5, 6]));
    expect(c.sungBy(a) && c.sungBy(b), isTrue);
  });

  test('the music\'s level tips a stretch that comes back less often than the chorus', () {
    const pre = ['心裡有一句話', '一直沒有說出口'];
    // The chorus comes back three times, the pre-chorus twice.
    final lines = song([verse1, [...pre, ...chorus3], verse2, [...pre, ...chorus3], chorus3]);
    bool preIsChorus(List<double?>? loud) {
      final plan = planDuet(lines, loudness: loud);
      return plan.sections[4] == DuetSection.chorus && plan.sections[5] == DuetSection.chorus;
    }

    expect(preIsChorus(null), isFalse, reason: 'half as repeated as the chorus');
    final loud = [for (final l in lines) pre.contains(l.text) || chorus3.contains(l.text) ? -8.0 : -20.0];
    expect(preIsChorus(loud), isTrue, reason: 'as loud as the chorus');
    expect(planDuet(song([verse1, chorus5]), loudness: [for (var i = 0; i < 9; i++) i < 4 ? -20.0 : -8.0]).sections, everyElement(DuetSection.verse),
        reason: 'loud alone, never repeated, is not enough');
  });

  test('the parts over time join a part\'s lines', () {
    final lines = song([verse1, chorus3, verse2, chorus3]);
    final spans = planDuet(lines).spans(lines);
    expect([for (final x in spans.take(7)) x.part], [a, b, a, b, a, b, c]);
    expect(spans.first.start, lines.first.start);
  });

  test('a part is judged without the other part\'s notes', () {
    final lines = song([verse1, chorus3, verse2, chorus3]);
    final plan = planDuet(lines);
    // One note in the middle of each line, and one between lines.
    final notesJson = {
      'notes': [
        for (final l in lines) {'onset': l.start + 1, 'offset': l.start + 3, 'pitch': 60},
        {'onset': 5.0, 'offset': 6.0, 'pitch': 62},
      ],
      'excluded_spans': [
        [1.0, 2.0],
      ],
    };
    final notes = NoteList.fromJson(notesJson);
    final drop = partnerNotes(notes, lines, plan, a);
    // B's lines (1, 3, 5 ...) go; A's, the together line and the stray note stay.
    final dropped = {for (final n in drop) lines.indexWhere((l) => l.start + 1 == notes.onset[n])};
    expect(dropped, {for (var i = 0; i < lines.length; i++) if (plan.parts[i] == b) i});
    final j = duetNotesJson(notesJson, lines, plan, a);
    expect((j['notes'] as List).length, (notesJson['notes'] as List).length - drop.length);
    expect((j['excluded_spans'] as List).length, 1 + drop.length);
    expect(j['duet'], 'a');
    // The other part's lines are left out of the reference and the take.
    expect(j['duet_spans'], [
      for (final x in plan.spans(lines))
        if (x.part == b) [x.start, x.end],
    ]);
    expect(partnerNotes(notes, lines, plan, b).intersection(drop), isEmpty);
  });

  test('no lyrics, no parts', () {
    expect(planDuet(const []).length, 0);
  });
}
