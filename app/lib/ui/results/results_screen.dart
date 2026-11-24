// Results: total, rank, sub-scores, note table and a static overview roll.
import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
import '../widgets/achievement_events.dart';
import '../../state/lyrics.dart';
import '../../state/note_lyrics.dart';
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
import '../../state/tuning_wand.dart';
import '../../state/wand_action.dart';
import '../../services/dev_mode.dart';
import '../../services/items.dart';
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

  /// The lyric under each note (see note_lyrics.dart); null without lyrics.
  List<String?>? _noteLyrics;
  F0Curve? _refF0;
  LiveTrace? _trace;
  double _duration = 0;
  double _pitchShift = 0;
  String? _error;

  /// The score before the Tuning Wand was first used (only shown here).
  ScoreData? _original;

  /// Notes fixed with the Tuning Wand (indices into [_notes]).
  Set<int> _wanded = const {};
  bool _wanding = false;

  /// With the Weakness Glasses (or in 開發模式): how much the total would
  /// rise with a wand on each note alone (worked out a batch at a time
  /// after the page opens).
  Map<int, double> _gains = {};
  bool _gainsRunning = false;
  int _gainsRun = 0;

  /// How far the shares are worked out (0..1), while [_gainsRunning].
  double _gainsProgress = 0;

  /// Each untuned note's share of the way to 100 (see WandWeights): worked
  /// out once per take (kept in its folder), then at once.
  Future<void> _computeGains() async {
    final notes = _notes;
    if (notes == null || _score == null || _gainsRunning) return;
    final services = context.read<AppServices>();
    if (!_seesGains(services)) return;
    final run = ++_gainsRun;
    // The figures shown stay until they are worked out again (a note that
    // gained nothing stays locked meanwhile, instead of a box popping up).
    setState(() {
      _gainsRunning = true;
      _gainsProgress = 0;
      _gains = {for (final e in _gains.entries) if (!_wanded.contains(e.key)) e.key: e.value};
    });
    try {
      final weights = await SingSession.wandWeights(
        services,
        services.library.files(widget.song),
        widget.take,
        onProgress: (d) {
          if (mounted && run == _gainsRun) setState(() => _gainsProgress = d);
        },
      );
      if (!mounted || run != _gainsRun) return;
      final shares = weights.shares;
      setState(() {
        _gains = {for (var i = 0; i < notes.length; i++) if (!_wanded.contains(i)) i: shares[WandWeights.onsetKey(notes.onset[i])] ?? 0};
        // A note a wand would add nothing to cannot be picked.
        _picked = {for (final i in _picked) if (!_noGain(i)) i};
      });
    } catch (_) {
      // Only a guide; the wand works without it.
    } finally {
      if (mounted && run == _gainsRun) setState(() => _gainsRunning = false);
    }
  }

  static bool _seesGains(AppServices services) => devFeatures(services.settings) || services.items.has(ItemKind.weaknessGlasses);

  /// The notes picked on the score above or in the list: the wand button
  /// above applies to all of them at once.
  Set<int> _picked = {};

  Set<int> _wandedOf(ScoreData? score, NoteList notes) {
    final uses = wandUsesOfScore(score?.raw);
    return {for (var i = 0; i < notes.length; i++) if (uses.any((u) => u.isNote(notes.onset[i]))) i};
  }

  /// Picks or drops note [i] (a note already tuned cannot be picked).
  /// With the gains shown: a note a wand would add nothing to (+0.00).
  bool _noGain(int i) => _seesGains(context.read<AppServices>()) && (_gains[i] ?? 1) < 0.005;

  void _togglePick(int? i) {
    if (i == null || _wanding || _noGain(i)) return;
    if (_wanded.contains(i)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('wand.applied')), duration: const Duration(seconds: 2)));
      return;
    }
    setState(() {
      final next = {..._picked};
      if (!next.remove(i)) next.add(i);
      _picked = next;
    });
  }

  /// "note 3 E4「愛」"
  String _noteLabel(NoteList notes, int i) {
    final lyric = _noteLyrics != null && i < _noteLyrics!.length ? _noteLyrics![i] : null;
    return tr('wand.note', {'n': i + 1, 'note': noteName(notes.pitch[i] + _pitchShift)}) + (lyric != null && lyric != lyricHold ? '「$lyric」' : '');
  }

  /// Above the score: what is picked and the wand button, locked (with a
  /// hint) until at least one note is picked.
  Widget _wandBar(ThemeData theme, NoteList notes, ScoreData? score) {
    const purple = Color(0xFFB57CFF);
    final picked = (_picked.toList()..sort());
    final held = context.watch<ItemService>().ownedOf(ItemKind.tuningWand);
    final ready = picked.isNotEmpty && score != null && !_wanding && !_revealing;
    final text = picked.isEmpty
        ? tr('wand.pickHint')
        : picked.length == 1
            ? tr('wand.picked', {'note': _noteLabel(notes, picked.first)})
            : tr('wand.pickedMany', {'n': picked.length});
    return Row(children: [
      Icon(picked.isEmpty ? Icons.touch_app_outlined : Icons.music_note, size: 18, color: picked.isEmpty ? theme.colorScheme.onSurfaceVariant : purple),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(color: picked.isEmpty ? theme.colorScheme.onSurfaceVariant : null, fontWeight: picked.isEmpty ? null : FontWeight.w700),
        ),
      ),
      if (picked.isNotEmpty)
        IconButton(tooltip: tr('wand.unpick'), visualDensity: VisualDensity.compact, onPressed: () => setState(() => _picked = {}), icon: const Icon(Icons.close, size: 18)),
      const SizedBox(width: 4),
      Tooltip(
        message: picked.isEmpty ? tr('wand.pickFirst') : '',
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: purple, foregroundColor: Colors.white),
          onPressed: ready ? () => _useWand(picked) : null,
          icon: Icon(ready ? Icons.auto_fix_high : Icons.lock_outline, size: 18),
          label: Text(picked.length > 1 ? tr('wand.useButtonMany', {'k': picked.length, 'n': held}) : tr('wand.useButton', {'n': held})),
        ),
      ),
    ]);
  }

  /// Asks, then takes the wand off every note: the score goes back to how
  /// it was sung; the wands used are not given back.
  Future<void> _resetWand() async {
    final notes = _notes, score = _score;
    if (notes == null || score == null || _wanding || _wanded.isEmpty) return;
    final services = context.read<AppServices>();
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.restart_alt, size: 36),
        title: Text(tr('wand.resetTitle')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(tr('wand.resetBody', {'n': _wanded.length, 'total': _original?.total.toStringAsFixed(1) ?? '—'})),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
          FilledButton.icon(onPressed: () => Navigator.pop(context, true), icon: const Icon(Icons.restart_alt, size: 18), label: Text(tr('wand.resetGo'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _wanding = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final before = score.total;
      final next = await resetTuningWand(services: services, song: widget.song, take: widget.take);
      if (!mounted) return;
      setState(() {
        _score = next;
        _original = null;
        _wanded = {};
        _picked = {};
      });
      messenger.showSnackBar(SnackBar(content: Text(tr('wand.resetDone', {'from': before.toStringAsFixed(1), 'to': next.total.toStringAsFixed(1)}))));
      _gainsRunning = false;
      unawaited(_computeGains());
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('wand.failed', {'e': '$e'}))));
    } finally {
      if (mounted) setState(() => _wanding = false);
    }
  }

  /// Asks (with the estimate), then uses a Tuning Wand on each picked note
  /// (redeeming the ones missing when the points allow) and shows the new
  /// score.
  Future<void> _useWand(List<int> picked) async {
    final notes = _notes, score = _score;
    if (notes == null || score == null || _wanding || picked.isEmpty) return;
    final services = context.read<AppServices>();
    final items = services.items;
    const kind = ItemKind.tuningWand;
    final need = picked.length;
    final held = items.ownedOf(kind);
    final short = need - held;
    final canBuy = short <= 0 || (kind.available && items.balance >= kind.cost * short);
    final what = need == 1
        ? _noteLabel(notes, picked.first)
        : tr('wand.notes', {'list': picked.take(5).map((i) => '${i + 1}').join(tr('wand.listSep')), 'more': need > 5 ? tr('wand.andMore', {'n': need}) : '', 'n': need});
    // What it would bring, worked out while the dialog is open.
    final estimate = canBuy ? previewTuningWand(services: services, song: widget.song, take: widget.take, notes: notes, indices: picked) : null;
    estimate?.ignore(); // the dialog may close before it is done
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_fix_high, color: Color(0xFFB57CFF), size: 36),
        title: Text(tr('items.tuningWand.name')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(short <= 0
                ? tr('wand.askMany', {'what': what, 'k': need, 'n': held})
                : canBuy
                    ? tr('wand.askRedeemMany', {'what': what, 'k': need, 'n': held, 'short': short, 'cost': kind.cost * short, 'balance': items.balance})
                    : tr('wand.noneMany', {'k': need, 'n': held, 'cost': kind.cost * short, 'balance': items.balance})),
            if (estimate != null) ...[
              const SizedBox(height: 14),
              _WandEstimate(before: score, after: estimate),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
          if (canBuy)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB57CFF), foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: Text(short <= 0 ? tr('wand.use') : tr('wand.redeemUse', {'cost': kind.cost * short})),
            ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _wanding = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final before = score.total;
      final next = await useTuningWand(services: services, song: widget.song, take: widget.take, notes: notes, indices: picked, redeem: short > 0);
      final original = await originalScoreOf(widget.take);
      if (!mounted) return;
      setState(() {
        _score = next;
        _original = original;
        _wanded = _wandedOf(next, notes);
        _picked = {};
      });
      _gainsRunning = false;
      unawaited(_computeGains());
      unawaited(ResultSfx.once(services.settings, 'wand'));
      messenger.showSnackBar(SnackBar(content: Text(tr('wand.done', {'from': before.toStringAsFixed(1), 'to': next.total.toStringAsFixed(1)}))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr('wand.failed', {'e': '$e'}))));
    } finally {
      if (mounted) setState(() => _wanding = false);
    }
  }

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
    recordAchievementEvent(context, 'basics.results');
    if (widget.score != null) {
      // Unlocks wait until the score (and any new record) has been shown.
      AchievementHold.add(this);
      _roll = AnimationController(vsync: this, duration: kRevealRoll)..addStatusListener((s) {
          if (s == AnimationStatus.completed) _onRolled();
        });
      _stamp = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
      _sfx = ResultSfx.of(context.read<AppSettings>(), only: const ['roll', 'ding', 'ding_s', 'celebrate'])..preload();
    }
    _load();
    _loadAdvice();
  }

  @override
  void dispose() {
    AchievementHold.remove(this);
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
    // An S or better lands with a brighter chord.
    _sfx?.play(rankTier(widget.score?.rank) > 0 ? 'ding_s' : 'ding');
    _stamp?.forward();
    if (!widget.newRecord) {
      Future<void>.delayed(const Duration(milliseconds: 900), () => AchievementHold.remove(this));
      return;
    }
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

  Future<void> _showRecordDialog() async {
    if (!mounted || widget.score == null) return;
    final thumb = context.read<AppServices>().library.files(widget.song).shownThumb;
    await showNewRecordDialog(context, song: widget.song, take: widget.take, score: widget.score!, previousBest: widget.previousBest, thumbPath: thumb);
    AchievementHold.remove(this);
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
      List<String?>? noteLyrics;
      try {
        final lines = (await services.pipeline.loadLyrics(widget.song)).primaryTrack?.shownLines ?? const <LyricLine>[];
        if (lines.isNotEmpty) noteLyrics = lyricsForNotes([for (var i = 0; i < notes.length; i++) notes.onset[i]], lines);
      } catch (_) {}
      final trace = buildTakeTrace(notes, takeF0, shift: shift, pitchShift: _pitchShift);
      final original = await originalScoreOf(widget.take);
      _duration = <double>[widget.song.durationSec ?? 0, notes.endTime + 1, takeF0.isEmpty ? 0.0 : takeF0.times.last].reduce((a, b) => a > b ? a : b);
      if (!mounted) return;
      setState(() {
        _score = score;
        _notes = notes;
        _noteLyrics = noteLyrics;
        _refF0 = refF0;
        _trace = trace;
        _original = original;
        _wanded = _wandedOf(score, notes);
      });
      unawaited(_computeGains());
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
                                            if (fieldOfScore(score.raw))
                                              Tooltip(
                                                message: tr('field.badgeTip'),
                                                child: Row(children: [
                                                  const Icon(Icons.wifi_tethering, size: 14, color: Color(0xFF3FC8DE)),
                                                  const SizedBox(width: 4),
                                                  Text(tr('field.badge'), style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFF8FE6F2))),
                                                ]),
                                              ),
                                            if (_original != null)
                                              Tooltip(
                                                message: tr('wand.originalTip'),
                                                child: Row(children: [
                                                  const Icon(Icons.auto_fix_high, size: 14, color: Color(0xFFB57CFF)),
                                                  const SizedBox(width: 4),
                                                  Flexible(
                                                    child: Text(tr('wand.original', {'total': _original!.total.toStringAsFixed(1), 'n': _wanded.length}),
                                                        style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFD9BDFF))),
                                                  ),
                                                  // Back to the score as sung (the wands stay used).
                                                  if (_wanded.isNotEmpty)
                                                    TextButton.icon(
                                                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                                                      onPressed: _wanding || _revealing ? null : _resetWand,
                                                      icon: const Icon(Icons.restart_alt, size: 16),
                                                      label: Text(tr('wand.reset')),
                                                    ),
                                                ]),
                                              ),
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
                                      final roll = ZoomableRoll(
                                        total: _duration > 0 ? _duration : 1,
                                        builder: (start, span) => PianoRollView(
                                        notes: notes,
                                        refF0: _refF0 ?? F0Curve.empty(),
                                        trace: _trace,
                                        minMidi: range.min,
                                        maxMidi: range.max,
                                        pitchShift: _pitchShift,
                                        totalDuration: _duration > 0 ? _duration : 1,
                                        keyboard: context.watch<AppSettings>().rollKeyboard,
                                        wandNotes: _wanded,
                                        fieldAura: fieldOfScore(score?.raw),
                                        selectedNotes: _picked,
                                        onSelectNote: _togglePick,
                                        viewStart: start,
                                        viewSpan: span,
                                      ),
                                      );
                                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                        _wandBar(theme, notes, score),
                                        const SizedBox(height: 8),
                                        Expanded(child: roll),
                                      ]);
                                    }),
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(
                                    flex: 6,
                                    child: Card(
                                      margin: EdgeInsets.zero,
                                      child: Stack(children: [
                                        _NoteTable(
                                          notes: notes,
                                          score: score,
                                          pitchShift: _pitchShift,
                                          lyrics: _noteLyrics,
                                          wanded: _wanded,
                                          picked: _picked,
                                          onPick: score == null || _wanding || _revealing ? null : _togglePick,
                                          gains: (context.watch<AppSettings>().devMode || context.watch<ItemService>().has(ItemKind.weaknessGlasses)) && _seesGains(context.read<AppServices>()) ? _gains : null,
                                          noGain: {for (var i = 0; i < notes.length; i++) if (_noGain(i)) i},
                                          gainsRunning: _gainsRunning,
                                          gainsProgress: _gainsProgress,
                                        ),
                                        if (_wanding) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator()),
                                      ]),
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

/// The whole-song piano roll, zoomable in time: Ctrl/⌘ + wheel or a pinch
/// zooms around the pointer, the wheel, a two-finger swipe or a drag moves
/// along, and the buttons zoom in, out and back to the whole song. A thin
/// bar under it shows which part is in view.
class ZoomableRoll extends StatefulWidget {
  const ZoomableRoll({super.key, required this.total, required this.builder});

  /// The song's length (seconds).
  final double total;

  /// The roll for the part in view: [span] seconds from [start] (span null:
  /// the whole song).
  final Widget Function(double start, double? span) builder;

  /// The shortest part one can zoom to (seconds).
  static const minSpan = 2.0;
  static const gutter = 46.0;

  @override
  State<ZoomableRoll> createState() => ZoomableRollState();
}

class ZoomableRollState extends State<ZoomableRoll> {
  double zoom = 1;
  double start = 0;
  double _lastScale = 1;

  double get _maxZoom => math.max(1, widget.total / ZoomableRoll.minSpan);
  double get span => widget.total / zoom;

  void _set(double z, double s) {
    final zz = z.clamp(1.0, _maxZoom).toDouble();
    final sp = widget.total / zz;
    setState(() {
      zoom = zz;
      start = s.clamp(0.0, math.max(0.0, widget.total - sp)).toDouble();
    });
  }

  /// Zooms by [factor] keeping the time at [frac] (0..1 across the plot) in place.
  void zoomBy(double factor, [double frac = 0.5]) {
    final at = start + frac * span;
    final z = (zoom * factor).clamp(1.0, _maxZoom).toDouble();
    _set(z, at - frac * widget.total / z);
  }

  void _pan(double dx, double plotW) {
    if (zoom <= 1 || plotW <= 0) return;
    _set(zoom, start + dx / plotW * span);
  }

  double _frac(double x, double width) => ((x - ZoomableRoll.gutter) / (width - ZoomableRoll.gutter)).clamp(0.0, 1.0);

  @override
  void didUpdateWidget(ZoomableRoll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.total != widget.total) _set(zoom, start);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, c) {
      final plotW = c.maxWidth - ZoomableRoll.gutter;
      return Stack(children: [
        Positioned.fill(
          child: Listener(
            onPointerSignal: (e) {
              if (e is! PointerScrollEvent) return;
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed || keys.isMetaPressed) {
                zoomBy(math.exp(-e.scrollDelta.dy / 240), _frac(e.localPosition.dx, c.maxWidth));
              } else {
                _pan(e.scrollDelta.dx != 0 ? e.scrollDelta.dx : e.scrollDelta.dy, plotW);
              }
            },
            onPointerPanZoomStart: (_) => _lastScale = 1,
            onPointerPanZoomUpdate: (e) {
              if (e.scale != _lastScale) {
                zoomBy(e.scale / _lastScale, _frac(e.localPosition.dx, c.maxWidth));
                _lastScale = e.scale;
              }
              _pan(-e.panDelta.dx, plotW);
            },
            child: GestureDetector(
              onHorizontalDragUpdate: zoom > 1 ? (d) => _pan(-d.delta.dx, plotW) : null,
              child: widget.builder(start, zoom > 1 ? span : null),
            ),
          ),
        ),
        // Zoom buttons.
        Positioned(
          top: 6,
          right: 6,
          child: Container(
            decoration: BoxDecoration(color: theme.colorScheme.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(tooltip: tr('roll.zoomOut'), visualDensity: VisualDensity.compact, iconSize: 18, onPressed: zoom > 1 ? () => zoomBy(1 / 1.6) : null, icon: const Icon(Icons.zoom_out)),
              Tooltip(
                message: tr('roll.zoomHint'),
                child: SizedBox(width: 44, child: Text('${zoom < 10 ? zoom.toStringAsFixed(1) : zoom.round()}×', textAlign: TextAlign.center, style: theme.textTheme.labelMedium)),
              ),
              IconButton(tooltip: tr('roll.zoomIn'), visualDensity: VisualDensity.compact, iconSize: 18, onPressed: zoom < _maxZoom ? () => zoomBy(1.6) : null, icon: const Icon(Icons.zoom_in)),
              IconButton(tooltip: tr('roll.zoomFit'), visualDensity: VisualDensity.compact, iconSize: 18, onPressed: zoom > 1 ? () => _set(1, 0) : null, icon: const Icon(Icons.fit_screen)),
            ]),
          ),
        ),
        // Which part is in view.
        if (zoom > 1)
          Positioned(
            left: ZoomableRoll.gutter + plotW * (start / widget.total),
            width: math.max(12, plotW / zoom),
            bottom: 2,
            height: 4,
            child: DecoratedBox(decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2))),
          ),
      ]);
    });
  }
}

