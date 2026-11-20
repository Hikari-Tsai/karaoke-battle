// Results: total, rank, sub-scores, note table and a static overview roll.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../advice/ai_advice.dart';
import '../../services/song_library.dart';
import '../../services/settings.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../rules/rules_screen.dart';
import '../widgets/info_tip.dart';
import '../widgets/shine.dart';
import '../widgets/score_colors.dart';
import '../widgets/rank.dart';
import 'new_record_dialog.dart';
import 'score_reveal.dart';
import 'replay_screen.dart';
import '../replays/export_replay_dialog.dart';
import 'export_video_dialog.dart';
import 'ai_analysis_dialog.dart';
import '../../state/take_trace.dart';
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

class _ResultsScreenState extends State<ResultsScreen> with TickerProviderStateMixin {
  // The reveal runs when the page opens straight after singing.
  AnimationController? _roll;
  AnimationController? _stamp;
  ResultSfx? _sfx;
  bool _rolled = false;
  bool _celebrating = false;
  static const _slot = SlotCurve();
  ScoreData? _score;
  NoteList? _notes;
  F0Curve? _refF0;
  LiveTrace? _trace;
  double _duration = 0;
  double _pitchShift = 0;
  String? _error;

  /// AI tips asked for this take earlier (in the app's language), shown
  /// at the bottom of the score panel.
  SavedAdvice? _advice;

  Future<void> _loadAdvice() async {
    final saved = await SavedAdvice.load(widget.take.adviceJson);
    if (!mounted) return;
    setState(() => _advice = saved != null && saved.lang == I18n.lang ? saved : null);
  }

