// 演唱紀錄: what you sang and how it scored, newest first, grouped by day.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/sing_history.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../results/results_screen.dart';
import 'setlist_dialog.dart';
import '../widgets/brand.dart';
import '../widgets/rank.dart';
import '../widgets/app_dialog.dart';

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
    final settings = context.read<AppSettings>();
    final entries = await loadSingHistory(_library, clearedAt: settings.historyClearedAt, hidden: settings.historyHidden);
    if (mounted && seq == _loadSeq) setState(() => _entries = entries);
  }

  Future<void> _open(HistoryEntry e) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(song: e.song, take: e.take)));
    if (mounted) _reload();
  }

  /// Removes one take from the list (and the setlist log); with the box
  /// ticked its recording is deleted as well. Removing alone can be undone.
  Future<void> _remove(HistoryEntry e) async {
    final deleteToo = await showDialog<bool>(context: context, builder: (_) => _RemoveDialog(entry: e));
    if (deleteToo == null || !mounted) return;
    final services = context.read<AppServices>();
    final settings = services.settings;
    if (deleteToo) {
      await _library.deleteTakes(e.song, [e.take]);
    } else {
      await settings.setHistoryHidden({...settings.historyHidden, e.key});
      services.setlistLog.update();
    }
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(tr(deleteToo ? 'history.removedDeleted' : 'history.removed')),
      persist: false, // an action makes it stay by default
      action: deleteToo
          ? null
          : SnackBarAction(
              label: tr('history.undo'),
              onPressed: () async {
                await settings.setHistoryHidden(settings.historyHidden..remove(e.key));
                services.setlistLog.update();
                if (mounted) _reload();
              },
            ),
    ));
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
    final items = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
        child: _StatsHeader(stats: summarizeHistory(entries), onOpenBest: _open),
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
      items.add(_HistoryRow(entry: e, files: _library.files(e.song), onOpen: () => _open(e), onRemove: () => _remove(e)));
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

/// Totals at the top: takes, songs, time sung, days (with the date range),
/// the average and the best take (tap it to open its result).
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.stats, required this.onOpenBest});
  final HistoryStats stats;
  final void Function(HistoryEntry) onOpenBest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final best = stats.best;
    final range = stats.first == null
        ? null
        : stats.first == stats.last
            ? formatDay(stats.first!)
            : tr('history.range', {'from': formatDay(stats.first!), 'to': formatDay(stats.last!)});
    final tiles = <Widget>[
      _StatTile(icon: Icons.mic_none, label: tr('history.stat.takes'), value: '${stats.takes}'),
      _StatTile(icon: Icons.library_music_outlined, label: tr('history.stat.songs'), value: '${stats.songs}'),
      _StatTile(icon: Icons.timer_outlined, label: tr('history.stat.time'), value: formatSungTime(stats.sung)),
      _StatTile(icon: Icons.calendar_today_outlined, label: tr('history.stat.days'), value: '${stats.days}', note: range),
      if (stats.average != null) _StatTile(icon: Icons.equalizer, label: tr('history.stat.avg'), value: stats.average!.toStringAsFixed(1)),
      if (best != null)
        _StatTile(
          icon: Icons.emoji_events_outlined,
          label: tr('history.stat.best'),
          value: best.take.total!.toStringAsFixed(1),
          valueColor: rankColor(best.take.rank),
          trailing: RankChip(rank: best.take.rank, fontSize: 11),
          note: best.song.title,
          onTap: () => onOpenBest(best),
        ),
    ];
    return Card(
      margin: EdgeInsets.zero,
      color: cs.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: LayoutBuilder(builder: (context, c) {
          // Six across when there is room, else three per row.
          final per = c.maxWidth >= 900 ? tiles.length : 3;
          final w = c.maxWidth / per;
          return Wrap(children: [for (final t in tiles) SizedBox(width: w, child: t)]);
        }),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.label, required this.value, this.note, this.valueColor, this.trailing, this.onTap});
  final IconData icon;
  final String label, value;
  final String? note;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 15, color: cs.onSurfaceVariant),
            const SizedBox(width: 5),
            Flexible(child: Text(label, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: valueColor, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          ]),
          if (note != null) Text(note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.files, required this.onOpen, required this.onRemove});
  final HistoryEntry entry;
  final SongFiles files;
  final VoidCallback onOpen, onRemove;

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
            IconButton(
              onPressed: onRemove,
              tooltip: tr('history.remove'),
              icon: Icon(Icons.delete_outline, size: 20, color: cs.onSurfaceVariant),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Remove one take from the list; optionally delete its recording too. Pops
/// null (cancel), false (list only) or true (also delete).
class _RemoveDialog extends StatefulWidget {
  const _RemoveDialog({required this.entry});
  final HistoryEntry entry;

  @override
  State<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<_RemoveDialog> {
  bool _delete = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = widget.entry;
    final t = e.startedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return AppDialog(
      title: Text(tr('history.removeTitle')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${e.song.title}\n${formatDay(dayOf(t))} ${two(t.hour)}:${two(t.minute)} · ${e.take.total!.toStringAsFixed(1)} ${e.take.rank ?? ''}'.trimRight(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(tr('history.removeBody')),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _delete,
            onChanged: (v) => setState(() => _delete = v ?? false),
            title: Text(tr('history.deleteTake')),
            subtitle: Text(tr('history.deleteTakeHint'), style: TextStyle(color: _delete ? cs.error : null)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          style: _delete ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
          onPressed: () => Navigator.pop(context, _delete),
          child: Text(tr(_delete ? 'history.removeAndDelete' : 'history.remove')),
        ),
      ],
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
    return AppDialog(
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
