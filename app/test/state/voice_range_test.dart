import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/state/voice_range.dart';

void main() {
  // [pitch, seconds] pairs laid end to end.
  NoteList melody(List<(double, double)> notes) {
    final on = <double>[], off = <double>[], p = <double>[];
    var t = 0.0;
    for (final (pitch, d) in notes) {
      on.add(t);
      off.add(t + d);
      p.add(pitch);
      t += d;
    }
    return NoteList(Float64List.fromList(on), Float64List.fromList(off), Float64List.fromList(p));
  }

  test('a female pop melody (A3..C5) suits a female voice and is high for a male one', () {
    final r = SongRange.of(melody([(57, 2), (60, 4), (64, 4), (67, 4), (69, 3), (72, 1)]));
    expect(r.verdict(VoiceZone.female, 0).fit, RangeFit.fits);
    final male = r.verdict(VoiceZone.male, 0);
    expect(male.fit, RangeFit.high);
    expect(male.bySemitones, greaterThanOrEqualTo(2));
    expect(r.bestShift(VoiceZone.female), 0);
    final down = r.bestShift(VoiceZone.male);
    expect(down, lessThan(0));
    expect(r.verdict(VoiceZone.male, down.toDouble()).fit, RangeFit.fits, reason: 'the AI key change fixes it');
  });

  test('a low male melody is low for a female voice; AI moves it up, within ±6', () {
    final r = SongRange.of(melody([(45, 2), (48, 4), (52, 4), (55, 4), (57, 2)]));
    expect(r.verdict(VoiceZone.male, 0).fit, RangeFit.fits);
    expect(r.verdict(VoiceZone.female, 0).fit, RangeFit.low);
    final up = r.bestShift(VoiceZone.female);
    expect(up, greaterThan(0));
    expect(up, lessThanOrEqualTo(SongRange.maxShift));
  });

  test('the tessitura is weighted by time: one short high note does not decide', () {
    final r = SongRange.of(melody([for (var i = 0; i < 10; i++) (60.0, 2.0), (76, 0.2)]));
    expect(r.highest, 76);
    expect(r.high, 60);
    expect(r.verdict(VoiceZone.female, 0).fit, RangeFit.fits);
  });

  test('an empty score is harmless', () {
    final r = SongRange.of(melody([]));
    expect(r.isEmpty, isTrue);
    expect(r.bestShift(VoiceZone.male), 0);
  });

  test('a key that fits is never moved, even with a short note above the range', () {
    // Female tessitura well inside F3..C5, one short D#5 peak.
    final r = SongRange.of(melody([(60, 4), (64, 4), (67, 4), (75, 0.3), (65, 4)]));
    expect(r.verdict(VoiceZone.female, 0).fit, RangeFit.fits);
    expect(r.bestShift(VoiceZone.female), 0);
  });

  test('the AI key does not depend on the key before (male then female = female)', () {
    final r = SongRange.of(melody([(60, 4), (64, 4), (67, 4), (69, 4), (72, 1)]));
    final female = r.bestShift(VoiceZone.female);
    final male = r.bestShift(VoiceZone.male);
    expect(male, isNot(female));
    // The female key fits even from the male key, but AI still answers the same.
    expect(r.verdict(VoiceZone.female, male.toDouble()).fit, RangeFit.fits);
    expect(r.bestShift(VoiceZone.female), female);
  });

  test('when the key does not fit, AI takes the smallest change that fits', () {
    final r = SongRange.of(melody([(64, 4), (67, 4), (69, 4), (71, 4)]));
    final s = r.bestShift(VoiceZone.male);
    expect(r.verdict(VoiceZone.male, s.toDouble()).fit, RangeFit.fits);
    expect(r.verdict(VoiceZone.male, s + 1.0).fit, isNot(RangeFit.fits), reason: 'one key less would not fit');
  });

  test('when nothing in reach fits, AI gets as close as it can', () {
    final r = SongRange.of(melody([(74, 4), (77, 4), (79, 4)])); // far too high for a male voice
    expect(r.bestShift(VoiceZone.male), -SongRange.maxShift);
  });
}
