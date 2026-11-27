// 直播工具 (was 演唱紀錄): 觀眾加油 at the top, then what you sang and how
// it scored, newest first, grouped by day.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/sing_history.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../live/cheer_widgets.dart';
import '../results/results_screen.dart';
import 'setlist_dialog.dart';
import '../widgets/brand.dart';
import '../widgets/rank.dart';
import '../widgets/app_dialog.dart';
import '../widgets/reveal.dart';
import '../widgets/live_score.dart';
import '../widgets/stats_card.dart';

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

  /// 重新起算: the stats and the list start from now. Nothing is deleted;
  /// the start point can be moved back at any time (undo, or the range).
  Future<void> _countFromNow() async {
    final entries = _entries ?? const <HistoryEntry>[];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AppDialog(
        title: Text(tr('history.clearTitle')),
        content: SizedBox(width: 440, child: Text(tr('history.clearBody', {'n': entries.length}))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('history.clear'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final settings = context.read<AppSettings>();
    final before = settings.historyClearedAt;
    await _setStart(DateTime.now());
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(tr('history.cleared')),
      persist: false, // an action makes it stay by default
      action: SnackBarAction(label: tr('history.undo'), onPressed: () => _setStart(before)),
    ));
  }

  Future<void> _setStart(DateTime? start) async {
    await context.read<AppSettings>().setHistoryClearedAt(start);
    await _reload();
  }

  /// The date range on the stats card: choose where the stats start (a day,
  /// now, or all takes).
  Future<void> _pickStart() async {
    final settings = context.read<AppSettings>();
    final current = settings.historyClearedAt;
    final choice = await showDialog<String>(context: context, builder: (_) => _StartDialog(start: current));
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'all':
        await _setStart(null);
      case 'now':
        await _setStart(DateTime.now());
      case 'date':
        final today = dayOf(DateTime.now());
        final picked = await showDatePicker(
          context: context,
          initialDate: current == null ? today : dayOf(current),
          firstDate: DateTime(2020),
          lastDate: today,
          helpText: tr('history.startTitle'),
        );
        if (picked == null || !mounted) return;
        // Then the time: the start of the sing day (kDayStartHour) unless
        // changed, or the current start's time when it was on that date.
        final keep = current != null && dayOf(current) == picked;
        final time = await showTimePicker(
          context: context,
          initialTime: keep ? TimeOfDay.fromDateTime(current.toLocal()) : const TimeOfDay(hour: kDayStartHour, minute: 0),
          helpText: tr('history.startTime'),
        );
        if (time != null && mounted) await _setStart(DateTime(picked.year, picked.month, picked.day, time.hour, time.minute));
    }
  }

  /// The OBS setlist: the same takes as the list (from the start point on),
  /// which is also what the OBS text file shows.
  void _obsSetlist() {
    final settings = context.read<AppSettings>();
    context.read<AppServices>().setlistLog.update();
    showSetlistDialog(context, day: dayOf(DateTime.now()), entries: _entries ?? const [], range: true, since: settings.historyClearedAt);
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
        bottom: const PreferredSize(preferredSize: Size.fromHeight(CheerBar.height), child: CheerBar()),
        actions: [
          // 觀眾加油: the payment services' 贊助成功動畫網址.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: () => showCheerSetupDialog(context),
              icon: const Icon(Icons.volunteer_activism),
              label: Text(tr('cheer.setupTitle')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonalIcon(
              onPressed: entries == null ? null : _obsSetlist,
              icon: const Icon(Icons.queue_music),
              label: Text(tr('setlist.today')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: entries == null || entries.isEmpty ? null : _countFromNow,
              icon: const Icon(Icons.restart_alt),
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
                    // Counting from a start point: the earlier takes are still there.
                    if (context.watch<AppSettings>().historyClearedAt case final start?) ...[
                      const SizedBox(height: 16),
                      Text(tr('history.emptySince', {'date': formatStart(start)}), style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 10),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        FilledButton.tonalIcon(onPressed: () => _setStart(null), icon: const Icon(Icons.history), label: Text(tr('history.startAll'))),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(onPressed: _pickStart, icon: const Icon(Icons.event_outlined), label: Text(tr('history.startTip'))),
                      ]),
                    ],
                  ]),
                )
              : _list(context, entries),
    );
  }

  Widget _list(BuildContext context, List<HistoryEntry> entries) {
    final items = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _StatsHeader(stats: summarizeHistory(entries), start: context.read<AppSettings>().historyClearedAt, onOpenBest: _open, onPickStart: _pickStart),
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
  const _StatsHeader({required this.stats, required this.start, required this.onOpenBest, required this.onPickStart});
  final HistoryStats stats;

  /// Where the stats start (null: all takes); the range opens [onPickStart].
  final DateTime? start;
  final void Function(HistoryEntry) onOpenBest;
  final VoidCallback onPickStart;

  @override
  Widget build(BuildContext context) {
    final best = stats.best;
    final range = start != null
        ? tr('history.since', {'date': formatStart(start!)})
        : stats.first == null
            ? tr('history.startAll')
            : stats.first == stats.last
                ? formatDay(stats.first!)
                : tr('history.range', {'from': formatDay(stats.first!), 'to': formatDay(stats.last!)});
    String whole(double v) => '${v.round()}';
    String tenth(double v) => v.toStringAsFixed(1);
    final tiles = <Widget>[
      StatTile(icon: Icons.mic_none, color: const Color(0xFFFF4FA3), label: tr('history.stat.takes'), value: stats.takes.toDouble(), format: whole),
      StatTile(icon: Icons.library_music_outlined, color: const Color(0xFFBF5AF2), label: tr('history.stat.songs'), value: stats.songs.toDouble(), format: whole),
      StatTile(
        icon: Icons.timer_outlined,
        color: const Color(0xFF64D2FF),
        label: tr('history.stat.time'),
        value: stats.sung.inSeconds.toDouble(),
        format: (v) => formatSungTime(Duration(seconds: v.round())),
      ),
      StatTile(icon: Icons.calendar_today_outlined, color: const Color(0xFF30D158), label: tr('history.stat.days'), value: stats.days.toDouble(), format: whole),
      if (stats.average != null)
        StatTile(icon: Icons.equalizer, color: const Color(0xFFFF9F0A), label: tr('history.stat.avg'), value: stats.average!, format: tenth),
      if (best != null)
        StatTile(
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
    return StatsCard(
      icon: Icons.insights,
      title: tr('history.statsTitle'),
      trailing: range,
      onTrailingTap: onPickStart,
      trailingTooltip: tr('history.startTip'),
      tiles: tiles,
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
                      CheerBadge(take: t, trailingGap: 8),
                      // Counts up when 觀眾加油 adds points while shown.
                      LiveScore(
                        value: t.total!,
                        builder: (context, v) {
                          final rank = liveRank(v, t.total!, t.rank);
                          final c = rankColor(rank);
                          return Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                              v.toStringAsFixed(1),
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w900,
                                color: c,
                                fontFeatures: const [FontFeature.tabularFigures()],
                                shadows: [if (rankTier(rank) > 0) Shadow(color: c.withValues(alpha: 0.45), blurRadius: 14)],
                              ),
                            ),
                            const SizedBox(width: 8),
                            RankChip(rank: rank, fontSize: 12),
                          ]);
                        },
                      ),
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
/// Where the History's stats and list start: pops 'date' (pick a day),
/// 'now' or 'all', or null.
class _StartDialog extends StatelessWidget {
  const _StartDialog({required this.start});
  final DateTime? start;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget option(String value, IconData icon, String label, {bool selected = false}) => ListTile(
          leading: Icon(icon, color: selected ? cs.primary : null),
          title: Text(label, style: selected ? TextStyle(color: cs.primary, fontWeight: FontWeight.w700) : null),
          trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          onTap: () => Navigator.pop(context, value),
        );
    return AppDialog(
      title: Text(tr('history.startTitle')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('history.startBody'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          option('date', Icons.event_outlined, start == null ? tr('history.startPick') : '${tr('history.startPick')}（${tr('history.since', {'date': formatStart(start!)})}）', selected: start != null),
          option('now', Icons.restart_alt, tr('history.startNow')),
          option('all', Icons.history, tr('history.startAll'), selected: start == null),
        ]),
      ),
    );
  }
}