  Future<void> _openAdvice() async {
    await showAiAnalysisDialog(context, song: widget.song, take: widget.take);
    await _loadAdvice();
  }

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
    await showShareDialog(context, song: widget.song, take: widget.take, score: score, isBest: isBest, thumbPath: services.library.files(widget.song).shownThumb);
  }

  @override
  void initState() {
    super.initState();
    if (widget.score != null) {
      _roll = AnimationController(vsync: this, duration: kRevealRoll)..addStatusListener((s) {
          if (s == AnimationStatus.completed) _onRolled();
        });
      _stamp = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
      _sfx = ResultSfx(enabled: context.read<AppSettings>().resultSounds)..preload();
    }
    _load();
    _loadAdvice();
  }

  @override
  void dispose() {
    _roll?.dispose();
    _stamp?.dispose();
    _sfx?.dispose();
    super.dispose();
  }

  bool get _revealing => _roll != null && !_rolled;

  Future<void> _startReveal() async {
    await _sfx?.preload();
    if (!mounted || _roll == null) return;
    _roll!.forward();
    _sfx?.play('roll');
  }

  /// Tap or key during the roll: jump to the final score.
  void _skipReveal() {
    final roll = _roll;
    if (roll == null || _rolled || !roll.isAnimating) return;
    roll.value = 1; // completes, which runs _onRolled
  }

  void _onRolled() {
    if (_rolled || !mounted) return;
    setState(() => _rolled = true);
    _sfx?.stop('roll');
    _sfx?.play('ding');
    _stamp?.forward();
    if (!widget.newRecord) return;
    Future<void>.delayed(const Duration(milliseconds: 750), () {
      if (!mounted) return;
      if (widget.previousBest != null) {
        setState(() => _celebrating = true);
        _sfx?.play('celebrate');
      } else {
        _showRecordDialog();
      }
    });
  }

  void _endCelebration() {
    if (!_celebrating) return;
    setState(() => _celebrating = false);
    _showRecordDialog();
  }

  void _showRecordDialog() {
    if (!mounted || widget.score == null) return;
    final thumb = context.read<AppServices>().library.files(widget.song).shownThumb;
    showNewRecordDialog(context, song: widget.song, take: widget.take, score: widget.score!, previousBest: widget.previousBest, thumbPath: thumb);
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final files = services.library.files(widget.song);
      final score = widget.score ?? await ScoringBridge.load(widget.take.scoreJson);
      final notes = await NoteList.load(await widget.take.notesFor(files.notesJson));
      final refF0 = await F0Curve.load(files.refF0Json, confidenceThreshold: 0.5);
      try {
        final info = jsonDecode(await File(widget.take.infoJson).readAsString()) as Map<String, dynamic>;
        _pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
      } catch (_) {}
      final offset = await SingSession.takeTimeOffset(widget.take);
      final takeF0 = await F0Curve.load(widget.take.f0Json, confidenceThreshold: 0.4, timeOffset: offset);
      final shift = (score?.shift ?? 0).toDouble();
      final trace = buildTakeTrace(notes, takeF0, shift: shift, pitchShift: _pitchShift);
      _duration = <double>[widget.song.durationSec ?? 0, notes.endTime + 1, takeF0.isEmpty ? 0.0 : takeF0.times.last].reduce((a, b) => a > b ? a : b);
      if (!mounted) return;
      setState(() {
        _score = score;
        _notes = notes;
        _refF0 = refF0;
        _trace = trace;
      });
      if (_roll != null && score != null) _startReveal();
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
    final page = Scaffold(
      appBar: AppBar(
        title: Text('${tr('results.title')} — ${widget.song.title}'),
        actions: [
          if (File(widget.take.wav).existsSync())
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReplayScreen(song: widget.song, take: widget.take))),
                icon: const Icon(Icons.play_circle_outline),
                label: Text(tr('replay.button')),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: _score == null ? null : _openAdvice,
              icon: const Icon(Icons.auto_awesome),
              label: Text(tr('advice.button')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: OutlinedButton.icon(
              onPressed: _score == null ? null : () => showExportReplayDialog(context, song: widget.song, take: widget.take),
              icon: const Icon(Icons.ios_share),
              label: Text(tr('export.button')),
            ),
          ),
          if (File(widget.take.wav).existsSync())
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: _score == null ? null : () => showExportVideoDialog(context, song: widget.song, take: widget.take),
                icon: const Icon(Icons.movie_outlined),
                label: Text(tr('video.button')),
              ),
            ),
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
                                      // Scrolls when the window is short; the AI tips sit at the bottom.
                                      : CustomScrollView(slivers: [
                                          SliverToBoxAdapter(
                                            child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.stretch,
                                          children: [
                                            Text(tr('results.total'), style: theme.textTheme.labelLarge),
                                            _totalRow(theme, score),
                                            if (_roll != null && widget.previousBest != null) _bestMarker(theme, score),
                                            if (score.placeholder) Text(tr('results.placeholder'), style: theme.textTheme.labelSmall),
                                            Text('${tr('results.shift')}: ${score.shift} (${score.octaveExactShift >= 0 ? '+' : ''}${score.octaveExactShift})', style: theme.textTheme.labelSmall),
                                            const SizedBox(height: 6),
                                            // Where the score comes from (not the live pop-ups); tap for the guide.
                                            InkWell(
                                              borderRadius: BorderRadius.circular(4),
                                              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RulesScreen())),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Padding(
                                                    padding: const EdgeInsets.only(top: 1, right: 4),
                                                    child: Icon(Icons.info_outline, size: 14, color: cs.onSurfaceVariant),
                                                  ),
                                                  Expanded(
                                                    child: Text(tr('results.scoredFrom'),
                                                        style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(height: 16),
                                            for (final (i, k) in ScoreData.subScoreKeys.indexed) ...[
                                              _roll == null
                                                  ? _SubScoreBar(label: tr('results.${_camel(k)}'), value: score.subScores[k], tipKey: _camel(k), index: i)
                                                  : AnimatedBuilder(
                                                      animation: _roll!,
                                                      builder: (_, _) => _SubScoreBar(
                                                        label: tr('results.${_camel(k)}'),
                                                        value: score.subScores[k],
                                                        tipKey: _camel(k),
                                                        index: i,
                                                        // Bars fill one after another while the total spins.
                                                        progress: Curves.easeOutCubic.transform(Interval(0.08 + 0.07 * i, 0.5 + 0.07 * i).transform(_roll!.value)),
                                                      ),
                                                    ),
                                              const SizedBox(height: 8),
                                            ],
                                            if (score.raw['rhythm'] is Map) ...[
                                              const SizedBox(height: 4),
                                              _roll == null
                                                  ? _RhythmSummary(rhythm: (score.raw['rhythm'] as Map).cast<String, dynamic>())
                                                  : AnimatedBuilder(
                                                      animation: _roll!,
                                                      builder: (_, _) => _RhythmSummary(
                                                        rhythm: (score.raw['rhythm'] as Map).cast<String, dynamic>(),
                                                        // Fills in after the sub-score bars.
                                                        progress: Curves.easeOutCubic.transform(const Interval(0.5, 0.85).transform(_roll!.value)),
                                                      ),
                                                    ),
                                            ],
                                            const SizedBox(height: 8),
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: TextButton.icon(
                                                // Opened over the results, so Back returns here.
                                                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RulesScreen())),
                                                icon: const Icon(Icons.menu_book_outlined, size: 18),
                                                label: Text(tr('results.scoringGuide')),
                                              ),
                                            ),
                                          ],
                                        ),
                                          ),
                                          if (_advice != null)
                                            SliverFillRemaining(
                                              hasScrollBody: false,
                                              child: Align(
                                                alignment: Alignment.bottomCenter,
                                                child: Padding(
                                                  padding: const EdgeInsets.only(top: 12),
                                                  child: _AdviceCard(advice: _advice!, onOpen: _openAdvice),
                                                ),
                                              ),
                                            ),
                                        ]),
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
                                        keyboard: context.watch<AppSettings>().rollKeyboard,
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
    if (_roll == null) return page;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (!_revealing || e is! KeyDownEvent) return KeyEventResult.ignored;
        _skipReveal();
        return KeyEventResult.handled;
      },
      child: Listener(
        onPointerDown: (_) => _skipReveal(),
        child: Stack(children: [
          page,
          if (_celebrating)
            Positioned.fill(
              child: CelebrationOverlay(score: widget.score!.total, previousBest: widget.previousBest!, onDone: _endCelebration),
            ),
        ]),
      ),
    );
  }

  // S and above shine and sparkle (see RankChip).
  Widget _rankChip(ThemeData theme, ScoreData score) => RankChip(rank: score.rank, fontSize: theme.textTheme.headlineSmall?.fontSize ?? 24);

  /// The total's halo in the rank's colour, slowly brightening and dimming
  /// ([t] on the shine clock; null: still).
  TextStyle _glowing(TextStyle style, ScoreData score, double? t) {
    if (t == null) return style;
    final pulse = shinePulse(t, period: 2.8);
    final c = rankTier(score.rank) > 0 ? _rankColor(score.rank) : (style.color ?? Colors.white);
    return style.copyWith(shadows: [Shadow(color: c.withValues(alpha: 0.18 + 0.32 * pulse), blurRadius: 14 + 18 * pulse)]);
  }

  /// The total and its rank; spinning reels and a stamped rank on reveal.
  Widget _totalRow(ThemeData theme, ScoreData score) {
    final style = theme.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.primary) ?? const TextStyle(fontSize: 57);
    final roll = _roll, stamp = _stamp;
    if (roll == null || stamp == null) {
      return ShineTicker(
        builder: (context, t) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(score.total.toStringAsFixed(1), style: _glowing(style, score, t)),
          const SizedBox(width: 12),
          Padding(padding: const EdgeInsets.only(bottom: 10), child: _rankChip(theme, score)),
        ]),
      );
    }
    // Spin to the total as shown (one decimal), so the last reel lands square.
    final target = _shown(score);
    final intDigits = target >= 100 ? 3 : (target >= 10 ? 2 : 1);
    return AnimatedBuilder(
      animation: Listenable.merge([roll, stamp]),
      builder: (context, _) {
        final u = roll.value;
        final perFrame = u >= 1 ? 0.0 : _slot.slope(u) * target * 10 / (kRevealRoll.inMilliseconds / 1000 * 60);
        final s = Curves.easeOutBack.transform(stamp.value);
        // Once landed, the total glows like the rank (ShineTicker below).
        return ShineTicker(builder: (context, t) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          FittedBox(
            child: RollingNumber(value: target * _slot.transform(u), intDigits: intDigits, style: u >= 1 ? _glowing(style, score, t) : style, tenthsPerFrame: perFrame),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Opacity(
              opacity: (stamp.value * 3).clamp(0.0, 1.0),
              child: Transform.scale(scale: 1 + 1.8 * (1 - s), child: _rankChip(theme, score)),
            ),
          ),
        ]));
      },
    );
  }

  /// "Best 85.2" under the spinning total, turning gold once it is passed.
  Widget _bestMarker(ThemeData theme, ScoreData score) {
    final best = widget.previousBest!;
    return AnimatedBuilder(
      animation: _roll!,
      builder: (context, _) {
        final shown = _shown(score) * _slot.transform(_roll!.value);
        final broken = widget.newRecord && shown > best;
        return Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, a) => ScaleTransition(scale: Tween(begin: 1.6, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)), child: FadeTransition(opacity: a, child: child)),
              child: broken
                  ? Container(
                      key: const ValueKey('broken'),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: trophyColor, borderRadius: BorderRadius.circular(20), boxShadow: const [BoxShadow(color: Color(0x88FFC400), blurRadius: 14)]),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.local_fire_department, size: 16, color: Colors.black),
                        const SizedBox(width: 4),
                        Text(tr('results.bestBroken'), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
                      ]),
                    )
                  : Text(
                      key: const ValueKey('best'),
                      tr('results.best', {'best': best.toStringAsFixed(1)}),
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
            ),
          ),
        );
      },
    );
  }

  static double _shown(ScoreData score) => (score.total * 10).roundToDouble() / 10;

  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  static Color _rankColor(String rank) => rankColor(rank);
}

