// Error messages with a "Report bug" link: it opens the GitHub issue form with
// the version, OS, graphics card, the error and the recent log filled in
// (services/problem_report.dart). Each error is written to the app log when
// it is shown.
import 'package:flutter/material.dart';

import '../../services/app_log.dart';
import '../../services/problem_report.dart';
import '../../state/i18n.dart';
import 'app_dialog.dart';

/// "Report bug" for [error]; logs the error once when it appears.
class ReportBugButton extends StatefulWidget {
  const ReportBugButton({super.key, required this.error, this.stack, this.where, this.log = true});
  final Object error;
  final StackTrace? stack;

  /// False when the error was logged already (e.g. a saved failure shown
  /// again in a list).
  final bool log;

  /// Where it happened, for the log ("scoring", "export video", ...).
  final String? where;

  @override
  State<ReportBugButton> createState() => _ReportBugButtonState();
}

class _ReportBugButtonState extends State<ReportBugButton> {
  @override
  void initState() {
    super.initState();
    if (widget.log) AppLog.error(widget.error, widget.stack, widget.where);
  }

  @override
  void didUpdateWidget(ReportBugButton old) {
    super.didUpdateWidget(old);
    if (widget.log && '${old.error}' != '${widget.error}') AppLog.error(widget.error, widget.stack, widget.where);
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => openProblemReport(context, error: widget.error),
        icon: const Icon(Icons.bug_report_outlined, size: 18),
        label: Text(tr('report.bug')),
      );
}

/// The usual error dialog ("Error", the message, Close) with "Report bug".
Future<void> showErrorDialog(BuildContext context, Object error, {StackTrace? stack, String? where, String? title, String? message}) =>
    showDialog<void>(
      context: context,
      builder: (c) => AppDialog(
        title: Text(title ?? tr('error')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 360),
          child: SingleChildScrollView(child: SelectableText(message ?? '$error')),
        ),
        actions: [
          ReportBugButton(error: error, stack: stack, where: where),
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('close'))),
        ],
      ),
    );

/// A snack bar for [error] (text [text], default "Error: …") with "Report
/// bug"; the error is logged.
/// Pass [messenger] when [context] may be gone by now.
void showErrorSnack(BuildContext context, Object error, {String? text, StackTrace? stack, String? where, ScaffoldMessengerState? messenger}) {
  AppLog.error(error, stack, where);
  messenger ??= ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(SnackBar(
    content: Text(text ?? '${tr('error')}: $error'),
    duration: const Duration(seconds: 8),
    persist: false, // an action makes it stay by default
    action: SnackBarAction(label: tr('report.bug'), onPressed: () => openProblemReport(context, error: error)),
  ));
}
