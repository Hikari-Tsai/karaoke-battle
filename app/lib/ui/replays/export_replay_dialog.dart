// "Export replay": saves a .zip (with the profile's name as the player) holding the
// replay JSON and the dry a cappella vocal, which someone else can import.
// For a song from a local file (which the receiver does not have) it also
// asks whether to pack the song in: including it carries a copyright
// reminder, leaving it out explains what the receiver will need.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import '../lyrics/lyrics_actions.dart' show lyricTrackLabel;
import '../widgets/error_report.dart';
import '../widgets/app_dialog.dart';

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
  bool _busy = false;
  String? _error;

  /// Names of the user's own subtitle tracks that go into the replay.
  List<String> _lyrics = const [];

  /// Songs from a local file: whether to pack the song in (null: not chosen yet).
  bool? _includeSong;
  bool get _localSong => widget.song.sourceType == SourceType.file;

  /// Rough size of the included song (MP3 192 kbps), in MB, when known.
  String? _songMb;

  /// The song has a cover image, which goes with the included song.
  bool _hasCover = false;

  /// The user imported a backing track for the song: it goes with it too.
  bool _hasBacking = false;

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    try {
      final f = File(services.library.files(widget.song).lyricsJson);
      final shared = f.existsSync() ? sharedLyrics(Lyrics.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>)) : null;
      _lyrics = [for (final t in shared?.tracks ?? const <LyricTrack>[]) lyricTrackLabel(t)];
    } catch (_) {}
    if (_localSong) {
      _hasCover = File(services.library.files(widget.song).coverJpg).existsSync();
      _hasBacking = services.library.files(widget.song).hasUserInst;
      var seconds = widget.song.durationSec;
      if (seconds == null) {
        // mix.wav: 44.1 kHz 16-bit stereo, near enough for an estimate.
        final mix = File(services.library.files(widget.song).mixWav);
        if (mix.existsSync()) seconds = mix.lengthSync() / (44100 * 4);
      }
      // The song, and the backing track at the same rate.
      if (seconds != null && seconds > 0) _songMb = (seconds * 192000 / 8 / 1e6 * (_hasBacking ? 2 : 1)).toStringAsFixed(1);
    }
  }

  Future<void> _export() async {
    final services = context.read<AppServices>();
    final player = services.settings.playerName.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final base = replayBaseName(widget.song.title, widget.take.total);
      final zip = await services.replays.export(
        song: widget.song,
        files: services.library.files(widget.song),
        take: widget.take,
        player: player,
        baseName: base,
        includeSong: _includeSong == true,
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
      unawaited(services.achievements.recordEvent('share.replay'));
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
    return AppDialog(
      canClose: !_busy, // as the cancel button
      scrollable: true,
      title: Text(tr('export.title')),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('export.body'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            Row(children: [
              Icon(hasVoice ? Icons.folder_zip_outlined : Icons.mic_off, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(tr(hasVoice ? 'export.contents' : 'export.noVoice'), style: theme.textTheme.bodySmall)),
            ]),
            if (_lyrics.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.subtitles_outlined, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('export.lyrics', {'names': _lyrics.join('、')}), style: theme.textTheme.bodySmall)),
              ]),
            ],
            if (_localSong) ...[
              const SizedBox(height: 12),
              _songChoice(theme),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null && !_busy) ReportBugButton(error: _error!, where: 'export replay'),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
        FilledButton.icon(
          onPressed: _busy || (_localSong && _includeSong == null) ? null : _export,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
          label: Text(tr('export.save')),
        ),
      ],
    );
  }

  /// Include the song or not, each with what it means.
  Widget _songChoice(ThemeData theme) {
    final cs = theme.colorScheme;
    final include = _includeSong;
    final note = include == null ? null : tr(include ? 'export.includeSongNote' : 'export.excludeSongNote');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.35),
        border: Border.all(color: cs.tertiary.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.warning_amber_rounded, size: 20, color: cs.tertiary),
            const SizedBox(width: 8),
            Expanded(child: Text(tr('export.localSong'), style: theme.textTheme.bodyMedium)),
          ]),
          const SizedBox(height: 4),
          RadioGroup<bool>(
            groupValue: include,
            onChanged: (v) {
              if (!_busy) setState(() => _includeSong = v);
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              RadioListTile<bool>(
                value: true,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr('export.includeSong')),
                subtitle: _songMb == null && !_hasCover && !_hasBacking
                    ? null
                    : Text([
                        if (_hasBacking || _hasCover)
                          tr('export.extras', {
                            'items': [if (_hasBacking) tr('export.withBacking'), if (_hasCover) tr('export.withCover')].join(tr('export.and')),
                          }),
                        if (_songMb != null) tr('export.songSize', {'mb': _songMb!}),
                      ].join(' · ')),
              ),
              RadioListTile<bool>(
                value: false,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr('export.excludeSong')),
              ),
            ]),
          ),
          if (note != null)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(include! ? Icons.copyright : Icons.info_outline, size: 18, color: include ? cs.error : cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: include ? cs.error : null))),
            ])
          else
            Text(tr('export.chooseSong'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}