/// PERFECT / GREAT / GOOD / MISS of the note onsets as one bar split by
/// count, with a legend and, when the latency was calibrated, whether the
/// singer tends to rush or drag.
class _RhythmSummary extends StatelessWidget {
  const _RhythmSummary({required this.rhythm, this.progress = 1});
  final Map<String, dynamic> rhythm;

  /// How far the bar has filled in (the reveal), 0..1.
  final double progress;

  static const _tiers = <(String, String, Color)>[
    ('perfect', 'PERFECT', Color(0xFFFFD60A)),
    ('great', 'GREAT', Color(0xFFFF4FA3)),
    ('good', 'GOOD', Color(0xFF30D158)),
    ('miss', 'MISS', Color(0xFF8E8E93)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final counts = (rhythm['counts'] as Map? ?? const {}).cast<String, dynamic>();
    int n(String k) => (counts[k] as num?)?.toInt() ?? 0;
    final total = _tiers.fold<int>(0, (sum, t) => sum + n(t.$1));
    final tendency = rhythm['tendency'] as String? ?? 'none';
    final ms = (rhythm['tendency_ms'] as num?)?.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(tr('results.timing'), style: theme.textTheme.labelLarge)),
            if (total > 0)
              Text(
                '$total',
                style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
          ],
        ),
        if (total > 0) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Row(
                    children: [
                      for (final (i, (key, _, color)) in _tiers.where((t) => n(t.$1) > 0).indexed) ...[
                        if (i > 0) const SizedBox(width: 2),
                        Expanded(
                          flex: n(key),
                          child: ColoredBox(color: color, child: const SizedBox.expand()),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        // One line; shrinks a little in a narrow panel rather than wrapping.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
          children: [
            for (final (i, (key, label, color)) in _tiers.indexed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (i > 0) const SizedBox(width: 12),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '${n(key)}',
                    style: TextStyle(color: color, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
          ],
          ),
        ),
        if (tendency != 'none') ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                switch (tendency) {
                  'rushing' => Icons.fast_forward,
                  'dragging' => Icons.slow_motion_video,
                  _ => Icons.check_circle_outline,
                },
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(tr('results.tendency.$tendency', {'ms': (ms ?? 0).abs().round()}), style: theme.textTheme.bodySmall)),
            ],
          ),
        ],
      ],
    );
  }
}

