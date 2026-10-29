import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/brand.dart';

void main() {
  testWidgets('brand lockup lays out in an app bar without overflow', (tester) async {
    // Optional real font + PNG output for a visual check (KE_TEST_BRAND_OUT).
    final out = Platform.environment['KE_TEST_BRAND_OUT'];
    final fontPath = Platform.environment['KE_TEST_BRAND_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        final loader = FontLoader('BrandTest')..addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
        await loader.load();
      });
    }
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, fontFamily: fontPath == null ? null : 'BrandTest'),
      home: Scaffold(
        appBar: AppBar(title: const BrandedTitle('Library')),
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 900,
              height: 64,
              child: AppBar(
                title: const BrandedTitle('Library'),
                actions: [Padding(padding: const EdgeInsets.only(right: 12), child: FilledButton.icon(onPressed: () {}, icon: const Icon(Icons.add), label: const Text('Add song')))],
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.runAsync(() => precacheImage(const AssetImage('assets/images/app_icon.png'), tester.element(find.byType(BrandLockup).first)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('KARAOKE'), findsNWidgets(2));
    if (out != null) {
      await tester.runAsync(() async {
        final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await b.toImage(pixelRatio: 2);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        await File(out).writeAsBytes(data!.buffer.asUint8List());
      });
    }
  });
}
