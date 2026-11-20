// A day's setlist as text for a stream: numbered with clock times, or as a
// timeline of video timestamps from when the stream started. Copy it, save
// it, or point OBS at today.txt, which the app keeps up to date.
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/sing_history.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/app_dialog.dart';

Future<void> showSetlistDialog(BuildContext context, {required DateTime day, required List<HistoryEntry> entries}) {
  return showDialog<void>(context: context, builder: (_) => _SetlistDialog(day: day, entries: entries));
}

class _SetlistDialog extends StatefulWidget {
  const _SetlistDialog({required this.day, required this.entries});
  final DateTime day;
  final List<HistoryEntry> entries;

  @override
  State<_SetlistDialog> createState() => _SetlistDialogState();
}

class _SetlistDialogState extends State<_SetlistDialog> {
  bool _timeline = false;
  late DateTime _start = _defaultStart();

  /// The first song's start, to the minute (most streams start a bit earlier).
  DateTime _defaultStart() {
    if (widget.entries.isEmpty) return widget.day.add(const Duration(hours: 20));
    final first = widget.entries.map((e) => e.startedAt.toLocal()).reduce((a, b) => a.isBefore(b) ? a : b);
    return DateTime(first.year, first.month, first.day, first.hour, first.minute);
  }

  String _text(AppSettings s) => formatSetlist(widget.entries, day: widget.day, scores: s.setlistScores, timelineStart: _timeline ? _start : null);

  void _snack(String msg) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickStart() async {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (picked == null) return;
    // On the sing day: hours before the day starts belong to the next date.
    var d = DateTime(widget.day.year, widget.day.month, widget.day.day, picked.hour, picked.minute);
    if (picked.hour < kDayStartHour) d = d.add(const Duration(days: 1));
    setState(() => _start = d);
  }

  Future<void> _save(String text) async {
    final uri = await FilePicker.saveFile(fileName: '${tr('setlist.fileName')} ${formatDay(widget.day)}.txt', bytes: utf8.encode(text));
    if (uri == null || !mounted) return;
    _snack(tr('setlist.saved', {'path': uri.toFilePath()}));
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = _text(settings);
    final today = dayOf(DateTime.now()) == widget.day;
    final t = _start;
    return AppDialog(
      title: Text(tr('setlist.title', {'date': formatDay(widget.day)})),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, icon: const Icon(Icons.schedule, size: 18), label: Text(tr('setlist.clock'))),
                ButtonSegment(value: true, icon: const Icon(Icons.timeline, size: 18), label: Text(tr('setlist.timeline'))),
              ],
              selected: {_timeline},
              onSelectionChanged: (v) => setState(() => _timeline = v.first),
            ),
            const SizedBox(width: 12),
            if (_timeline)
              OutlinedButton.icon(
                onPressed: _pickStart,
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: Text(tr('setlist.streamStart', {'time': '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'})),
              ),
          ]),
          if (_timeline) ...[
            const SizedBox(height: 6),
            Text(tr('setlist.timelineHint'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(tr('setlist.scores')),
            value: settings.setlistScores,
            onChanged: (v) async {
              await settings.setSetlistScores(v);
              services.setlistLog.update();
            },
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
            child: SingleChildScrollView(child: SelectableText(text.trimRight(), style: theme.textTheme.bodyMedium?.copyWith(height: 1.5))),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                _snack(tr('setlist.copied'));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(tr('setlist.copy')),
            ),
            OutlinedButton.icon(onPressed: () => _save(text), icon: const Icon(Icons.save_alt, size: 18), label: Text(tr('setlist.save'))),
          ]),
          if (today) ...[
            const Divider(height: 28),
            Row(children: [
              Icon(Icons.cast, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              Text(tr('setlist.obsTitle'), style: theme.textTheme.titleSmall),
            ]),
            const SizedBox(height: 4),
            Text(tr('setlist.obsHint'), style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            SelectableText(services.setlistLog.todayFile, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Wrap(spacing: 4, children: [
              TextButton.icon(
                onPressed: () async {
                  await services.setlistLog.write();
                  await revealPath(services.setlistLog.todayFile);
                },
                icon: const Icon(Icons.folder_open, size: 16),
                label: Text(tr('setlist.reveal')),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: services.setlistLog.todayFile));
                  _snack(tr('setlist.pathCopied'));
                },
                icon: const Icon(Icons.link, size: 16),
                label: Text(tr('setlist.copyPath')),
              ),
            ]),
          ],
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('close')))],
    );
  }
}
