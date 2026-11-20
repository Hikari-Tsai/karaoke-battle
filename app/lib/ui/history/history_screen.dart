// 歌單: what you sang and how it scored, newest first, grouped by day.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/sing_history.dart';
import '../../services/song_library.dart';
import '../../state/i18n.dart';
import '../results/results_screen.dart';
import 'setlist_dialog.dart';
import '../widgets/brand.dart';
import '../widgets/rank.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.active = true});

  /// The tab is showing (it stays mounted in the shell); reloads when it is.
  final bool active;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry>? _entries;
  late final SongLibrary _library = context.read<SongLibrary>();
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _library.addListener(_reload);
    _library.takesChanged.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(HistoryScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _reload();
  }

  @override
  void dispose() {
    _library.removeListener(_reload);
    _library.takesChanged.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final seq = ++_loadSeq;
    final entries = await loadSingHistory(_library, clearedAt: context.read<AppSettings>().historyClearedAt);
    if (mounted && seq == _loadSeq) setState(() => _entries = entries);
  }

  Future<void> _open(HistoryEntry e) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(song: e.song, take: e.take)));
    if (mounted) _reload();
  }

  Future<void> _clear() async {
    final entries = _entries ?? const <HistoryEntry>[];
    if (entries.isEmpty) return;
    final deleteToo = await showDialog<bool>(context: context, builder: (_) => _ClearDialog(count: entries.length));
    if (deleteToo == null || !mounted) return;
    final settings = context.read<AppSettings>();
    // Everything listed is at or before the newest take.
    final now = DateTime.now();
    final newest = entries.first.take.createdAt;
    await settings.setHistoryClearedAt(newest.isAfter(now) ? newest : now);
    if (deleteToo) {
      final bySong = <Song, List<TakeInfo>>{};
      for (final e in entries) {
        (bySong[e.song] ??= []).add(e.take);
      }
      for (final MapEntry(key: song, value: takes) in bySong.entries) {
        await _library.deleteTakes(song, takes);
      }
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr(deleteToo ? 'history.clearedDeleted' : 'history.cleared'))));
  }

  void _setlist(DateTime day) {
    final entries = (_entries ?? const <HistoryEntry>[]).where((e) => dayOf(e.startedAt) == day).toList();
    showSetlistDialog(context, day: day, entries: entries);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: BrandedTitle(tr('history.title')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: entries == null ? null : () => _setlist(dayOf(DateTime.now())),
              icon: const Icon(Icons.queue_music),
              label: Text(tr('setlist.today')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: entries == null || entries.isEmpty ? null : _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text(tr('history.clear')),
            ),
          ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.queue_music, size: 64, color: cs.onSurface.withValues(alpha: 0.3)),
                    const SizedBox(height: 12),
                    Text(tr('history.empty'), style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 4),
                    Text(tr('history.emptyHint'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ]),
                )
              : _list(context, entries),
    );
  }

  Widget _list(BuildContext context, List<HistoryEntry> entries) {
    final theme = Theme.of(context);
    final songs = entries.map((e) => e.song.id).toSet().length;
    final items = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(tr('history.summary', {'n': entries.length, 'songs': songs}), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    ];
    DateTime? day;
    for (final e in entries) {
      final d = dayOf(e.startedAt);
      if (d != day) {
        day = d;
        items.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
          child: Row(children: [
            Text(_dayLabel(d), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(onPressed: () => _setlist(d), icon: const Icon(Icons.subject, size: 18), label: Text(tr('setlist.button'))),
          ]),
        ));
      }
      items.add(_HistoryRow(entry: e, files: _library.files(e.song), onOpen: () => _open(e)));
    }
    return ListView(padding: const EdgeInsets.all(12), children: items);
  }

  static String _dayLabel(DateTime d) {
    final today = dayOf(DateTime.now());
    if (d == today) return tr('history.today');
    if (d == today.subtract(const Duration(days: 1))) return tr('history.yesterday');
    return formatDay(d);
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.files, required this.onOpen});
  final HistoryEntry entry;
  final SongFiles files;
  final VoidCallback onOpen;

  static const _order = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];
  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = entry.take;
    final local = entry.startedAt.toLocal();
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final thumb = files.shownThumb;
    final parts = [
      for (final k in _order)
        if (t.subScores.containsKey(k)) '${tr('results.${_camel(k)}')} ${t.subScores[k] == null ? '—' : t.subScores[k]!.round()}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            SizedBox(width: 48, child: Text(time, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]))),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 80,
                height: 45,
                child: File(thumb).existsSync()
                    ? Image.file(File(thumb), fit: BoxFit.cover)
                    : ColoredBox(color: cs.surfaceContainerHighest, child: Icon(Icons.music_note, color: cs.onSurfaceVariant)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: 12),
            Text(t.total!.toStringAsFixed(1), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: rankColor(t.rank))),
            const SizedBox(width: 6),
            RankChip(rank: t.rank, fontSize: 12),
            const SizedBox(width: 8),
            TextButton(onPressed: onOpen, child: Text(tr('library.viewResult'))),
          ]),
        ),
      ),
    );
  }
}

/// Clear the list; optionally delete the recordings too. Pops null (cancel),
/// false (list only) or true (also delete).
class _ClearDialog extends StatefulWidget {
  const _ClearDialog({required this.count});
  final int count;

  @override
  State<_ClearDialog> createState() => _ClearDialogState();
}

class _ClearDialogState extends State<_ClearDialog> {
  bool _delete = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(tr('history.clearTitle')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('history.clearBody', {'n': widget.count})),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _delete,
            onChanged: (v) => setState(() => _delete = v ?? false),
            title: Text(tr('history.deleteTakes')),
            subtitle: Text(tr('history.deleteTakesHint'), style: TextStyle(color: _delete ? cs.error : null)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          style: _delete ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
          onPressed: () => Navigator.pop(context, _delete),
          child: Text(tr(_delete ? 'history.clearAndDelete' : 'history.clear')),
        ),
      ],
    );
  }
}