/// The AI tips asked for earlier, at the bottom of the score panel: the
/// overall feedback, and how many tips there are. Tap for the whole answer.
class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.advice, required this.onOpen});
  final SavedAdvice advice;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = advice.advice;
    final body = theme.textTheme.bodySmall?.copyWith(height: 1.6, color: cs.onSurface);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0x3D9E266C), Color(0x8C24103E)]),
            border: Border.all(color: const Color(0x33C8BEFA)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 16, color: Color(0xFFF9D84A)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(tr('results.aiAdvice'), style: theme.textTheme.labelLarge?.copyWith(color: const Color(0xFFC8BEFA))),
                  ),
                  Text(tr('results.aiMore', {'n': a.tips.length}), style: theme.textTheme.labelSmall?.copyWith(color: cs.primary)),
                  Icon(Icons.chevron_right, size: 16, color: cs.primary),
                ],
              ),
              if (a.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                // Finding ids like [F1] belong to the full answer; this is a preview.
                Text(a.summary.replaceAll(RegExp(r'\s*\[F\d+(?:\s*,\s*F\d+)*\]'), ''), style: body, maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SubScoreBar extends StatelessWidget {
  const _SubScoreBar({required this.label, required this.value, required this.tipKey, this.progress = 1, this.index = 0});
  final String label;
  final double? value;

  /// Its place in the list: the light sweeps the bars one after another.
  final int index;

  /// How far the bar has filled in (the reveal), 0..1.
  final double progress;

  /// Sub-score key in the rules ('pitch', 'longTone', ...): its rule and tips
  /// are shown behind the question mark.
  final String tipKey;

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
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: theme.textTheme.bodyMedium),
              InfoTip(
                icon: Icons.help_outline,
                size: 16,
                sections: [(tr('results.tipRule'), tr('rules.$tipKey')), (tr('results.tipHow'), tr('results.tip.$tipKey'))],
                footer: tr('results.tipMore'),
              ),
            ]),
            value == null
                ? Tooltip(message: tr('results.locked'), child: Icon(Icons.lock_outline, size: 15, color: cs.onSurfaceVariant))
                : Text((value! * progress).toStringAsFixed(0), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: value == null
              // Not scored for this song: a striped, locked bar.
              ? SizedBox(height: 8, child: CustomPaint(painter: _StripesPainter(background: cs.surfaceContainerHighest, stripe: cs.onSurface.withValues(alpha: 0.12))))
              : Stack(children: [
                  LinearProgressIndicator(
                    value: value! * progress / 100,
                    minHeight: 8,
                    // The sub-score's colour, as on the scoring rules page.
                    color: subScoreColor(tipKey),
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                  // Filled in: a band of light now and then, as on the demo cards.
                  if (progress >= 1) Positioned.fill(child: BarShine(fraction: value! / 100, index: index)),
                ]),
        ),
      ],
    );
  }
}

/// Diagonal stripes, for a sub-score that does not count for the song.
class _StripesPainter extends CustomPainter {
  const _StripesPainter({required this.background, required this.stripe});
  final Color background, stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final p = Paint()
      ..color = stripe
      ..strokeWidth = 3;
    for (var x = -size.height; x < size.width + size.height; x += 7) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_StripesPainter old) => old.background != background || old.stripe != stripe;
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
