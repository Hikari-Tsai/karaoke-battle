// "Export replay": asks for the player name and whether to include the voice
// recording, then saves a .json replay file someone else can import.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';

/// File name suggested in the save dialog: `<title> <score>.json` without
/// characters file systems reject.
String replayFileName(String title, double? total) {
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final base = safe.isEmpty ? 'replay' : (safe.length > 80 ? safe.substring(0, 80).trim() : safe);
  return total == null ? '$base.json' : '$base ${total.toStringAsFixed(1)}.json';
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
  bool _voice = true;
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
      final text = await services.replays.export(
        song: widget.song,
        files: services.library.files(widget.song),
        take: widget.take,
        player: player,
        includeVoice: _voice,
      );
      final uri = await FilePicker.saveFile(
        dialogTitle: tr('export.saveTitle'),
        fileName: replayFileName(widget.song.title, widget.take.total),
        bytes: Uint8List.fromList(utf8.encode(text)),
        mimeType: 'application/json',
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
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: hasVoice && _voice,
              onChanged: !hasVoice || _busy ? null : (v) => setState(() => _voice = v ?? true),
              title: Text(tr('export.includeVoice')),
              subtitle: Text(tr(hasVoice ? 'export.includeVoiceHint' : 'export.noVoice')),
            ),
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
