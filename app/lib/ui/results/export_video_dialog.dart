// "Export video": a copyright reminder first, then where to save, then the
// render with progress and a cancel button (see video_export.dart).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../replays/export_replay_dialog.dart' show replayBaseName;
import 'video_export.dart';

Future<void> showExportVideoDialog(BuildContext context, {required Song song, required TakeInfo take}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.copyright, size: 32),
      title: Text(tr('video.copyrightTitle')),
      content: SizedBox(width: 460, child: Text(tr('video.copyrightBody'))),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('video.agree'))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  // Picks the file (an empty placeholder until the video is written).
  final uri = await FilePicker.saveFile(
    dialogTitle: tr('video.saveTitle'),
    fileName: '${replayBaseName(song.title, take.total)}.mp4',
    bytes: Uint8List(0),
    mimeType: 'video/mp4',
  );
  if (uri == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExportVideoDialog(song: song, take: take, outPath: uri.toFilePath()),
  );
}

class _ExportVideoDialog extends StatefulWidget {
  const _ExportVideoDialog({required this.song, required this.take, required this.outPath});
  final Song song;
  final TakeInfo take;
  final String outPath;

  @override
  State<_ExportVideoDialog> createState() => _ExportVideoDialogState();
}

class _ExportVideoDialogState extends State<_ExportVideoDialog> {
  final _cancel = Completer<void>();
  double _fraction = 0;
  String _stage = 'video.preparing';
  String? _error;
  bool _done = false;
  final _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final services = context.read<AppServices>();
    final base = Theme.of(context);
    // The stage is drawn as on the dark sing screen, whatever the app theme.
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: base.colorScheme.primary, brightness: Brightness.dark),
      fontFamily: base.textTheme.bodyMedium?.fontFamily,
    );
    try {
      await exportTakeVideo(
        services: services,
        song: widget.song,
        take: widget.take,
        theme: theme,
        view: View.of(context),
        outPath: widget.outPath,
        player: services.settings.playerName,
        cancel: _cancel.future,
        onProgress: (f, s) {
          if (!mounted) return;
          setState(() {
            _fraction = f;
            _stage = s;
          });
        },
      );
      if (mounted) setState(() => _done = true);
    } on VideoExportCancelled {
      await _removePlaceholder();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      await _removePlaceholder();
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _removePlaceholder() async {
    try {
      final f = File(widget.outPath);
      if (await f.exists() && await f.length() == 0) await f.delete();
    } catch (_) {}
  }

  Future<void> _reveal() async {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', widget.outPath]);
    } else {
      await revealPath(widget.outPath);
    }
  }

  String _eta() {
    if (_fraction < 0.03 || _stage != 'video.rendering') return '';
    final left = _clock.elapsed * ((1 - _fraction) / _fraction);
    final m = left.inMinutes, s = left.inSeconds % 60;
    return tr('video.eta', {'time': m > 0 ? '$m:${s.toString().padLeft(2, '0')}' : '${s}s'});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = !_done && _error == null;
    return AlertDialog(
      title: Text(tr('video.title')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_error != null)
            SelectableText('${tr('error')}: $_error', style: TextStyle(color: theme.colorScheme.error))
          else if (_done)
            Text(tr('video.done', {'path': widget.outPath}))
          else ...[
            Text(tr(_stage)),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: _stage == 'video.rendering' ? _fraction : null),
            const SizedBox(height: 6),
            Row(children: [
              Text('${(_fraction * 100).toStringAsFixed(0)}%', style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(_eta(), style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 8),
            Text(tr('video.keepOpen'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ]),
      ),
      actions: [
        if (busy)
          TextButton(
            onPressed: _cancel.isCompleted ? null : () => setState(() => _cancel.complete()),
            child: Text(_cancel.isCompleted ? tr('library.cancelling') : tr('cancel')),
          )
        else ...[
          if (_done) TextButton.icon(onPressed: _reveal, icon: const Icon(Icons.folder_open), label: Text(tr('video.reveal'))),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('close'))),
        ],
      ],
    );
  }
}
