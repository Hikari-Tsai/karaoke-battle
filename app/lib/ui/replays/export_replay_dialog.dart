// "Export replay": asks for the player name, then saves a .zip holding the
// replay JSON and the dry a cappella vocal, which someone else can import.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';

/// Base name for the exported files: `<title> <score>` without characters
/// file systems reject (and no leading or doubled dots).
String replayBaseName(String title, double? total) {
  var safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\.{2,}'), '.').replaceAll(RegExp(r'\s+'), ' ').trim();
  safe = safe.replaceFirst(RegExp(r'^[.\s]+'), '');
  final base = safe.isEmpty ? 'replay' : (safe.length > 80 ? safe.substring(0, 80).trim() : safe);
  return total == null ? base : '$base ${total.toStringAsFixed(1)}';
}

Future<void> showExportReplayDialog(BuildContext context, {required Song song, required TakeInfo take}) {
  return showDialog<void>(context: context, builder: (_) => _ExportReplayDialog(song: song, take: take));
}

class _ExportReplayDialog extends StatefulWidget {
  const _ExportReplayDialog({required this.song, required this.take});
  final Song song;
  final TakeInfo take;

  @override
  State<_ExportReplayDialog> createState() => _ExportReplayDialogState();
}

class _ExportReplayDialogState extends State<_ExportReplayDialog> {
  late final TextEditingController _name;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: context.read<AppServices>().settings.playerName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final services = context.read<AppServices>();
    final player = _name.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await services.settings.setPlayerName(player);
      final base = replayBaseName(widget.song.title, widget.take.total);
      final zip = await services.replays.export(
        song: widget.song,
        files: services.library.files(widget.song),
        take: widget.take,
        player: player,
        baseName: base,
      );
      final uri = await FilePicker.saveFile(
        dialogTitle: tr('export.saveTitle'),
        fileName: '$base.zip',
        bytes: zip,
        mimeType: 'application/zip',
      );
      if (!mounted) return;
      if (uri == null) {
        setState(() => _busy = false);
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(tr('export.done', {'path': uri.toFilePath()}))));
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
    final hasVoice = File(widget.take.wav).existsSync();
    return AlertDialog(
      title: Text(tr('export.title')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('export.body'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 40,
              decoration: InputDecoration(labelText: tr('export.player'), hintText: tr('export.playerHint'), border: const OutlineInputBorder()),
            ),
            Row(children: [
              Icon(hasVoice ? Icons.folder_zip_outlined : Icons.mic_off, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(tr(hasVoice ? 'export.contents' : 'export.noVoice'), style: theme.textTheme.bodySmall)),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
          label: Text(tr('export.save')),
        ),
      ],
    );
  }
}
