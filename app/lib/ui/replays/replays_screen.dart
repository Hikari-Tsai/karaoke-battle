// "Replays" tab: import replay files other players exported, find (or
// prepare) the song they sang locally, then show the result card or watch
// the take.
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/prep_pipeline.dart';
import '../../services/replay_library.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/replay_file.dart';
import '../../state/scoring_bridge.dart';
import '../library/add_song_dialog.dart' show kLanguages, kMediaExtensions;
import '../results/new_record_dialog.dart';
import '../results/replay_screen.dart';
import '../widgets/brand.dart';
import '../widgets/rank.dart';

/// File types the import accepts: the exported .zip, or an unzipped .json
/// (its vocal .mp3 is read from beside it).
const kReplayExtensions = ['zip', 'json'];

/// Localized message for a failed import.
String replayImportError(Object e) {
  if (e is ReplayFormatException) return tr('replays.err.${e.code}');
  if (e is FileSystemException) return tr('replays.err.read');
  return '$e';
}

class ReplaysScreen extends StatefulWidget {
  const ReplaysScreen({super.key});

  @override
  State<ReplaysScreen> createState() => _ReplaysScreenState();
}

class _ReplaysScreenState extends State<ReplaysScreen> {
  bool _dragging = false;
  bool _busy = false;

