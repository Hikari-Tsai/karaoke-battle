// Every dialog in the app is an AppDialog: an AlertDialog with an X in its
// top-left corner. The X, a click outside the dialog and Esc all close it the
// same way, as its cancel button does.
import 'package:flutter/material.dart';

import '../../state/i18n.dart';

class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.icon,
    this.title,
    this.content,
    this.actions,
    this.contentPadding,
    this.scrollable = false,
    this.onClose,
    this.canClose = true,
  });

  final Widget? icon;
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? contentPadding;
  final bool scrollable;

  /// What closing does when it is more than popping the dialog with no
  /// result, e.g. stopping the work in progress: whatever the dialog's cancel
  /// button does at the moment. It is then also up to this to pop.
  final VoidCallback? onClose;

  /// False while the dialog cannot be cancelled (its cancel button is greyed
  /// out, e.g. a step that must finish): the X is greyed out too and clicks
  /// outside and Esc do nothing.
  final bool canClose;

  @override
  Widget build(BuildContext context) {
    final close = IconButton(
      tooltip: tr('close'),
      visualDensity: VisualDensity.compact,
      onPressed: canClose ? () => Navigator.maybePop(context) : null,
      icon: const Icon(Icons.close),
    );
    Widget? icon = this.icon;
    Widget? title = this.title;
    EdgeInsetsGeometry? iconPadding;
    EdgeInsetsGeometry? titlePadding;
    if (icon != null) {
      // The icon stays centred above the title, the X beside it on the left.
      icon = Stack(alignment: Alignment.center, children: [
        icon,
        Align(alignment: AlignmentDirectional.centerStart, child: close),
      ]);
      iconPadding = EdgeInsets.fromLTRB(12, 12, 12, title != null ? 12 : (content != null ? 0 : 24));
    } else {
      title = Row(children: [
        close,
        if (title != null) ...[const SizedBox(width: 4), Expanded(child: title)],
      ]);
      titlePadding = EdgeInsets.fromLTRB(12, 12, 24, content == null ? 20 : 0);
    }
    final dialog = AlertDialog(
      icon: icon,
      iconPadding: iconPadding,
      title: title,
      titlePadding: titlePadding,
      content: content,
      contentPadding: contentPadding,
      actions: actions,
      scrollable: scrollable,
    );
    if (onClose == null && canClose) return dialog;
    // Esc and clicks outside ask to pop the dialog (maybePop), as does the X.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && canClose) onClose?.call();
      },
      child: dialog,
    );
  }
}
