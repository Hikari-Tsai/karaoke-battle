import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/advice/mentor_relay.dart';
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
    // A dry run with the wand on the third note: its score, nothing written.
    final before = File(path('score.json')).readAsStringSync();
    final preview = await ScoringBridge.scoreAndSave(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('none.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), octaveInvariant: true, calibratedTiming: true,
        previewSpans: [(2.5, 3.3)]);
    expect(perfect(preview), 4, reason: 'as if the wand were used');
    expect(File(path('score.json')).readAsStringSync(), before, reason: 'nothing saved');
    expect(File(TakeWand.pathIn(dir.path)).existsSync(), isFalse);
    await TakeWand([WandUse(onset: 2.5, offset: 3.3, pitch: 64, at: DateTime(2026, 11, 24))]).save(dir.path);
    final tuned = await score();
    expect(perfect(tuned), 4, reason: 'the third note is perfect now');
    expect(tuned.total, preview.total, reason: 'the estimate was the score it gets');
    expect(tuned.total, greaterThan(plain.total));
    expect(wandUsesOfScore(tuned.raw).single.isNote(2.5), isTrue, reason: 'the score carries where the wand was used');
    expect((await TakeWand.load(dir.path)).hasNote(2.5), isTrue);
    // The take as sung is kept beside it, for the AI tips.
    final raw = jsonDecode(File(ScoringBridge.rawScorePath(path('score.json'))).readAsStringSync()) as Map<String, dynamic>;
    expect(((raw['rhythm'] as Map)['counts'] as Map)['perfect'], 3, reason: 'without the wand');
    expect(raw.containsKey('wand'), isFalse);
    await const TakeWand([]).save(dir.path);
    await score();
    expect(File(ScoringBridge.rawScorePath(path('score.json'))).existsSync(), isFalse, reason: 'no items, no second score');
  });

  test('a note left out, and one the original is silent in, are all points with the wand', () async {
    final dir = Directory.systemTemp.createTempSync('wandmiss');
    addTearDown(() => dir.deleteSync(recursive: true));
    String path(String n) => p.join(dir.path, n);
    final notes = [for (var i = 0; i < 4; i++) {'onset': i * 1.0 + 0.5, 'offset': i * 1.0 + 1.3, 'pitch': 60.0 + i}];
    File(path('notes.json')).writeAsStringSync(jsonEncode({'notes': notes}));
    const hop = 0.016;
    double hz(double m) => 440 * math.pow(2, (m - 69) / 12).toDouble();
    // The original: every note, but its pitch not caught in the second half
    // of note 3. The singer: notes 1, 2 and 4, nothing for note 3.
    final times = <double>[], refF0 = <double>[], refC = <double>[], take = <double>[], takeC = <double>[];
    for (var t = 0.0; t < 5; t += hop) {
      times.add(t);
      double? m;
      var idx = -1;
      for (final (i, n) in notes.indexed) {
        if (t >= (n['onset'] as double) && t < (n['offset'] as double)) {
          m = n['pitch'] as double;
          idx = i;
        }
      }
      final refSilent = idx == 2 && t > 3.0;
      refF0.add(m == null || refSilent ? 0 : hz(m));
      refC.add(m == null || refSilent ? 0 : 0.9);
      take.add(m == null || idx == 2 ? 0 : hz(m));
      takeC.add(m == null || idx == 2 ? 0 : 0.9);
    }
    File(path('ref_f0.json')).writeAsStringSync(jsonEncode({'hop': hop, 'times': times, 'f0': refF0, 'confidence': refC}));
    File(path('take_f0.json')).writeAsStringSync(jsonEncode({'hop': hop, 'times': times, 'f0': take, 'confidence': takeC}));
    Future<ScoreData> score() => ScoringBridge.scoreAndSave(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('ref_f0.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), octaveInvariant: true, calibratedTiming: true);
    Map rhythmOf(ScoreData s, int i) => ((s.raw['rhythm'] as Map)['notes'] as List).cast<Map>().firstWhere((n) => n['index'] == i);
    Map perNoteOf(ScoreData s, int i) => ((s.raw['note_metrics'] as Map)['per_note'] as List).cast<Map>().firstWhere((n) => n['index'] == i);
    final plain = await score();
    expect(rhythmOf(plain, 2)['onset'], 'miss', reason: 'not sung');
    // 開發模式: what a wand on each note alone would add.
    final (base, gains) = await ScoringBridge.wandGains(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('ref_f0.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), calibratedTiming: true,
        candidates: [for (final n in notes) (n['onset'] as double, n['offset'] as double)]);
    expect(base, closeTo(plain.total, 1e-6), reason: 'the take without wands');
    expect(gains[2], greaterThan(5), reason: 'the note left out gains the most');
    expect(gains[0].abs(), lessThan(0.5), reason: 'a note sung well gains little');
    expect(gains.every((g) => g >= 0), isTrue, reason: 'a wand never costs');
    // Normalized: the shares fill the way to 100 exactly, and the total with
    // wands is the take without them plus the shares of the notes tuned.
    final weights = WandWeights(key: 'k', base: base, raw: {for (final (i, n) in notes.indexed) WandWeights.onsetKey(n['onset'] as double): gains[i]});
    final shares = weights.shares;
    expect(shares.values.fold<double>(0, (a, b) => a + b), closeTo(100 - base, 1e-9));
    final open = [for (final n in notes) if (shares[WandWeights.onsetKey(n['onset'] as double)]! > WandWeights.minGain) n['onset'] as double];
    expect(weights.totalWith(open), 100.0, reason: 'every note that can gain tuned');
    final third = await ScoringBridge.scoreAndSave(
        notesJsonPath: path('notes.json'), refF0JsonPath: path('ref_f0.json'), takeF0JsonPath: path('take_f0.json'), scoreJsonPath: path('score.json'), octaveInvariant: true, calibratedTiming: true,
        previewSpans: [(2.5, 3.3)], weights: weights);
    expect(third.total, closeTo(base + shares[WandWeights.onsetKey(2.5)]!, 1e-9), reason: 'the total moves by exactly the share shown');
    await TakeWand([WandUse(onset: 2.5, offset: 3.3, pitch: 62, at: DateTime(2026, 11, 24))]).save(dir.path);
    final tuned = await score();
    expect((rhythmOf(tuned, 2)['onset'], rhythmOf(tuned, 2)['offset']), ('perfect', 'perfect'), reason: 'the wand gives it all');
    expect((perNoteOf(tuned, 2)['voiced_fraction'], perNoteOf(tuned, 2)['pitch_coverage'], perNoteOf(tuned, 2)['matched']), (1.0, 1.0, true));
    expect(((tuned.raw['rhythm'] as Map)['counts'] as Map)['miss'], 0);
    expect(tuned.total, greaterThan(plain.total));
    // A wand never costs points, and with every note tuned the take is 100.

    await TakeWand([for (final n in notes) WandUse(onset: n['onset'] as double, offset: n['offset'] as double, pitch: n['pitch'] as double, at: DateTime(2026, 11, 25))]).save(dir.path);
    final all = await score();
    expect((all.total, all.rank), (100.0, 'SSS'), reason: 'every note tuned');
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
    final earned = ValueNotifier(8);
    var now = DateTime(2026, 11, 24, 10);
    ItemService service() => ItemService(dataRoot: dir.path, earnedPoints: () => earned.value, points: earned, clock: () => now);
    final items = service();
    addTearDown(items.dispose);
    await items.start();
    // The start's top-up came before anyone listened: kept for the screen.
    final missed = items.takeMissed();
    expect(missed.single.daily, isTrue);
    expect(missed.single.items[ItemKind.tuningWand], 5);
    expect(items.takeMissed(), isEmpty, reason: 'once');
    final gains = <ItemGain>[];
    final sub = items.gains.listen(gains.add);
    addTearDown(sub.cancel);
    expect((items.ownedOf(ItemKind.tuningWand), items.ownedOf(ItemKind.resonanceField)), (5, 2), reason: 'the day\'s allowance');
    // The Mentor Ticket waits for its relay: none given, none to redeem.
    expect(ItemKind.mentorTicket.available, mentorAvailable);
    if (!mentorAvailable) {
      expect(items.ownedOf(ItemKind.mentorTicket), 0);
      expect(items.canRedeem(ItemKind.mentorTicket), isFalse);
    }
    expect(items.balance, 8, reason: 'the allowance is free');
    expect(await items.redeem(ItemKind.tuningWand), isTrue);
    expect((items.balance, items.ownedOf(ItemKind.tuningWand)), (3, 6));
    await Future<void>.delayed(Duration.zero);
    expect(gains.last.items, {ItemKind.tuningWand: 1}, reason: 'a redeem is celebrated');
    expect((gains.last.cost, gains.last.daily), (5, false));
    expect(await items.redeem(ItemKind.tuningWand), isFalse, reason: 'not enough points');
    var told = 0;
    items.addListener(() => told++);
    earned.value = 55;
    expect(told, 1, reason: 'new points show at once');
    expect(items.balance, 50);
    for (var i = 0; i < 6; i++) {
      expect(await items.consume(ItemKind.tuningWand), isTrue);
    }
    expect(await items.consume(ItemKind.tuningWand), isFalse, reason: 'none left');
    // The next top-up is at 5:00 after this sing day.
    expect(items.nextReset, DateTime(2026, 11, 25, 5));
    now = DateTime(2026, 11, 25, 4, 59);
    await items.refillIfDue();
    expect(items.ownedOf(ItemKind.tuningWand), 0, reason: 'before 5:00 it is still the same sing day');
    now = DateTime(2026, 11, 25, 5);
    await items.refillIfDue();
    expect((items.ownedOf(ItemKind.tuningWand), items.ownedOf(ItemKind.resonanceField)), (5, 2), reason: 'unused fields do not pile up');
    await Future<void>.delayed(Duration.zero);
    expect(gains.last.daily, isTrue);
    expect(gains.last.items, {ItemKind.tuningWand: 5}, reason: 'only what was topped up');
    await items.refillIfDue();
    expect(items.ownedOf(ItemKind.tuningWand), 5, reason: 'once a day');
    // More than the allowance is kept.
    await items.setOwned(ItemKind.tuningWand, 7);
    now = DateTime(2026, 11, 26, 8);
    await items.refillIfDue();
    expect(items.ownedOf(ItemKind.tuningWand), 7);
    final again = service();
    addTearDown(again.dispose);
    await again.start();
    expect((again.spent, again.ownedOf(ItemKind.tuningWand), again.usedOf(ItemKind.tuningWand), again.refilledDay), (5, 7, 6, DateTime(2026, 11, 26)));
    // 開發模式 sets them directly.
    await again.setBalance(500);
    await again.setOwned(ItemKind.tuningWand, 9);
    expect((again.balance, again.earned, again.ownedOf(ItemKind.tuningWand)), (500, 55, 9));
    // The Weakness Glasses: kept, one only.
    await again.setBalance(2000);
    expect(await again.redeem(ItemKind.weaknessGlasses), isTrue);
    expect((again.has(ItemKind.weaknessGlasses), again.canRedeem(ItemKind.weaknessGlasses), again.balance), (true, false, 1500), reason: 'one is all one needs');
    await again.setBalance(500);
    // Several at once: one celebration, used up together.
    final gains2 = <ItemGain>[];
    final sub2 = again.gains.listen(gains2.add);
    addTearDown(sub2.cancel);
    expect(await again.redeemMany(ItemKind.tuningWand, 3), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect((gains2.single.items[ItemKind.tuningWand], gains2.single.cost), (3, 15));
    expect(await again.consumeMany(ItemKind.tuningWand, 13), isFalse, reason: 'only 12 held');
    expect(await again.consumeMany(ItemKind.tuningWand, 12), isTrue);
    expect(again.ownedOf(ItemKind.tuningWand), 0);
    await again.resetTrades();
    expect((again.spent, again.balance, again.usedOf(ItemKind.tuningWand), again.ownedOf(ItemKind.tuningWand), again.ownedOf(ItemKind.resonanceField)), (0, 55, 0, 5, 2),
        reason: 'every trade undone, the day\'s allowance held');
  });
}