  void _snack(String msg) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));

  Future<void> _importPaths(List<String> paths) async {
    if (paths.isEmpty || _busy) return;
    final replays = context.read<AppServices>().replays;
    setState(() => _busy = true);
    try {
      for (final path in paths) {
        try {
          final list = await replays.import(path);
          _snack(list.length == 1 ? tr('replays.imported', {'title': list.first.title}) : tr('replays.importedMany', {'n': list.length}));
        } catch (e) {
          _snack('${tr('replays.importFailed')}: ${replayImportError(e)}');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: tr('replays.pickTitle'), type: FileType.custom, allowedExtensions: kReplayExtensions);
      await _importPaths([for (final f in files) ?f.path]);
    } catch (e) {
      _snack('${tr('replays.importFailed')}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragDone: (d) {
        setState(() => _dragging = false);
        _importPaths([for (final f in d.files) if (kReplayExtensions.any((e) => f.path.toLowerCase().endsWith('.$e'))) f.path]);
      },
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: BrandedTitle(tr('replays.title')),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.file_open),
                    label: Text(tr('replays.import')),
                  ),
                ),
              ],
            ),
            body: Consumer3<ReplayLibrary, SongLibrary, PrepPipeline>(
              builder: (context, replays, library, pipeline, _) {
                final items = replays.items;
                if (items.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.ondemand_video, size: 64, color: cs.onSurface.withValues(alpha: 0.3)),
                          const SizedBox(height: 12),
                          Text(tr('replays.empty'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final r = items[i];
                    final song = ReplayLibrary.findSong(library, r);
                    return _ReplayCard(key: ValueKey(r.id), replay: r, song: song, status: song == null ? null : pipeline.statusOf(song.id));
                  },
                );
              },
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cs.primary.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Text(tr('replays.drop'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: cs.primary)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReplayCard extends StatefulWidget {
  const _ReplayCard({super.key, required this.replay, required this.song, required this.status});
  final ImportedReplay replay;
  final Song? song;
  final PrepStatus? status;

  @override
  State<_ReplayCard> createState() => _ReplayCardState();
}

class _ReplayCardState extends State<_ReplayCard> {
  bool _busy = false;

  ImportedReplay get r => widget.replay;

  String get _player => r.player.isEmpty ? tr('replays.unknownPlayer') : r.player;

  String get _language {
    final l = r.language;
    return kLanguages.contains(l) ? l : context.read<AppServices>().settings.defaultLanguage;
  }

  void _snack(String msg) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));

  Future<void> _guard(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _snack('${tr('error')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Links the replay to the song found by title / video id so later
  /// lookups do not depend on the match.
  Future<Song> _linked(Song song) async {
    if (r.songId != song.id) await context.read<AppServices>().replays.link(r, song.id);
    return song;
  }

  Future<void> _download() => _guard(() async {
        final services = context.read<AppServices>();
        final song = await services.pipeline.addUrl('https://www.youtube.com/watch?v=${r.youtubeId}', language: _language);
        await services.replays.link(r, song.id);
      });

  Future<void> _pickSource() => _guard(() async {
        final services = context.read<AppServices>();
        final files = await FilePicker.pickFiles(dialogTitle: tr('replays.pickSource'), type: FileType.custom, allowedExtensions: kMediaExtensions);
        final path = files.isEmpty ? null : files.first.path;
        if (path == null) return;
        final song = await services.pipeline.importFile(path, title: r.title, language: _language);
        await services.replays.link(r, song.id);
      });

  Future<void> _chooseFromLibrary() async {
    final services = context.read<AppServices>();
    final songs = services.library.songs;
    final picked = await showDialog<Song>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('replays.chooseSong')),
        children: [
          if (songs.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(tr('library.empty'))),
          for (final s in songs)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(s),
              child: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (picked != null) await services.replays.link(r, picked.id);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('replays.deleteTitle')),
        content: Text(tr('replays.deleteBody', {'title': r.title, 'player': _player})),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok == true && mounted) await context.read<AppServices>().replays.delete(r);
  }

  Future<void> _watch(Song song) async {
    await _linked(song);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReplayScreen(song: song, take: r.take, notesJsonPath: r.notesJson, player: _player)));
  }

  Future<void> _showCard(Song? song, bool ready) async {
    final score = await ScoringBridge.load(r.take.scoreJson);
    if (!mounted) return;
    if (score == null) {
      _snack(tr('results.notAvailable'));
      return;
    }
    final services = context.read<AppServices>();
    final cardSong = song ?? Song(id: r.id, title: r.title, sourceType: SourceType.file, createdAt: r.createdAt);
    final thumb = song == null ? null : services.library.files(song).thumbJpg;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        content: SizedBox(
          width: 420,
          height: 420,
          child: FittedBox(
            child: ShareCard(song: cardSong, score: score, thumbPath: thumb, date: r.createdAt, badge: _player, badgeIcon: Icons.person),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(tr('close'))),
          if (ready && song != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.of(ctx).pop();
                _watch(song);
              },
              icon: const Icon(Icons.play_circle_outline),
              label: Text(tr('replays.watch')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final services = context.read<AppServices>();
    final song = widget.song;
    final status = widget.status;
    final stage = status?.stage ?? song?.stage;
    final inProgress = song != null && stage != PrepStage.done && stage != PrepStage.failed;
    final ready = song != null && song.stage == PrepStage.done && !(status != null && status.stage != PrepStage.done && status.stage != PrepStage.failed);
    final failed = song != null && song.stage == PrepStage.failed && status == null;
    final thumbPath = song == null ? null : services.library.files(song).thumbJpg;
    final thumb = thumbPath != null && File(thumbPath).existsSync() ? File(thumbPath) : null;
    final date = MaterialLocalizations.of(context).formatShortDate(r.createdAt);

    final String statusText;
    if (ready) {
      statusText = tr('replays.ready', {'title': song.title});
    } else if (inProgress) {
      statusText = '${tr('replays.preparing')} · ${tr('stage.${stage!.name}')}';
    } else if (failed) {
      statusText = tr('replays.failed');
    } else if (r.youtubeId != null) {
      statusText = tr('replays.missingYoutube');
    } else {
      statusText = tr('replays.missingFile');
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 128,
                    height: 72,
                    child: thumb != null
                        ? Image.file(thumb, fit: BoxFit.cover)
                        : ColoredBox(color: cs.surfaceContainerHighest, child: Icon(Icons.ondemand_video, color: cs.onSurfaceVariant)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.person, size: 16, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Flexible(child: Text(_player, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
                        const SizedBox(width: 12),
                        Text(date, style: theme.textTheme.bodySmall),
                        const SizedBox(width: 12),
                        Tooltip(
                          message: tr(r.hasVoice ? 'replays.hasVoice' : 'replays.noVoice'),
                          child: Icon(r.hasVoice ? Icons.mic : Icons.mic_off, size: 16, color: r.hasVoice ? cs.primary : cs.onSurfaceVariant),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Text(statusText, style: theme.textTheme.bodySmall?.copyWith(color: failed ? cs.error : cs.onSurfaceVariant), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(r.total.toStringAsFixed(1), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: rankColor(r.rank))),
                    const SizedBox(height: 4),
                    RankChip(rank: r.rank),
                  ],
                ),
                PopupMenuButton<String>(
                  tooltip: tr('more'),
                  onSelected: (v) {
                    if (v == 'link') _chooseFromLibrary();
                    if (v == 'delete') _delete();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'link', child: Text(tr('replays.chooseSong'))),
                    PopupMenuItem(value: 'delete', child: Text(tr('delete'))),
                  ],
                ),
              ],
            ),
            if (inProgress && status != null) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: status.fraction > 0 ? status.fraction : null),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(onPressed: () => _showCard(song, ready), icon: const Icon(Icons.style_outlined), label: Text(tr('replays.card'))),
                if (ready)
                  FilledButton.icon(onPressed: () => _watch(song), icon: const Icon(Icons.play_circle_outline), label: Text(tr('replays.watch')))
                else if (song == null && r.youtubeId != null)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _download,
                    icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download),
                    label: Text(tr('replays.download')),
                  )
                else if (song == null || failed)
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _pickSource,
                    icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.audio_file),
                    label: Text(tr('replays.pickSource')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
