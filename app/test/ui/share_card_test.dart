import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/state/scoring_bridge.dart';
import 'package:karaoke_battle/ui/results/new_record_dialog.dart';

void main() {
  testWidgets('share card renders at 1080x1080 and the post text has the link', (tester) async {
    I18n.notifier.value = 'zh';
    final song = Song(id: 'x', title: '【歌ってみた】食虫植物 / covered by 多帕 Topa', sourceType: SourceType.youtube, createdAt: DateTime(2026, 10, 29));
    final score = ScoreData.fromJson({
      'total': 96.2,
      'rank': 'SS',
      'raw_total': 93.1,
      'scale': 2,
      'sub_scores': {
        'pitch': {'value': 0.96}, 'rhythm': {'value': 0.91}, 'stability': {'value': 0.88},
        'vibrato': {'value': null}, 'expression': {'value': 0.82}, 'long_tone': {'value': 0.97},
      },
    });
    // Real thumbnails are not decoded in widget tests (no real image codec
    // loop), so the card is rendered without one here.
    const String? thumb = null;
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Center(child: RepaintBoundary(key: key, child: ShareCard(song: song, score: score, thumbPath: thumb, date: DateTime(2026, 10, 29), badge: tr('share.newRecord')))),
    ));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    expect(boundary.size, const Size(ShareCard.size, ShareCard.size));
    final out = Platform.environment['KE_TEST_CARD_OUT'];
    if (out != null) {
      await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 1080 / ShareCard.size);
        expect(img.width, 1080);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        await File(out).writeAsBytes(data!.buffer.asUint8List());
      });
    }
    final text = shareText(song, score);
    expect(text, contains('96.2'));
    expect(text, contains('SS'));
    expect(text, contains('/releases/latest'));
    expect(shareText(song, score, newRecord: false), isNot(contains('刷新')));
  });
}