/// The wand dialog's estimate: the total and rank now and after, worked
/// out by scoring the take with the note perfect (nothing saved).
class _WandEstimate extends StatelessWidget {
  const _WandEstimate({required this.before, required this.after});
  final ScoreData before;
  final Future<ScoreData> after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const purple = Color(0xFFB57CFF);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: purple.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: purple.withValues(alpha: 0.35)),
      ),
      child: FutureBuilder<ScoreData>(
        future: after,
        builder: (context, snap) {
          if (snap.hasError) return Text(tr('wand.estimateFailed'), style: theme.textTheme.bodySmall);
          final a = snap.data;
          if (a == null) {
            return Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(tr('wand.estimating'), style: theme.textTheme.bodyMedium),
            ]);
          }
          final gain = a.total - before.total;
          final big = theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800);
          final up = a.rank != before.rank;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('wand.estimate'), style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFD9BDFF))),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(before.total.toStringAsFixed(1), style: big?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, size: 20)),
              Text(a.total.toStringAsFixed(1), style: big?.copyWith(color: rankColor(a.rank))),
              const SizedBox(width: 8),
              Text('${gain >= 0 ? '+' : ''}${gain.toStringAsFixed(1)}', style: theme.textTheme.titleMedium?.copyWith(color: gain > 0 ? const Color(0xFF4CD964) : theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
              const Spacer(),
              RankChip(rank: before.rank),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 16)),
              RankChip(rank: a.rank),
            ]),
            if (up) ...[
              const SizedBox(height: 6),
              Text(tr('wand.rankUp', {'from': before.rank, 'to': a.rank}), style: theme.textTheme.bodySmall?.copyWith(color: rankColor(a.rank), fontWeight: FontWeight.w700)),
            ] else if (gain.abs() < 0.05) ...[
              const SizedBox(height: 6),
              Text(tr('wand.noGain'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ]);
        },
      ),
    );
  }
}

