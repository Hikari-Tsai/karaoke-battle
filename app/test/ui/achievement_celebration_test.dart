import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/achievements.dart';
import 'package:karaoke_battle/ui/profile/achievement_celebration.dart';
import 'package:karaoke_battle/ui/profile/achievements_view.dart' show TierBadge;
import 'package:karaoke_battle/ui/widgets/achievement_events.dart';

AchievementDef d(String id) => achievements.firstWhere((a) => a.id == id);

Future<int Function()> show(WidgetTester tester, List<AchievementUnlock> unlocks) async {
  var done = 0;
  await tester.pumpWidget(MaterialApp(home: AchievementCelebration(unlocks: unlocks, onDone: () => done++, autoClose: false)));
  await tester.pump(const Duration(seconds: 2));
  return () => done;
}

void main() {
  testWidgets('one unlock: its name, what it asked for and the points; a click closes it', (tester) async {
    final done = await show(tester, [AchievementUnlock(d('takes'), 2)]);
    expect(find.text('成就解鎖！'), findsOneWidget);
    expect(find.text('麥克風常客'), findsOneWidget);
    expect(find.textContaining('100'), findsWidgets, reason: 'the silver tier asks for 100 takes');
    expect(find.text('+50 點'), findsOneWidget);
    expect(find.byType(TierBadge), findsOneWidget, reason: 'the tier as a badge, not a word');
    await tester.tapAt(const Offset(20, 20));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(done(), 1);
  });

  testWidgets('several unlocks share one screen, the rest counted; Esc closes it', (tester) async {
    final list = [for (final id in ['firstSong', 'firstTake', 'calibrated', 'wholeSong', 'keyChange', 'named', 'lyrics']) AchievementUnlock(d(id), 1)];
    final done = await show(tester, list);
    expect(find.text('解鎖 7 個成就！'), findsOneWidget);
    expect(find.text('第一首歌'), findsOneWidget);
    expect(find.text('報上名來'), findsNothing, reason: 'only the first five are shown');
    expect(find.text('還有 2 個成就解鎖'), findsOneWidget);
    expect(find.text('+70 點'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(done(), 1);
  });

  test('a hold lasts until every screen holding it lets go', () {
    final a = Object(), b = Object();
    AchievementHold.add(a);
    AchievementHold.add(b);
    AchievementHold.remove(a);
    expect(AchievementHold.active, isTrue);
    AchievementHold.remove(b);
    expect(AchievementHold.active, isFalse);
  });
}
