// Saves one of a song's subtitle tracks as an SRT or LRC file.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import 'lyrics_actions.dart';
import '../widgets/app_dialog.dart';

/// Asks which track and format, then where to save. Says so when the song
/// has no subtitles.
Future<void> exportLyrics(BuildContext context, Song song) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final lyrics = await context.read<AppServices>().pipeline.loadLyrics(song);
  final tracks = [for (final t in lyrics.tracks) if (t.lines.any((l) => l.text.trim().isNotEmpty)) t];
  if (tracks.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text(tr('lyrics.exportNone'))));
    return;
  }
  if (!context.mounted) return;
  final choice = await showDialog<(LyricTrack, String)>(
    context: context,
    builder: (_) => _ExportLyricsDialog(tracks: tracks, primary: lyrics.primary),
  );
  if (choice == null) return;
  final (track, format) = choice;
  final name = song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final uri = await FilePicker.saveFile(fileName: '$name.$format', bytes: utf8.encode(exportSubtitles(track, format)));
  if (uri == null) return;
  messenger?.showSnackBar(SnackBar(content: Text(tr('lyrics.editor.exported', {'path': uri.toFilePath()}))));
}

class _ExportLyricsDialog extends StatefulWidget {
  const _ExportLyricsDialog({required this.tracks, this.primary});
  final List<LyricTrack> tracks;
  final String? primary;

  @override
  State<_ExportLyricsDialog> createState() => _ExportLyricsDialogState();
}

class _ExportLyricsDialogState extends State<_ExportLyricsDialog> {
  late LyricTrack _track = widget.tracks.firstWhere((t) => t.lang == widget.primary, orElse: () => widget.tracks.first);
  String _format = 'srt';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = _track.lines.where((l) => l.text.trim().isNotEmpty).length;
    return AppDialog(
      title: Text(tr('lyrics.exportTitle')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('lyrics.exportTrack'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          DropdownButton<LyricTrack>(
            isExpanded: true,
            value: _track,
            items: [
              for (final t in widget.tracks)
                DropdownMenuItem(
                  value: t,
                  child: Text(t.lang == widget.primary ? '${lyricTrackLabel(t)} · ${tr('lyrics.exportPrimary')}' : lyricTrackLabel(t), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (t) => setState(() => _track = t ?? _track),
          ),
          Text(tr('lyrics.exportLines', {'n': lines}), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          Text(tr('lyrics.exportFormat'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Row(children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'srt', label: Text('SRT')), ButtonSegment(value: 'lrc', label: Text('LRC'))],
              selected: {_format},
              onSelectionChanged: (v) => setState(() => _format = v.first),
            ),
          ]),
          const SizedBox(height: 6),
          Text(tr(_format == 'srt' ? 'lyrics.exportSrtHint' : 'lyrics.exportLrcHint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, (_track, _format)), child: Text(tr('lyrics.exportSave'))),
      ],
    );
  }
}
