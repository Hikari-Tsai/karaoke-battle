// Library: song list with prep progress, actions and takes.
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/prep_pipeline.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../results/results_screen.dart';
import '../sing/sing_screen.dart';
import '../widgets/rank.dart';
import 'add_song_dialog.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _dragging = false;

  Future<void> _onDrop(DropDetails d) async {
    final services = context.read<AppServices>();
    for (final item in d.items) {
      if (item is DropFileItem && item.localPath != null) {
        await services.pipeline.importFile(item.localPath!, language: services.settings.defaultLanguage);
      } else if (item is DropStringItem && item.value.startsWith('http')) {
        await services.pipeline.addUrl(item.value.trim(), language: services.settings.defaultLanguage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDrop: _onDrop,
      onEnter: (_) => setState(() => _dragging = true),
      onLeave: () => setState(() => _dragging = false),
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: Text(tr('library.title')),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton.icon(onPressed: () => AddSongDialog.show(context), icon: const Icon(Icons.add), label: Text(tr('library.add'))),
                ),
              ],
            ),
            body: Consumer2<SongLibrary, PrepPipeline>(
              builder: (context, library, pipeline, _) {
                final songs = library.songs;
                if (songs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.queue_music, size: 64, color: cs.onSurface.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(tr('library.empty'), style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: songs.length,
                  itemBuilder: (context, i) => _SongCard(key: ValueKey(songs[i].id), song: songs[i], status: pipeline.statusOf(songs[i].id)),
                );
              },
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cs.primary.withValues(alpha: 0.15),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.primary, width: 2)),
                    child: Text(tr('library.dropHere'), style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SongCard extends StatefulWidget {
  const _SongCard({super.key, required this.song, required this.status});
  final Song song;
  final PrepStatus? status;

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  List<TakeInfo>? _takes;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _loadTakes(); // the best score is shown on the card even when collapsed
    if (widget.song.stage == PrepStage.done) {
      // Songs prepared before thumbnails existed get one lazily.
      context.read<AppServices>().pipeline.ensureThumbnail(widget.song);
    }
  }

  Future<void> _loadTakes() async {
    final library = context.read<SongLibrary>();
    final t = await library.takes(widget.song);
    if (mounted) setState(() => _takes = t);
  }

  /// The scored take with the highest total, if any.
  TakeInfo? get _best {
    TakeInfo? best;
    for (final t in _takes ?? const <TakeInfo>[]) {
      if (t.total == null) continue;
      if (best == null || t.total! > best.total!) best = t;
    }
    return best;
  }

  Future<void> _sing() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SingScreen(song: widget.song)));
    if (mounted) _loadTakes();
  }

  Future<void> _openResult(TakeInfo t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(song: widget.song, take: t)));
    if (mounted) _loadTakes();
  }

  Future<void> _reprocess() async {
    final services = context.read<AppServices>();
    final f = services.library.files(widget.song);
    for (final p in [f.vocalsWav, f.instWav, f.notesJson, f.refF0Json]) {
      final file = File(p);
      if (await file.exists()) await file.delete();
    }
    widget.song
      ..stage = PrepStage.pending
      ..error = null;
    await services.library.save(widget.song);
    services.pipeline.enqueue(widget.song);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('delete')),
        content: Text(tr('library.deleteConfirm', {'title': widget.song.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final services = context.read<AppServices>();
    services.pipeline.cancel(widget.song.id);
    await services.library.delete(widget.song);
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final status = widget.status;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final stage = status?.stage ?? song.stage;
    final inProgress = status != null && stage != PrepStage.done && stage != PrepStage.failed;
    final ready = song.stage == PrepStage.done && !inProgress;
    final services = context.read<AppServices>();
    final dir = services.library.files(song).dir;
    final best = _best;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                MouseRegion(
                  cursor: ready ? SystemMouseCursors.click : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: ready ? _sing : null,
                    child: Tooltip(
                      message: ready ? tr('library.sing') : '',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 128,
                          height: 72,
                          child: Stack(fit: StackFit.expand, children: [
                            _thumb(song, services.library.files(song).thumbJpg, cs),
                            if (ready)
                              Center(
                                child: Container(
                                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                  padding: const EdgeInsets.all(4),
                                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 26),
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (song.artist.isNotEmpty) Text(song.artist, style: theme.textTheme.bodySmall),
                          Text(formatDuration(song.durationSec), style: theme.textTheme.bodySmall),
                          _Badge(text: tr('source.${song.sourceType.name}'), icon: song.sourceType == SourceType.youtube ? Icons.smart_display : Icons.insert_drive_file),
                          _Badge(text: tr('lang.${song.language}')),
                          _Badge(
                            text: tr('stage.${stage.name}'),
                            color: stage == PrepStage.done ? const Color(0xFF2E7D32) : (stage == PrepStage.failed ? cs.error : cs.secondaryContainer),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (best != null) ...[
                  const SizedBox(width: 12),
                  Tooltip(
                    message: tr('library.bestScore'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.emoji_events, color: trophyColor, size: 22),
                        const SizedBox(width: 4),
                        Text(best.total!.toStringAsFixed(1), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: rankColor(best.rank))),
                        const SizedBox(width: 6),
                        RankChip(rank: best.rank),
                      ],
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                FilledButton.icon(onPressed: ready ? _sing : null, icon: const Icon(Icons.play_circle_outline), label: Text(tr('library.sing'))),
                const SizedBox(width: 4),
                if (inProgress)
                  IconButton(tooltip: tr('library.cancelPrep'), onPressed: () => services.pipeline.cancel(song.id), icon: const Icon(Icons.stop_circle_outlined))
                else
                  PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'reprocess' => _reprocess(),
                      'folder' => revealPath(dir),
                      'delete' => _delete(),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'reprocess', child: ListTile(leading: const Icon(Icons.refresh), title: Text(tr('library.reprocess')))),
                      PopupMenuItem(value: 'folder', child: ListTile(leading: const Icon(Icons.folder_open), title: Text(tr('library.showFolder')))),
                      PopupMenuItem(value: 'delete', child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(tr('delete')))),
                    ],
                  ),
                IconButton(
                  tooltip: tr('library.takes'),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () {
                    setState(() => _expanded = !_expanded);
                    if (_expanded) _loadTakes();
                  },
                ),
              ],
            ),
            if (inProgress) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: status.fraction > 0 ? status.fraction : null),
              const SizedBox(height: 4),
              Text('${tr('stage.${stage.name}')}  ${status.message}', style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (song.error != null && song.stage == PrepStage.failed) ...[
              const SizedBox(height: 6),
              SelectableText(song.error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error), maxLines: 3),
            ],
            if (_expanded) ...[
              const Divider(),
              if (_takes == null)
                const LinearProgressIndicator()
              else if (_takes!.isEmpty)
                Text(tr('library.noTakes'), style: theme.textTheme.bodySmall)
              else
                for (final t in _takes!)
                  _TakeRow(
                    take: t,
                    isBest: identical(t, best),
                    onView: File(t.scoreJson).existsSync() ? () => _openResult(t) : null,
                  ),
            ],
          ],
        ),
      ),
    );
  }

  /// Local thumbnail (YouTube image or a grabbed frame) when the prep made
  /// one, else the remote YouTube thumbnail, else a placeholder.
  Widget _thumb(Song song, String thumbPath, ColorScheme cs) {
    final file = File(thumbPath);
    if (file.existsSync()) {
      return Image.file(file, key: ValueKey(file.lastModifiedSync()), fit: BoxFit.cover, errorBuilder: (context, error, stack) => _thumbFallback(cs));
    }
    if (song.thumbnailUrl != null) {
      return Image.network(song.thumbnailUrl!, fit: BoxFit.cover, errorBuilder: (context, error, stack) => _thumbFallback(cs));
    }
    return _thumbFallback(cs);
  }

  Widget _thumbFallback(ColorScheme cs) => Container(color: cs.surfaceContainerHighest, child: Icon(Icons.music_note, color: cs.onSurface.withValues(alpha: 0.4)));
}

