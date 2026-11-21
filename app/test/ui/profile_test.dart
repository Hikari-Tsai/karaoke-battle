// The profile: the name is the export dialogs' player name, the look is
// saved, and the cartoon singer draws in both looks.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/achievements.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/identity.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/ui/profile/achievements_view.dart' show TierBadge;
import 'package:karaoke_battle/ui/profile/profile_screen.dart';
import 'package:karaoke_battle/ui/widgets/info_tip.dart';
import 'package:karaoke_battle/ui/profile/singing_avatar.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the name is the player name; the look is saved', (tester) async {
    SharedPreferences.setMockInitialValues({'flutter.player_name': '家家', 'flutter.dev_mode': false});
    final settings = await AppSettings.load();
    final tmp = Directory.systemTemp.createTempSync('profile');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final paths = AppPaths.forTest(tmp.path);
    final library = SongLibrary(paths);
    final achievements = AchievementService(
      library: library,
      replays: ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({}))),
      settings: settings,
      dataRoot: tmp.path,
      cacheDir: p.join(tmp.path, 'cache'),
    );
    addTearDown(achievements.dispose);
    final identity = IdentityService(dataRoot: tmp.path);
    // Real file IO: outside the test's fake clock.
    await tester.runAsync(() => identity.start(machineId: () async => 'MACHINE-1', os: 'macOS 27.2.1'));
    // An A and an SS so far: the sticker shows the SS.
    File(p.join(tmp.path, 'achievements.json')).writeAsStringSync('{"version": 3, "unlocked": {"firstA": "2026-11-01T00:00:00.000", "rankSS": "2026-11-02T00:00:00.000"}}');
    await tester.runAsync(achievements.start);
    tester.view.physicalSize = const Size(1220, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<SongLibrary>.value(value: library),
        ChangeNotifierProvider<AchievementService>.value(value: achievements),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('家家'), findsOneWidget, reason: 'the export dialogs\' name');
    expect(find.byType(RankSticker), findsOneWidget);
    expect(tester.widget<RankSticker>(find.byType(RankSticker)).rank, 'SS', reason: 'the best rank reached');
    expect(find.text('成就'), findsOneWidget, reason: 'the achievements below');
    expect(find.text(identity.identity!.userId), findsOneWidget, reason: 'the user ID');
    expect(find.textContaining('(macOS 27.2.1)'), findsOneWidget, reason: 'the device with its OS version');
    expect(find.text('這台'), findsOneWidget);
    expect(find.text('麥克風常客'), findsOneWidget);
    expect(find.text('???'), findsNWidgets(5), reason: 'the secret ones, until found');
    // The tier dots switch which tier a card shows, and back.
    expect(find.text('0 / 500'), findsNothing);
    await tester.tap(find.byTooltip('金 · 完成 500 次有評分的演唱'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0 / 500'), findsOneWidget, reason: 'the gold of 500 takes');
    expect(find.text('+100'), findsWidgets);
    await tester.tap(find.byTooltip('金 · 完成 500 次有評分的演唱'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('0 / 500'), findsNothing, reason: 'back to the next tier to reach');
    expect(find.byType(TierBadge), findsNWidgets(3), reason: 'the A, the SS and the name (家家) unlocked, as badges');
    // A circled i explains how a rule is judged; the secrets' only once seen.
    final tips = find.byType(InfoTip).evaluate().length;
    expect(tips, greaterThan(20));
    // Debug builds with 開發模式 on show what the secrets ask for.
    await settings.setDevMode(true);
    await tester.pump();
    expect(find.byType(InfoTip).evaluate().length, tips + 5, reason: 'the five secrets\' notes show too');
    expect(find.text('???'), findsNothing);
    expect(find.text('夜貓子'), findsOneWidget);
    expect(find.text('開發模式'), findsNWidgets(5), reason: 'marked as seen only in 開發模式');
    await settings.setDevMode(false);
    await tester.pump();
    expect(find.byType(SingingAvatar), findsNWidgets(1 + AvatarKind.values.length), reason: 'the singer and the look picker');

    await tester.tap(find.text('貓咪'));
    await tester.pump();
    expect(settings.avatarKind, 'cat');

    // The pen opens the name for editing; Enter saves it.
    await tester.tap(find.byTooltip('編輯名稱'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '夏語遙');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(settings.playerName, '夏語遙', reason: 'saved for the exports');
    expect(find.byType(TextField), findsNothing, reason: 'back to the big name');
    expect(find.text('夏語遙'), findsOneWidget);
  });

  testWidgets('every look draws, animated and still', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Wrap(children: [
        for (final k in AvatarKind.values) ...[
          SingingAvatar(kind: k, size: 120),
          SingingAvatar(kind: k, size: 44, headOnly: true, animated: false),
        ],
      ]),
    ));
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
    expect(avatarKindOf('rabbit'), AvatarKind.rabbit);
    expect(avatarKindOf('male'), AvatarKind.male, reason: 'the saved looks so far');
    expect(avatarKindOf('anything else'), AvatarKind.female);
  });
}
