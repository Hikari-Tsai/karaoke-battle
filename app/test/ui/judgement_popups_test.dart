import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/judgement_popups.dart';

void main() {
  test('hits pop in large, settle at 1x, then drift up and fade out', () {
    final start = judgementMotion(0.001, miss: false);
    expect(start.scale, greaterThan(1.4));
    final settle = judgementMotion(0.06, miss: false);
    expect(settle.scale, closeTo(0.95, 0.01), reason: 'overshoot below 1');
    final hold = judgementMotion(0.2, miss: false);
    expect(hold.scale, closeTo(1, 1e-9));
    expect(hold.opacity, 1);
    final fading = judgementMotion(0.4, miss: false);
    expect(fading.opacity, inExclusiveRange(0, 1));
    expect(fading.dy, lessThan(hold.dy), reason: 'drifts upwards');
    expect(judgementMotion(JudgementLayer.life + 0.01, miss: false).opacity, 0);
  });

  test('a MISS does not pop and sinks while fading', () {
    final a = judgementMotion(0.01, miss: true);
    final b = judgementMotion(0.4, miss: true);
    expect(a.scale, 1);
    expect(b.dy, greaterThan(a.dy));
    expect(b.opacity, lessThan(a.opacity));
  });

  test('tier styles', () {
    expect(JudgementStyle.of('perfect').label, 'PERFECT');
    expect(JudgementStyle.of('great').label, 'GREAT');
    expect(JudgementStyle.of('good').label, 'GOOD');
    expect(JudgementStyle.of('anything else').label, 'MISS');
  });

  test('pitch tiers by median deviation', () {
    expect(pitchTier(0), 'perfect');
    expect(pitchTier(-15), 'perfect');
    expect(pitchTier(25), 'great');
    expect(pitchTier(-45), 'good');
    expect(pitchTier(60), 'miss');
    expect(worseTier('perfect', 'good'), 'good');
    expect(worseTier('miss', 'perfect'), 'miss');
  });

  test('a note on time but off key cannot show PERFECT', () {
    final m = JudgementMark.forNote(time: 1, midi: 60, timing: 'perfect', onsetErrorMs: 5, cents: -40);
    expect(m.tier, 'good');
    expect(m.high, isFalse, reason: 'flat -> LOW');
    expect(m.fast, isNull, reason: 'timing was PERFECT, no FAST/LATE');
  });

  test('in tune keeps the timing tier and shows only FAST/LATE', () {
    final m = JudgementMark.forNote(time: 1, midi: 60, timing: 'great', onsetErrorMs: 80, cents: 8);
    expect(m.tier, 'great');
    expect(m.fast, isFalse, reason: 'late');
    expect(m.high, isNull);
  });

  test('both tags when early and sharp; no pitch data keeps the timing tier', () {
    final m = JudgementMark.forNote(time: 1, midi: 60, timing: 'good', onsetErrorMs: -120, cents: 35);
    expect(m.tier, 'good');
    expect(m.fast, isTrue);
    expect(m.high, isTrue);
    final silent = JudgementMark.forNote(time: 1, midi: 60, timing: 'miss');
    expect(silent.tier, 'miss');
    expect(silent.fast, isNull);
    expect(silent.high, isNull);
  });
}