/// One take: score and rank up front, sub-scores in the subtitle; the best
/// take of the song is highlighted.
class _TakeRow extends StatelessWidget {
  const _TakeRow({required this.take, required this.isBest, required this.onView});
  final TakeInfo take;
  final bool isBest;
  final VoidCallback? onView;

  static const _order = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];
  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = take;
    final date = t.createdAt.toLocal().toString().split('.').first;
    final color = rankColor(t.rank);
    final parts = <String>[
      for (final k in _order)
        if (t.subScores.containsKey(k)) '${tr('results.${_camel(k)}')} ${t.subScores[k] == null ? '—' : t.subScores[k]!.round()}',
    ];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: isBest
          ? BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.7)),
            )
          : null,
      child: ListTile(
        dense: true,
        onTap: onView,
        leading: t.total == null
            ? Icon(Icons.graphic_eq, color: cs.onSurfaceVariant)
            : SizedBox(
                width: 110,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.total!.toStringAsFixed(1), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
                    const SizedBox(width: 6),
                    RankChip(rank: t.rank, fontSize: 12),
                  ],
                ),
              ),
        title: Row(
          children: [
            Text(date, style: theme.textTheme.bodyMedium),
            if (isBest) ...[
              const SizedBox(width: 8),
              const Icon(Icons.emoji_events, size: 16, color: trophyColor),
              const SizedBox(width: 2),
              Text(tr('library.bestTake'), style: theme.textTheme.labelMedium?.copyWith(color: trophyColor, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
        subtitle: t.total == null ? Text(tr('library.notScored'), style: theme.textTheme.bodySmall) : Text(parts.join(' · '), style: theme.textTheme.bodySmall),
        trailing: TextButton(onPressed: onView, child: Text(tr('library.viewResult'))),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.icon, this.color});
  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = color ?? cs.surfaceContainerHighest;
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 3)],
          Text(text, style: TextStyle(fontSize: 11, color: fg)),
        ],
      ),
    );
  }
}
