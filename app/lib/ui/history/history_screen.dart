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
import '../widgets/reveal.dart';
import '../widgets/shine.dart';

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
    final items = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _StatsHeader(stats: summarizeHistory(entries), onOpenBest: _open),
      ),
    ];
    DateTime? day;
    var shown = 0; // rows on the first screen come in one after another
    for (final e in entries) {
      final d = dayOf(e.startedAt);
      if (d != day) {
        day = d;
        items.add(_DayHeader(label: _dayLabel(d), count: entries.where((x) => dayOf(x.startedAt) == d).length, onSetlist: () => _setlist(d)));
      }
      items.add(FadeSlideIn(
        delay: Duration(milliseconds: 40 * (shown < 10 ? shown : 0)),
        offset: 12,
        duration: const Duration(milliseconds: 600),
        child: _HistoryRow(entry: e, files: _library.files(e.song), onOpen: () => _open(e), onRemove: () => _remove(e)),
      ));
      shown++;
    }
    // A reading width, centred, with room on both sides.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 20),
      children: [
        for (final w in items)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: w),
            ),
          ),
      ],
    );
  }

  static String _dayLabel(DateTime d) {
    final today = dayOf(DateTime.now());
    if (d == today) return tr('history.today');
    if (d == today.subtract(const Duration(days: 1))) return tr('history.yesterday');
    return formatDay(d);
  }
}

/// A day's heading: the date in a pill, how many takes, a rule, and the
/// day's setlist.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.count, required this.onSetlist});
  final String label;
  final int count;
  final VoidCallback onSetlist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999), border: Border.all(color: cs.primary.withValues(alpha: 0.35))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.calendar_today_outlined, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            Text(label, style: theme.textTheme.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 10),
        Text(tr('history.dayTakes', {'n': count}), style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.outlineVariant.withValues(alpha: 0.5))),
        const SizedBox(width: 8),
        TextButton.icon(onPressed: onSetlist, icon: const Icon(Icons.subject, size: 18), label: Text(tr('setlist.button'))),
      ]),
    );
  }
}

/// Totals at the top: takes, songs, time sung, days (with the date range),
/// the average and the best take (tap it to open its result). The numbers
/// count up and the tiles come in one after another.
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({required this.stats, required this.onOpenBest});
  final HistoryStats stats;
  final void Function(HistoryEntry) onOpenBest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final best = stats.best;
    final range = stats.first == null
        ? null
        : stats.first == stats.last
            ? formatDay(stats.first!)
            : tr('history.range', {'from': formatDay(stats.first!), 'to': formatDay(stats.last!)});
    String whole(double v) => '${v.round()}';
    String tenth(double v) => v.toStringAsFixed(1);
    final tiles = <Widget>[
      _StatTile(icon: Icons.mic_none, color: const Color(0xFFFF4FA3), label: tr('history.stat.takes'), value: stats.takes.toDouble(), format: whole),
      _StatTile(icon: Icons.library_music_outlined, color: const Color(0xFFBF5AF2), label: tr('history.stat.songs'), value: stats.songs.toDouble(), format: whole),
      _StatTile(
        icon: Icons.timer_outlined,
        color: const Color(0xFF64D2FF),
        label: tr('history.stat.time'),
        value: stats.sung.inSeconds.toDouble(),
        format: (v) => formatSungTime(Duration(seconds: v.round())),
      ),
      _StatTile(icon: Icons.calendar_today_outlined, color: const Color(0xFF30D158), label: tr('history.stat.days'), value: stats.days.toDouble(), format: whole),
      if (stats.average != null)
        _StatTile(icon: Icons.equalizer, color: const Color(0xFFFF9F0A), label: tr('history.stat.avg'), value: stats.average!, format: tenth),
      if (best != null)
        _StatTile(
          icon: Icons.emoji_events_outlined,
          color: trophyColor,
          label: tr('history.stat.best'),
          value: best.take.total!,
          format: tenth,
          valueColor: rankColor(best.take.rank),
          trailing: RankChip(rank: best.take.rank, fontSize: 12),
          note: best.song.title,
          highlight: true,
          onTap: () => onOpenBest(best),
        ),
    ];
    return FadeSlideIn(
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3D1546), Color(0xFF241640), Color(0xFF16141F)]),
          border: Border.all(color: const Color(0x33C8BEFA)),
          boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 30, offset: Offset(0, 12))],
        ),
        child: Stack(children: [
          // A soft glow drifting across.
          Positioned.fill(
            child: ShineTicker(
              builder: (context, t) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.8 + 1.6 * (t == null ? 0.5 : shinePulse(t, period: 12)), -0.6),
                    radius: 1.2,
                    colors: const [Color(0x33FF4FA3), Color(0x00FF4FA3)],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(Icons.insights, size: 20, color: Color(0xFFC8BEFA)),
                const SizedBox(width: 8),
                Text(tr('history.statsTitle'), style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                const Spacer(),
                if (range != null) Text(range, style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFAAA6BA))),
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, c) {
                // All across when there is room, else three per row.
                final per = c.maxWidth >= 900 ? tiles.length : 3;
                const gap = 10.0;
                final w = (c.maxWidth - gap * (per - 1)) / per;
                return Wrap(spacing: gap, runSpacing: gap, children: [
                  for (final (i, t) in tiles.indexed)
                    SizedBox(width: w, child: FadeSlideIn(delay: Duration(milliseconds: 80 + 70 * i), offset: 12, child: t)),
                ]);
              }),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _StatTile extends StatefulWidget {
  const _StatTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.format,
    this.note,
    this.valueColor,
    this.trailing,
    this.highlight = false,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final double value;
  final String Function(double) format;
  final String? note;
  final Color? valueColor;
  final Widget? trailing;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  State<_StatTile> createState() => _StatTileState();
}

