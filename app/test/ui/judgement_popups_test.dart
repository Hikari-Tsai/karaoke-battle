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
}
