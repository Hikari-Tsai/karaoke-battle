import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/scoring.dart';
import 'package:karaoke_battle/services/items.dart';
import 'package:karaoke_battle/state/scoring_bridge.dart';
import 'package:karaoke_battle/state/tuning_wand.dart';
import 'package:path/path.dart' as p;

void main() {
  test('perfect spans: the note sung as the reference, in the singer\'s octave, at the judged time', () {
    final ref = [for (var i = 0; i < 20; i++) i < 5 ? double.nan : 60.0];
    // Sung an octave down, 2 frames late, and a little flat from frame 12.
    final take = [for (var i = 0; i < 22; i++) i < 7 ? double.nan : (i < 12 ? 48.0 : 48.3)];
    final out = Scorer.applyPerfectSpans(take, ref, [(0.08, 0.32)], hop: 0.016, offsetFrames: 2, calibratedTiming: false);
    // Note frames 5..19 of the reference land on take frames 7..21.
    expect(out.sublist(7, 22), everyElement(48.0));
    expect(out[5].isNaN && out[6].isNaN, isTrue, reason: 'the reference is silent there');
    // With a trusted clock the note goes where the track clock puts it.
    final clock = Scorer.applyPerfectSpans(take, ref, [(0.08, 0.32)], hop: 0.016, offsetFrames: 2, calibratedTiming: true);
    expect(clock.sublist(5, 20), everyElement(48.0));
  });

  test('the bridge scores wand notes as perfect and keeps the list in the score', () async {
    final dir = Directory.systemTemp.createTempSync('wand');
    addTearDown(() => dir.deleteSync(recursive: true));
    String path(String n) => p.join(dir.path, n);
    // Four notes, a second each; the singer gets the third one wrong (a tritone off, late).
    final notes = [for (var i = 0; i < 4; i++) {'onset': i * 1.0 + 0.5, 'offset': i * 1.0 + 1.3, 'pitch': 60.0 + i * 2}];
    File(path('notes.json')).writeAsStringSync(jsonEncode({'notes': notes}));
    const hop = 0.016;
    final times = <double>[], f0 = <double>[], conf = <double>[];
    for (var t = 0.0; t < 5; t += hop) {
      times.add(t);
      double? m;
      for (final (i, n) in notes.indexed) {
        final on = (n['onset'] as double) + (i == 2 ? 0.25 : 0), off = n['offset'] as double;
        if (t >= on && t < off) m = (n['pitch'] as double) + (i == 2 ? 6 : 0);
      }
      f0.add(m == null ? 0 : 440 * math.pow(2, (m - 69) / 12).toDouble());
      conf.add(m == null ? 0 : 0.9);
    }
    File(path('take_f0.json')).writeAsStringSync(jsonEncode({'hop': hop, 'times': times, 'f0': f0, 'confidence': conf}));
    Future<ScoreData> score() => ScoringBridge.scoreAndSave(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('none.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), octaveInvariant: true, calibratedTiming: true);
    int perfect(ScoreData s) => ((s.raw['rhythm'] as Map)['counts'] as Map)['perfect'] as int;
    final plain = await score();
    expect(perfect(plain), 3);
    expect(wandUsesOfScore(plain.raw), isEmpty);
    await TakeWand([WandUse(onset: 2.5, offset: 3.3, pitch: 64, at: DateTime(2026, 11, 24))]).save(dir.path);
    final tuned = await score();
    expect(perfect(tuned), 4, reason: 'the third note is perfect now');
    expect(tuned.total, greaterThan(plain.total));
    expect(wandUsesOfScore(tuned.raw).single.isNote(2.5), isTrue, reason: 'the score carries where the wand was used');
    expect((await TakeWand.load(dir.path)).hasNote(2.5), isTrue);
  });

  test('the Resonance Field judges the whole take twice as leniently', () async {
    final dir = Directory.systemTemp.createTempSync('field');
    addTearDown(() => dir.deleteSync(recursive: true));
    String path(String n) => p.join(dir.path, n);
    // Six notes, sung 0.8 semitones sharp and flat in turn (no key change
    // fits them all) and 90 ms late.
    final notes = [for (var i = 0; i < 6; i++) {'onset': i * 1.0 + 0.5, 'offset': i * 1.0 + 1.3, 'pitch': 60.0 + i}];
    File(path('notes.json')).writeAsStringSync(jsonEncode({'notes': notes}));
    const hop = 0.016;
    final times = <double>[], f0 = <double>[], conf = <double>[];
    for (var t = 0.0; t < 7; t += hop) {
      times.add(t);
      double? m;
      for (final (i, n) in notes.indexed) {
        if (t >= (n['onset'] as double) + 0.09 && t < (n['offset'] as double)) m = (n['pitch'] as double) + (i.isEven ? 0.8 : -0.8);
      }
      f0.add(m == null ? 0 : 440 * math.pow(2, (m - 69) / 12).toDouble());
      conf.add(m == null ? 0 : 0.9);
    }
    File(path('take_f0.json')).writeAsStringSync(jsonEncode({'hop': hop, 'times': times, 'f0': f0, 'confidence': conf}));
    Future<ScoreData> score() => ScoringBridge.scoreAndSave(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('none.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), octaveInvariant: true, calibratedTiming: true);
    Map counts(ScoreData s) => (s.raw['rhythm'] as Map)['counts'] as Map;
    final plain = await score();
    expect(plain.subScores['pitch'], lessThan(70), reason: '0.8 semitones off is out of tune');
    expect(counts(plain)['perfect'], 0, reason: '90 ms late is a GREAT');
    expect(fieldOfScore(plain.raw), isFalse);
    await TakeField.mark(dir.path, DateTime(2026, 11, 24));
    final field = await score();
    expect(field.subScores['pitch'], greaterThan(90), reason: 'within a semitone now');
    expect(counts(field)['perfect'], 6, reason: '90 ms is within the doubled PERFECT window');
    expect(field.total, greaterThan(plain.total + 10));
    expect(fieldOfScore(field.raw), isTrue, reason: 'the score says it was sung in the field');
    expect(RhythmWindows.forTempo(120).widened(2).perfect, closeTo(0.1, 1e-9));
  });

  test('items: redeemed with the points earned, used up one at a time, saved', () async {
    final dir = Directory.systemTemp.createTempSync('items');
    addTearDown(() => dir.deleteSync(recursive: true));
    final earned = ValueNotifier(30);
    final items = ItemService(dataRoot: dir.path, earnedPoints: () => earned.value, points: earned);
    await items.start();
    expect(items.balance, 30);
    expect(await items.redeem(ItemKind.tuningWand), isTrue);
    expect(items.balance, 5);
    expect(await items.redeem(ItemKind.tuningWand), isFalse, reason: 'not enough points');
    var told = 0;
    items.addListener(() => told++);
    earned.value = 55;
    expect(told, 1, reason: 'new points show at once');
    expect(items.balance, 30);
    expect(await items.consume(ItemKind.tuningWand), isTrue);
    expect(await items.consume(ItemKind.tuningWand), isFalse, reason: 'none left');
    final again = ItemService(dataRoot: dir.path, earnedPoints: () => earned.value, points: earned);
    await again.start();
    expect((again.spent, again.ownedOf(ItemKind.tuningWand), again.usedOf(ItemKind.tuningWand)), (25, 0, 1));
    // 開發模式 sets them directly.
    await again.setBalance(500);
    await again.setOwned(ItemKind.tuningWand, 3);
    expect((again.balance, again.earned, again.ownedOf(ItemKind.tuningWand)), (500, 55, 3));
  });
}
