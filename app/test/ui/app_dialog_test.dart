// AppDialog: the X, a click outside and Esc all close it as its cancel
// button does; nothing closes it while it cannot be cancelled.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/app_dialog.dart';

void main() {
  late Object? result;
  late bool closed;

  Future<void> open(WidgetTester tester, Widget Function(BuildContext) dialog) async {
    result = 'not closed';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async => result = await showDialog<String>(context: context, builder: dialog),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Widget plain(BuildContext context) => AppDialog(
        title: const Text('Title'),
        content: const Text('Body'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, 'ok'), child: const Text('OK'))],
      );

  testWidgets('the X closes with no result', (tester) async {
    await open(tester, plain);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('a click outside closes with no result', (tester) async {
    await open(tester, plain);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('Esc closes with no result', (tester) async {
    await open(tester, plain);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('the X sits left of the title, and of a centred icon', (tester) async {
    await open(tester, plain);
    expect(tester.getCenter(find.byIcon(Icons.close)).dx, lessThan(tester.getTopLeft(find.text('Title')).dx));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await open(tester, (_) => const AppDialog(icon: Icon(Icons.star), title: Text('Title'), content: Text('Body')));
    // The panel itself (the AlertDialog's own box fills the screen).
    final dialog = tester.getRect(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Material)).first);
    final x = tester.getCenter(find.byIcon(Icons.close));
    expect(x.dx, lessThan(dialog.left + 60));
    expect(x.dy, lessThan(tester.getTopLeft(find.text('Title')).dy));
    expect(tester.getCenter(find.byIcon(Icons.star)).dx, closeTo(dialog.center.dx, 1));
  });

  testWidgets('onClose runs instead of popping, for the X and a click outside', (tester) async {
    var calls = 0;
    await open(tester, (context) => AppDialog(title: const Text('Title'), onClose: () => calls++));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(AlertDialog), findsOneWidget); // onClose decides when to pop
  });

  testWidgets('canClose: false keeps it open; its own buttons still close it', (tester) async {
    closed = false;
    await open(
      tester,
      (context) => AppDialog(
        canClose: false,
        onClose: () => closed = true,
        title: const Text('Title'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, 'ok'), child: const Text('OK'))],
      ),
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.tapAt(const Offset(5, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(closed, isFalse);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(result, 'ok');
  });
}