class _StatTileState extends State<_StatTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = widget;
    final border = w.highlight ? w.color.withValues(alpha: _hover ? 0.9 : 0.55) : const Color(0x1FFFFFFF);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        transform: Matrix4.translationValues(0, _hover && w.onTap != null ? -2 : 0, 0),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
          boxShadow: [if (w.highlight) BoxShadow(color: w.color.withValues(alpha: _hover ? 0.3 : 0.15), blurRadius: 18)],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: w.onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [w.color, w.color.withValues(alpha: 0.5)]),
                      boxShadow: [BoxShadow(color: w.color.withValues(alpha: 0.35), blurRadius: 10)],
                    ),
                    child: Icon(w.icon, size: 15, color: const Color(0xFF111111)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFC9C4D8))),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: CountUp(
                        value: w.value,
                        format: w.format,
                        delay: const Duration(milliseconds: 150),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: w.valueColor ?? Colors.white,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  if (w.trailing != null) ...[const SizedBox(width: 6), w.trailing!],
                ]),
                if (w.note != null) ...[
                  const SizedBox(height: 2),
                  Text(w.note!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFFAAA6BA))),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.entry, required this.files, required this.onOpen, required this.onRemove});
  final HistoryEntry entry;
  final SongFiles files;
  final VoidCallback onOpen, onRemove;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  static const _order = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];
  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entry = widget.entry;
    final t = entry.take;
    final rc = rankColor(t.rank);
    final local = entry.startedAt.toLocal();
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final thumb = widget.files.shownThumb;
    final parts = [
      for (final k in _order)
        if (t.subScores.containsKey(k)) '${tr('results.${_camel(k)}')} ${t.subScores[k] == null ? '—' : t.subScores[k]!.round()}',
    ];
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _hover ? cs.surfaceContainerHigh : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _hover ? rc.withValues(alpha: 0.45) : cs.outlineVariant.withValues(alpha: 0.25)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onOpen,
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // The rank's colour down the left edge.
                Container(width: 4, decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [rc, rc.withValues(alpha: 0.4)]))),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    child: Row(children: [
                      SizedBox(
                        width: 50,
                        child: Text(time, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                      ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 96,
                          height: 54,
                          child: File(thumb).existsSync()
                              ? AnimatedScale(
                                  scale: _hover ? 1.06 : 1,
                                  duration: const Duration(milliseconds: 300),
                                  child: Image.file(File(thumb), fit: BoxFit.cover),
                                )
                              : ColoredBox(color: cs.surfaceContainerHighest, child: Icon(Icons.music_note, color: cs.onSurfaceVariant)),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(entry.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        ]),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        t.total!.toStringAsFixed(1),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: rc,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          shadows: [if (rankTier(t.rank) > 0) Shadow(color: rc.withValues(alpha: 0.45), blurRadius: 14)],
                        ),
                      ),
                      const SizedBox(width: 8),
                      RankChip(rank: t.rank, fontSize: 12),
                      const SizedBox(width: 10),
                      TextButton(onPressed: widget.onOpen, child: Text(tr('library.viewResult'))),
                      IconButton(
                        onPressed: widget.onRemove,
                        tooltip: tr('history.remove'),
                        icon: Icon(Icons.delete_outline, size: 20, color: cs.onSurfaceVariant),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
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
