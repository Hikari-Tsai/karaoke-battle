import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/text_focus.dart';

void main() {
  // A page-level key handler like the lyrics editor's: Space / Enter are
  // shortcuts in text fields too, except while an input method is composing.
  Future<(FocusNode, TextEditingController, List<String>)> pump(WidgetTester tester) async {
    final page = FocusNode();
    final c = TextEditingController();
    final fired = <String>[];
    addTearDown(page.dispose);
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Focus(
        focusNode: page,
        autofocus: true,
        onKeyEvent: (_, e) {
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          final field = focusedTextField();
          if (field != null) {
            if (isComposing(field)) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.escape) {
              page.requestFocus();
              return KeyEventResult.handled;
            }
          }
          fired.add(e.logicalKey.debugName ?? '?');
          return KeyEventResult.handled;
        },
        child: Scaffold(body: TextField(controller: c)),
      ),
    ));
    await tester.pump();
    return (page, c, fired);
  }

  testWidgets('shortcuts work in a text field until an input method composes', (tester) async {
    final (page, c, fired) = await pump(tester);
    expect(focusedTextField(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(fired, ['Space']);

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusedTextField(), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(fired, ['Space', 'Enter']);

    // Zhuyin: "ㄏㄠˇ" is being composed; Space / Enter belong to the input method.
    c.value = const TextEditingValue(
      text: '你ㄏㄠˇ',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 1, end: 4),
    );
    await tester.pump();
    expect(isComposing(focusedTextField()!), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(fired, ['Space', 'Enter']);

    // The candidate is picked: Enter stamps again.
    c.value = const TextEditingValue(text: '你好', selection: TextSelection.collapsed(offset: 2));
    await tester.pump();
    expect(isComposing(focusedTextField()!), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(fired, ['Space', 'Enter', 'Enter']);

    // Esc leaves the field.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(page.hasPrimaryFocus, isTrue);
  });

  testWidgets('Esc while an input method is composing stays in the field', (tester) async {
    final (page, c, fired) = await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    c.value = const TextEditingValue(
      text: '你ㄏㄠˇ',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 1, end: 4),
    );
    await tester.pump();
    expect(isComposing(focusedTextField()!), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(page.hasPrimaryFocus, isFalse);
    expect(focusedTextField(), isNotNull);
    expect(fired, isEmpty);
  });
}
