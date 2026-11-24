// The profile: the name is the export dialogs' player name, the look is
// saved, and the cartoon singer draws in both looks.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/achievements.dart';
import 'package:karaoke_battle/services/achievements.dart' as defs show achievements;
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/identity.dart';
import 'package:karaoke_battle/services/items.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/ui/profile/achievements_view.dart' show TierBadge;
import 'package:karaoke_battle/ui/profile/items_view.dart' show ItemsSection;
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
    final items = ItemService.of(tmp.path, achievements);
    addTearDown(items.dispose);
    await tester.runAsync(items.start);
    // Real file IO: outside the test's fake clock.
    await tester.runAsync(() => identity.start(machineId: () async => 'MACHINE-1', os: 'macOS 27.2.1'));
    // An A and an SS so far: the sticker shows the SS.
    File(p.join(tmp.path, 'achievements.json')).writeAsStringSync('{"version": 3, "unlocked": {"firstA": "2026-11-01T00:00:00.000", "rankSS": "2026-11-02T00:00:00.000"}}');
    await tester.runAsync(achievements.start);
    tester.view.physicalSize = const Size(1220, 3400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<SongLibrary>.value(value: library),
        ChangeNotifierProvider<AchievementService>.value(value: achievements),
        ChangeNotifierProvider<IdentityService>.value(value: identity),
        ChangeNotifierProvider<ItemService>.value(value: items),
      ],
      child: const MaterialApp(home: ProfileScreen()),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('家家'), findsOneWidget, reason: 'the export dialogs\' name');
    expect(find.byType(RankSticker), findsOneWidget);
    expect(tester.widget<RankSticker>(find.byType(RankSticker)).rank, 'SS', reason: 'the best rank reached');
    expect(find.text('成就'), findsOneWidget, reason: 'the achievements below');
    // The achievements in figures: unlocked of all, the medals, the latest.
    expect(find.text('成就統計'), findsOneWidget);
    final goals = defs.achievements.fold<int>(0, (a, d) => a + d.thresholds.length);
    expect(find.text('${achievements.unlocked.length} / $goals'), findsOneWidget, reason: 'counted up to the unlocked of all');
    expect(find.text('金牌'), findsOneWidget);
    expect(find.text('銀牌'), findsOneWidget);
    expect(find.text('銅牌'), findsOneWidget);
    expect(find.text('最新解鎖'), findsOneWidget);
    // Items: the points to spend (all earned so far) and the Tuning Wand.
    expect(find.text('我的背包'), findsOneWidget);
    expect(find.text('我的道具'), findsOneWidget);
    expect(find.text('可用點數'), findsOneWidget);
    final earned = achievements.points;
    expect(items.balance, earned);
    expect(find.text('$earned'), findsWidgets, reason: 'the points to spend, counted up');
    expect(find.text('修音魔杖'), findsWidgets);
    await tester.runAsync(() => items.redeem(ItemKind.tuningWand));
    await tester.pump(const Duration(seconds: 2));
    expect(items.balance, earned - ItemKind.tuningWand.cost);
    expect(find.text('× 4'), findsNWidgets(2), reason: 'the day\'s 3 and the one redeemed, in the bag and on its slot');
    expect(find.text('每日 05:00 重置'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('修音魔杖 3 個、共鳴結界 1 個')), findsOneWidget, reason: 'what the reset tops up to, on hover');
    expect(find.text('即將推出'), findsNWidgets(ItemsSection.slots - ItemKind.values.length), reason: 'room kept for the items to come');
    expect(find.text(identity.identity!.userId), findsOneWidget, reason: 'the user ID');
    expect(find.textContaining('(macOS 27.2.1)'), findsOneWidget, reason: 'the device with its OS version');
    expect(find.text('這台'), findsOneWidget);
    expect(find.text('麥克風常客'), findsOneWidget);
    expect(find.text('???'), findsNWidgets(7), reason: 'the secret ones, until found');
    // A tiered goal is a deck of cards: a tier's dot shuffles its card to the
    // top, and again brings back the next tier to reach.
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(find.text('0 / 500'), findsNothing);
    await tester.tap(find.byTooltip('金 · 完成 500 次有評分的演唱'));
    await settle();
    expect(find.text('0 / 500'), findsOneWidget, reason: 'the gold of 500 takes');
    expect(find.text('+100'), findsWidgets);
    await tester.tap(find.byTooltip('金 · 完成 500 次有評分的演唱'));
    await settle();
    expect(find.text('0 / 500'), findsNothing, reason: 'back to the next tier to reach');
    final takesCard = find.ancestor(of: find.text('麥克風常客'), matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_AchievementTile'));
    Finder inCard(String text) => find.descendant(of: takesCard, matching: find.text(text));
    expect(inCard('0 / 10'), findsOneWidget);
    // Dragging the top card off sends it to the back: the silver comes up.
    await tester.drag(inCard('0 / 10'), const Offset(160, 0));
    await settle();
    expect(inCard('0 / 100'), findsOneWidget, reason: 'the next card in the deck');
    expect(inCard('0 / 10'), findsNothing);
    expect(find.byType(TierBadge), findsNWidgets(3), reason: 'the A, the SS and the name (家家) unlocked, as badges');
    // A circled i explains how a rule is judged; the secrets' only once seen.
    final tips = find.byType(InfoTip).evaluate().length;
    expect(tips, greaterThan(20));
    // Debug builds with 開發模式 on show what the secrets ask for.
    await settings.setDevMode(true);
    await tester.pump();
    expect(find.byType(InfoTip).evaluate().length, tips + 7, reason: 'the seven secrets\' notes show too');
    expect(find.text('???'), findsNothing);
    expect(find.text('夜貓子'), findsOneWidget);
    expect(find.text('開發模式'), findsNWidgets(7), reason: 'marked as seen only in 開發模式');
    // 開發模式 sets the points and items: from the button, or a double click.
    expect(find.text('設定點數和道具'), findsOneWidget);
    await tester.tap(find.text('設定點數和道具'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.widgetWithText(TextField, '可用點數'), '999');
    await tester.enterText(find.widgetWithText(TextField, '修音魔杖 持有數量'), '7');
    await tester.tap(find.text('套用'));
    // Each change is saved to the data folder (real file IO), one after another.
    for (var i = 0; i < 12 && items.ownedOf(ItemKind.tuningWand) != 7; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(seconds: 2));
    expect((items.balance, items.ownedOf(ItemKind.tuningWand)), (999, 7));
    expect(items.earned, achievements.points, reason: 'what achievements earned stays');
    await tester.tap(find.text('× 7').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('× 7').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(TextField, '修音魔杖 持有數量'), findsOneWidget, reason: 'a double click opens it too');
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 500));
    // 開發模式 undoes every trade.
    await tester.tap(find.text('重置交易'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('重置'));
    for (var i = 0; i < 12 && items.spent != 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect((items.spent, items.balance), (0, achievements.points));
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
