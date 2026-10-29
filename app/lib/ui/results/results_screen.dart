// Results: total, rank, sub-scores, note table and a static overview roll.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/rank.dart';
import 'new_record_dialog.dart';
import '../../state/live_trace.dart';
import '../../state/scoring_bridge.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../sing/piano_roll.dart';
import '../sing/sing_screen.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.song, required this.take, this.score, this.newRecord = false, this.previousBest});
  final Song song;
  final TakeInfo take;
  final ScoreData? score;

  /// Show the "new record" celebration once the screen is up.
  final bool newRecord;

  /// The song's best total before this take (null = first scored take).
  final double? previousBest;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  ScoreData? _score;
  NoteList? _notes;
  F0Curve? _refF0;
  LiveTrace? _trace;
  double _duration = 0;
  double _pitchShift = 0;
  String? _error;

  Future<void> _share() async {
    final score = _score;
    if (score == null) return;
    final services = context.read<AppServices>();
    var isBest = widget.newRecord;
    if (!isBest) {
      try {
        double? best;
        for (final t in await services.library.takes(widget.song)) {
          if (t.total != null && (best == null || t.total! > best)) best = t.total;
        }
        isBest = best != null && score.total >= best;
      } catch (_) {}
    }
    if (!mounted) return;
    await showShareDialog(context, song: widget.song, take: widget.take, score: score, isBest: isBest, thumbPath: services.library.files(widget.song).thumbJpg);
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.newRecord && widget.score != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final thumb = context.read<AppServices>().library.files(widget.song).thumbJpg;
        showNewRecordDialog(context, song: widget.song, take: widget.take, score: widget.score!, previousBest: widget.previousBest, thumbPath: thumb);
      });
    }
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final files = services.library.files(widget.song);
      final score = widget.score ?? await ScoringBridge.load(widget.take.scoreJson);
      final notes = await NoteList.load(files.notesJson);
      final refF0 = await F0Curve.load(files.refF0Json, confidenceThreshold: 0.5);
      try {
        final info = jsonDecode(await File(widget.take.infoJson).readAsString()) as Map<String, dynamic>;
        _pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
      } catch (_) {}
      final offset = await SingSession.takeTimeOffset(widget.take);
      final takeF0 = await F0Curve.load(widget.take.f0Json, confidenceThreshold: 0.4, timeOffset: offset);
      final shift = (score?.shift ?? 0).toDouble();
      final trace = LiveTrace(takeF0.length + 1);
      for (var i = 0; i < takeF0.length; i++) {
        final m = takeF0.midi[i];
        if (m.isNaN) continue;
        final refRaw = notes.pitchAt(takeF0.times[i]);
        final ref = refRaw.isNaN ? double.nan : refRaw + _pitchShift;
        var display = m + shift;
        var cents = double.nan;
        var cat = PitchCategory.none;
        if (!ref.isNaN) {
          display = foldToOctaveOf(m + shift, ref);
          cents = (display - ref) * 100;
          final a = cents.abs();
          cat = a <= 50 ? PitchCategory.good : (a <= 100 ? PitchCategory.near : PitchCategory.off);
        }
        trace.add(takeF0.times[i], m, display, cents, cat);
      }
      _duration = <double>[widget.song.durationSec ?? 0, notes.endTime + 1, takeF0.isEmpty ? 0.0 : takeF0.times.last].reduce((a, b) => a > b ? a : b);
      if (!mounted) return;
      setState(() {
        _score = score;
        _notes = notes;
        _refF0 = refF0;
        _trace = trace;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final score = _score;
    final notes = _notes;
    return Scaffold(
      appBar: AppBar(
        title: Text('${tr('results.title')} — ${widget.song.title}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: _score == null ? null : _share,
              icon: const Icon(Icons.share),
              label: Text(tr('share.button')),
            ),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: SelectableText(_error!))
          : notes == null
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 320,
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: score == null
                                      ? Center(child: Text(tr('results.notAvailable')))
                                      : Column(
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          children: [
                                            Text(tr('results.total'), style: theme.textTheme.labelLarge),
                                            Row(
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                Text(score.total.toStringAsFixed(1), style: theme.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w700, color: cs.primary)),
                                                const SizedBox(width: 12),
                                                Padding(
                                                  padding: const EdgeInsets.only(bottom: 10),
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                                    decoration: BoxDecoration(color: _rankColor(score.rank), borderRadius: BorderRadius.circular(8)),
                                                    child: Text(score.rank, style: theme.textTheme.headlineSmall?.copyWith(color: Colors.black, fontWeight: FontWeight.w800)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (score.placeholder) Text(tr('results.placeholder'), style: theme.textTheme.labelSmall),
                                            Text('${tr('results.shift')}: ${score.shift} (${score.octaveExactShift >= 0 ? '+' : ''}${score.octaveExactShift})', style: theme.textTheme.labelSmall),
                                            const SizedBox(height: 16),
                                            for (final k in ScoreData.subScoreKeys) ...[
                                              _SubScoreBar(label: tr('results.${_camel(k)}'), value: score.subScores[k]),
                                              const SizedBox(height: 8),
                                            ],
                                          ],
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                children: [
                                  Expanded(
                                    flex: 5,
                                    child: Builder(builder: (context) {
                                      final range = pitchRangeFor(notes, _pitchShift);
                                      return PianoRollView(
                                        notes: notes,
                                        refF0: _refF0 ?? F0Curve.empty(),
                                        trace: _trace,
                                        minMidi: range.min,
                                        maxMidi: range.max,
                                        pitchShift: _pitchShift,
                                        totalDuration: _duration > 0 ? _duration : 1,
                                      );
                                    }),
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    flex: 6,
                                    child: Card(
                                      margin: EdgeInsets.zero,
                                      child: _NoteTable(notes: notes, score: score, pitchShift: _pitchShift),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                            icon: const Icon(Icons.library_music),
                            label: Text(tr('results.backToLibrary')),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SingScreen(song: widget.song))),
                            icon: const Icon(Icons.mic),
                            label: Text(tr('results.singAgain')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }

  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  static Color _rankColor(String rank) => rankColor(rank);
}

class _SubScoreBar extends StatelessWidget {
  const _SubScoreBar({required this.label, required this.value});
  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text(value == null ? tr('results.notAvailable') : value!.toStringAsFixed(0), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (value ?? 0) / 100,
            minHeight: 8,
            color: value == null ? cs.outlineVariant : cs.primary,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }
}

class _NoteTable extends StatelessWidget {
  const _NoteTable({required this.notes, required this.score, required this.pitchShift});
  final NoteList notes;
  final ScoreData? score;
  final double pitchShift;

  @override
  Widget build(BuildContext context) {
    final rows = <ScoreNoteRow>[];
    if (score != null) {
      rows.addAll(score!.notes);
    }
    final byIndex = {for (final r in rows) r.index: r};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(tr('results.notes'), style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              width: double.infinity,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 28,
                dataRowMaxHeight: 32,
                columns: [
                  const DataColumn(label: Text('#')),
                  DataColumn(label: Text(tr('results.onset'))),
                  DataColumn(label: Text(tr('results.refPitch'))),
                  DataColumn(label: Text(tr('results.sungDev'))),
                  DataColumn(label: Text(tr('results.matched'))),
                ],
                rows: [
                  for (var i = 0; i < notes.length; i++)
                    DataRow(cells: [
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(notes.onset[i].toStringAsFixed(2))),
                      DataCell(Text(noteName(notes.pitch[i] + pitchShift))),
                      DataCell(_centsCell(context, byIndex[i]?.cents)),
                      DataCell(Icon(byIndex[i]?.matched == true ? Icons.check_circle : Icons.remove_circle_outline,
                          size: 16, color: byIndex[i]?.matched == true ? const Color(0xFF4CD964) : Theme.of(context).colorScheme.outline)),
                    ]),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _centsCell(BuildContext context, double? cents) {
    if (cents == null) return Text(tr('results.notAvailable'));
    final a = cents.abs();
    final color = a <= 50 ? const Color(0xFF4CD964) : (a <= 100 ? const Color(0xFFFFCC00) : const Color(0xFFFF3B30));
    return Text('${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)}', style: TextStyle(color: color));
  }
}
