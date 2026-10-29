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
        appBar: AppBar(title: const Text('Library'), actions: const [AppBarBrand()]),
        body: Center(child: RepaintBoundary(key: key, child: const ColoredBox(color: Color(0xFF1B1B22), child: Padding(padding: EdgeInsets.all(12), child: BrandLockup(height: 68))))),
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
