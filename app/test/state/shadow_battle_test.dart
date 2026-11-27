// Shadow battle: the running in-tune figure both sides race on, and the
// battle kept with a take.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/duet_parts.dart';
import 'package:karaoke_battle/state/live_trace.dart';
import 'package:karaoke_battle/state/shadow_battle.dart';
import 'package:karaoke_battle/state/song_data.dart';

NoteList _notes(List<(double, double)> spans) => NoteList(
      Float64List.fromList([for (final s in spans) s.$1]),
      Float64List.fromList([for (final s in spans) s.$2]),
      Float64List.fromList([for (final _ in spans) 60.0]),
    );

/// Frames every 10 ms from [from] to [to], all of category [cat].
void _sing(LiveTrace t, double from, double to, int cat) {
  for (var x = from; x < to - 1e-9; x += 0.01) {
    t.add(x, 60, 60, 0, cat);
  }
}

void main() {
  test('in-tune share counts the time inside the green band only', () {
    final t = LiveTrace();
    _sing(t, 0, 0.5, PitchCategory.good);
    _sing(t, 0.5, 1.0, PitchCategory.off);
    expect(inTuneShare(t, 0, 1), closeTo(0.5, 0.02));
    // A silent note counts nothing; a gap in the voice is not bridged.
    expect(inTuneShare(t, 2, 3), 0);
    final gap = LiveTrace()
      ..add(0, 60, 60, 0, PitchCategory.good)
      ..add(0.9, 60, 60, 0, PitchCategory.good);
    expect(inTuneShare(gap, 0, 1), closeTo(0.1, 0.01));
  });

  test('the running figure averages the notes that are over', () {
    final notes = _notes([(0, 1), (1, 2), (2, 3)]);
    final t = LiveTrace();
    _sing(t, 0, 1, PitchCategory.good);
    _sing(t, 1, 2, PitchCategory.near);
    final race = RunningAccuracy(notes, t);
    expect(race.at(0.5), isNull);
    expect(race.at(1.0)!.share, closeTo(1, 0.02));
    expect(race.at(2.0)!.share, closeTo(0.5, 0.02));
    // With [settle], a note counts only that long after its end.
    expect(race.at(2.2, settle: 0.5)!.notes, 1);
    // Back to an earlier moment (a static line): only the notes over by then.
    expect(race.at(1.5)!.notes, 1);
    expect(race.at(3.0)!.share, closeTo(1 / 3, 0.02));
  });

  test('a line still being sung is followed as it grows', () {
    final notes = _notes([(0, 1), (1, 2)]);
    final t = LiveTrace();
    final race = RunningAccuracy(notes, t);
    _sing(t, 0, 1, PitchCategory.good);
    expect(race.at(1.0)!.share, closeTo(1, 0.02));
    _sing(t, 1, 2, PitchCategory.good);
    expect(race.at(2.0)!.share, closeTo(1, 0.02));
  });

  test('the battle is kept with the take and decides on the totals', () async {
    final dir = await Directory.systemTemp.createTemp('battle');
    addTearDown(() => dir.delete(recursive: true));
    const rec = BattleRecord(replayId: 'abc', player: '小明', total: 88.4, rank: 'S', subScores: {'pitch': 90, 'vibrato': null});
    await rec.save(dir.path);
    final back = await BattleRecord.load(dir.path);
    expect(back!.player, '小明');
    expect(back.total, 88.4);
    expect(back.subScores, {'pitch': 90.0, 'vibrato': null});
    expect(back.outcome(90), 1);
    expect(back.outcome(80), -1);
    expect(back.outcome(88.41), 0);
    expect(await BattleRecord.load('${dir.path}/none'), isNull);
  });

  test('a duet battle keeps the part the opponent sang', () async {
    final dir = await Directory.systemTemp.createTemp('battle');
    addTearDown(() => dir.delete(recursive: true));
    await const BattleRecord(replayId: 'r', player: 'p', total: 80, rank: 'A', part: DuetPart.b).save(dir.path);
    expect((await BattleRecord.load(dir.path))!.part, DuetPart.b);
    await const BattleRecord(replayId: 'r', player: 'p', total: 80, rank: 'A').save(dir.path);
    expect((await BattleRecord.load(dir.path))!.part, isNull, reason: 'the whole song');
  });
}
