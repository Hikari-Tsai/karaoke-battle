// The dialog that comes up by itself when yt-dlp needs fixing: the launch
// check found the app's copy broken or only a PATH copy, or installing or
// updating it failed. It installs (or reinstalls) the app's own copy and
// runs `yt-dlp -U`, with progress, and offers a retry on failure.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/sidecars.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';

enum YtDlpIssue { broken, pathOnly, failed }

/// Shows the dialog for what the launch check found, if anything needs it.
Future<void> showYtDlpLaunchDialog(BuildContext context) async {
  final setup = context.read<SetupController>();
  final settings = context.read<AppServices>().settings;
  switch (setup.ytDlpHealth) {
    case YtDlpHealth.broken:
      await showYtDlpDialog(context, YtDlpIssue.broken, setup.ytDlpDetail);
    case YtDlpHealth.pathOnly when !settings.dismissedYtDlpPathOnly:
      await showYtDlpDialog(context, YtDlpIssue.pathOnly, setup.ytDlpDetail);
    default:
  }
}

/// [detail] is the PATH yt-dlp for [YtDlpIssue.pathOnly], otherwise the error.
Future<void> showYtDlpDialog(BuildContext context, YtDlpIssue issue, String detail) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _YtDlpDialog(issue: issue, detail: detail),
    );

class _YtDlpDialog extends StatefulWidget {
  const _YtDlpDialog({required this.issue, required this.detail});
  final YtDlpIssue issue;
  final String detail;

  @override
  State<_YtDlpDialog> createState() => _YtDlpDialogState();
}

class _YtDlpDialogState extends State<_YtDlpDialog> {
  bool _dontRemind = false;
  ({bool ok, String message})? _result;

  Future<void> _fix() async {
    setState(() => _result = null);
    // A PATH-only setup has no copy of the app's own to throw away.
    final r = await context.read<SetupController>().updateYtDlp(reinstall: widget.issue != YtDlpIssue.pathOnly);
    if (mounted) setState(() => _result = r);
  }

  Future<void> _close() async {
    if (_dontRemind) await context.read<AppServices>().settings.setDismissedYtDlpPathOnly(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final setup = context.watch<SetupController>();
    final theme = Theme.of(context);
    final busy = setup.ytDlpBusy;
    final row = setup.sidecarStates[SidecarKind.ytDlp]!;
    final done = _result?.ok ?? false;
    final body = switch (widget.issue) {
      YtDlpIssue.broken => tr('ytdlp.broken'),
      YtDlpIssue.pathOnly => tr('ytdlp.pathOnly', {'path': widget.detail}),
      YtDlpIssue.failed => tr('ytdlp.failed'),
    };
    final error = _result == null ? (widget.issue == YtDlpIssue.pathOnly ? null : widget.detail) : (done ? null : _result!.message);
    return AlertDialog(
      title: Text(tr('ytdlp.title')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error, maxLines: 6, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ],
            if (busy) ...[
              const SizedBox(height: 12),
              Text(tr('ytdlp.working'), style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: row.installing && row.fraction > 0 ? row.fraction : null),
            ],
            if (done) ...[
              const SizedBox(height: 12),
              Text(tr('ytdlp.done'), style: theme.textTheme.bodyMedium),
              SelectableText(_result!.message, maxLines: 6, style: theme.textTheme.bodySmall),
            ],
            if (widget.issue == YtDlpIssue.pathOnly && !done)
              CheckboxListTile(
                value: _dontRemind,
                onChanged: busy ? null : (v) => setState(() => _dontRemind = v ?? false),
                title: Text(tr('ytdlp.dontRemind')),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
          ],
        ),
      ),
      actions: done
          ? [FilledButton(onPressed: _close, child: Text(tr('close')))]
          : [
              TextButton(onPressed: busy ? null : _close, child: Text(tr('later'))),
              FilledButton(
                onPressed: busy ? null : _fix,
                child: Text(_result != null ? tr('retry') : (widget.issue == YtDlpIssue.pathOnly ? tr('download') : tr('ytdlp.repair'))),
              ),
            ],
    );
  }
}
