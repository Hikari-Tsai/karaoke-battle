// "AI analysis": builds a Markdown file with instructions and this take's
// analysis that the user copies or saves and gives to an AI assistant of
// their choice. Nothing is sent anywhere by the app.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../advice/advice_prompt.dart';
import '../../advice/take_analysis.dart';
import '../../advice/take_analysis_loader.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../replays/export_replay_dialog.dart' show replayBaseName;
import '../widgets/error_report.dart';

Future<void> showAiAnalysisDialog(BuildContext context, {required Song song, required TakeInfo take}) {
  return showDialog<void>(context: context, builder: (_) => _AiAnalysisDialog(song: song, take: take));
}

class _AiAnalysisDialog extends StatefulWidget {
  const _AiAnalysisDialog({required this.song, required this.take});
  final Song song;
  final TakeInfo take;

  @override
  State<_AiAnalysisDialog> createState() => _AiAnalysisDialogState();
}

class _AiAnalysisDialogState extends State<_AiAnalysisDialog> {
  TakeAnalysis? _analysis;
  String _appVersion = '';
  bool _includeTitle = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final input = await loadTakeAnalysisInput(
        library: services.library,
        song: widget.song,
        take: widget.take,
        ownRangeKeys: services.settings.ownRangeKeys,
      );
      final analysis = analyzeTake(input);
      var version = '';
      try {
        version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _appVersion = version;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _markdown() => buildAdvicePrompt(_analysis!, lang: I18n.lang, includeTitle: _includeTitle, appVersion: _appVersion);

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: _markdown()));
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger?.showSnackBar(SnackBar(content: Text(tr('advice.copied'))));
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final base = replayBaseName(_includeTitle ? widget.song.title : 'Karaoke Battle', widget.take.total);
      final uri = await FilePicker.saveFile(
        dialogTitle: tr('advice.saveTitle'),
        fileName: '$base AI.md',
        bytes: Uint8List.fromList(utf8.encode(_markdown())),
        mimeType: 'text/markdown',
      );
      if (!mounted) return;
      if (uri == null) {
        setState(() => _busy = false);
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(tr('advice.saved', {'path': uri.toFilePath()}))));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _analysis != null && !_busy;
    return AlertDialog(
      title: Text(tr('advice.title')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('advice.steps'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text(tr('advice.tokens'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
            ]),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _includeTitle,
              onChanged: _busy ? null : (v) => setState(() => _includeTitle = v ?? true),
              title: Text(tr('advice.includeTitle')),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            if (_analysis == null && _error == null) const LinearProgressIndicator(),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null && !_busy) ReportBugButton(error: _error!, where: 'ai analysis'),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
        OutlinedButton.icon(
          onPressed: ready ? _copy : null,
          icon: const Icon(Icons.copy),
          label: Text(tr('advice.copy')),
        ),
        FilledButton.icon(
          onPressed: ready ? _save : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
          label: Text(tr('advice.save')),
        ),
      ],
    );
  }
}
