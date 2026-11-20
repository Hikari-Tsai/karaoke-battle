import 'package:flutter/widgets.dart';

/// The text field that holds keyboard focus, or null.
///
/// A TextField's focus node is attached by a [Focus] that [EditableText]
/// builds, so the focused context is a [Focus] below the [EditableTextState],
/// never the [EditableText] itself.
EditableTextState? focusedTextField() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  if (ctx is StatefulElement && ctx.state is EditableTextState) return ctx.state as EditableTextState;
  return ctx.findAncestorStateOfType<EditableTextState>();
}

/// Whether an input method (Zhuyin, Pinyin, Japanese, ...) is in the middle of
/// composing in [field]: Enter, Space and Esc then belong to the input method.
bool isComposing(EditableTextState field) {
  final c = field.widget.controller.value.composing;
  return c.isValid && !c.isCollapsed;
}