class _NoteTable extends StatelessWidget {
  const _NoteTable({required this.notes, required this.score, required this.pitchShift, this.lyrics, this.wanded = const {}, this.picked = const {}, this.onPick, this.gains, this.gainsRunning = false, this.gainsProgress = 0, this.noGain = const {}});
  final double gainsProgress;

  /// Each note's gain from a wand on it alone (null: not shown), and the
  /// notes it would add nothing to (no box, not pickable).
  final Map<int, double>? gains;
  final Set<int> noGain;
  final bool gainsRunning;
  final NoteList notes;

  /// Notes fixed with the Tuning Wand, and the ones picked for it (also on
  /// the score above): a row's box, or a click on the row, picks it.
  final Set<int> wanded;
  final Set<int> picked;
  final ValueChanged<int>? onPick;
  final ScoreData? score;
  final double pitchShift;

  /// The lyric under each note, matched by time (rough); null: no lyrics.
  final List<String?>? lyrics;

  @override
  Widget build(BuildContext context) {
    final rows = <ScoreNoteRow>[];
    if (score != null) {
      rows.addAll(score!.notes);
    }
    final byIndex = {for (final r in rows) r.index: r};
    // More of what each note was judged on: the rhythm calls, how much of it
    // was sung and in tune, and how steady a long note was.
    final raw = score?.raw;
    Map<int, Map> byNote(Object? list) => {for (final e in (list is List ? list : const [])) if (e is Map && e['index'] is int) e['index'] as int: e};
    final perNote = byNote((raw?['note_metrics'] as Map?)?['per_note']);
    final rhythm = byNote((raw?['rhythm'] as Map?)?['notes']);
    final longs = byNote((raw?['technique'] as Map?)?['long_notes']);
    DataColumn col(String key) => DataColumn(label: Tooltip(message: tr('results.col.$key.tip'), child: Text(tr('results.col.$key'))));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(tr('results.notes'), style: Theme.of(context).textTheme.titleMedium),
        ),
        if (lyrics != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.info_outline, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(tr('results.lyricHint'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.info_outline, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(tr('results.notesHint'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
          ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) => SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth),
              child: DataTable(
                showCheckboxColumn: false,
                columnSpacing: 18,
                headingRowHeight: 36,
                dataRowMinHeight: 28,
                dataRowMaxHeight: 32,
                columns: [
                  const DataColumn(label: Text('#')),
                  if (lyrics != null) DataColumn(label: Text(tr('results.lyric'))),
                  DataColumn(label: Text(tr('results.onset'))),
                  DataColumn(label: Text(tr('results.refPitch'))),
                  DataColumn(label: Tooltip(message: tr('results.col.dev.tip'), child: Text(tr('results.sungDev')))),
                  col('inTune'),
                  col('attack'),
                  col('release'),
                  col('sung'),
                  col('steady'),
                  DataColumn(label: Tooltip(message: tr('results.col.matched.tip'), child: Text(tr('results.matched')))),
                  if (gains != null)
                    DataColumn(
                      label: Tooltip(
                        message: tr('results.col.gain.tip'),
                        child: Text(gainsRunning ? '${tr('results.col.gain')} ${(gainsProgress * 100).round()}%' : tr('results.col.gain'), style: const TextStyle(color: Color(0xFFB57CFF))),
                      ),
                    ),
                  DataColumn(label: Tooltip(message: tr('items.tuningWand.name'), child: const Icon(Icons.auto_fix_high, size: 16))),
                ],
                rows: [
                  for (var i = 0; i < notes.length; i++)
                    DataRow(
                      selected: picked.contains(i),
                      onSelectChanged: onPick == null || wanded.contains(i) || noGain.contains(i) ? null : (_) => onPick!(i),
                      cells: [
                      DataCell(Text('${i + 1}')),
                      if (lyrics != null) DataCell(_lyricCell(context, i < lyrics!.length ? lyrics![i] : null)),
                      DataCell(Text(notes.onset[i].toStringAsFixed(2))),
                      DataCell(Text(noteName(notes.pitch[i] + pitchShift))),
                      DataCell(_centsCell(context, byIndex[i]?.cents)),
                      DataCell(_percentCell(context, (perNote[i]?['pitch_coverage'] as num?)?.toDouble())),
                      DataCell(_callCell(context, rhythm[i]?['onset'] as String?)),
                      DataCell(_callCell(context, rhythm[i]?['offset'] as String?)),
                      DataCell(_percentCell(context, (perNote[i]?['voiced_fraction'] as num?)?.toDouble())),
                      DataCell(_steadyCell(context, longs[i])),
                      DataCell(Icon(byIndex[i]?.matched == true ? Icons.check_circle : Icons.remove_circle_outline,
                          size: 16, color: byIndex[i]?.matched == true ? const Color(0xFF4CD964) : Theme.of(context).colorScheme.outline)),
                      if (gains != null) DataCell(_gainCell(context, wanded.contains(i) ? null : gains![i], pending: gainsRunning && !wanded.contains(i) && !gains!.containsKey(i))),
                      DataCell(wanded.contains(i)
                          ? Tooltip(message: tr('wand.applied'), child: const Icon(Icons.auto_fix_high, size: 18, color: Color(0xFFB57CFF)))
                          : noGain.contains(i)
                          ? const SizedBox.shrink()
                          : Tooltip(
                              message: tr('wand.pickTip'),
                              child: Checkbox(
                                visualDensity: VisualDensity.compact,
                                activeColor: const Color(0xFFB57CFF),
                                value: picked.contains(i),
                                onChanged: onPick == null ? null : (_) => onPick!(i),
                              ),
                            )),
                    ]),
                ],
              ),
              ),
            ),
          )),
        ),
      ],
    );
  }

  static const _good = Color(0xFF4CD964), _near = Color(0xFFFFCC00), _bad = Color(0xFFFF3B30);

  /// 開發模式: the gain from a wand on this note ("…" while worked out).
  Widget _gainCell(BuildContext context, double? gain, {bool pending = false}) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (pending) return Text('…', style: TextStyle(color: muted));
    if (gain == null) return Text('—', style: TextStyle(color: muted));
    if (gain < 0.005) return Text('—', style: TextStyle(color: muted));
    final color = gain >= 0.5 ? const Color(0xFFB57CFF) : (gain >= 0.1 ? const Color(0xFFD9BDFF) : muted);
    // A note can even cost a little (the whole take aligns a bit differently).
    return Text('${gain >= 0 ? '+' : '−'}${gain.abs().toStringAsFixed(2)}', style: TextStyle(color: color, fontWeight: gain >= 0.5 ? FontWeight.w800 : null, fontFeatures: const [FontFeature.tabularFigures()]));
  }

  /// A share (0..1) as a percentage: green from 90 %, yellow from 60 %.
  Widget _percentCell(BuildContext context, double? v) {
    if (v == null) return Text('—', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant));
    final p = (v * 100).round();
    return Text('$p%', style: TextStyle(color: p >= 90 ? _good : (p >= 60 ? _near : _bad), fontFeatures: const [FontFeature.tabularFigures()]));
  }

  /// A rhythm call: PERFECT / GREAT / GOOD / MISS in its colour.
  Widget _callCell(BuildContext context, String? call) {
    if (call == null) return Text('—', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant));
    final color = switch (call) { 'perfect' => _good, 'great' => const Color(0xFF64D2FF), 'good' => _near, _ => _bad };
    return Text(call.toUpperCase(), style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 0.5));
  }

  /// A long note's wobble (cents) beside the original's: green within 10
  /// cents of it, yellow within 40; "—" for short notes.
  Widget _steadyCell(BuildContext context, Map? d) {
    final st = (d?['stability_cents'] as num?)?.toDouble();
    if (st == null) return Text('—', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant));
    final over = st - ((d?['ref_stability_cents'] as num?)?.toDouble() ?? 0);
    return Text('${st.round()}¢', style: TextStyle(color: over <= 10 ? _good : (over <= 40 ? _near : _bad), fontFeatures: const [FontFeature.tabularFigures()]));
  }

  Widget _lyricCell(BuildContext context, String? text) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (text == null) return Text('—', style: TextStyle(color: muted.withValues(alpha: 0.5)));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text == lyricHold ? TextStyle(color: muted) : const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _centsCell(BuildContext context, double? cents) {
    if (cents == null) return Text(tr('results.notAvailable'));
    final a = cents.abs();
    final color = a <= 50 ? const Color(0xFF4CD964) : (a <= 100 ? const Color(0xFFFFCC00) : const Color(0xFFFF3B30));
    return Text('${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)}', style: TextStyle(color: color));
  }
}
