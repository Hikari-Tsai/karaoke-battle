// Replay of a take: the recorded voice over the backing track (same key),
// with the video, lyrics, the reference notes and the sung pitch line drawn
// up to the playhead, and the rhythm judgement of each note popping up as it
// is reached.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/replay_mix.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/live_trace.dart';
import '../../state/lyrics.dart';
import '../../state/note_edits.dart';
import '../../state/replay_session.dart';
import '../../state/scoring_bridge.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../../state/take_trace.dart';
import '../sing/lyrics_overlay.dart';
import '../sing/piano_roll.dart';
import '../sing/video_pane.dart';
import '../widgets/rank.dart';
import '../widgets/judgement_popups.dart';
import '../widgets/voice_fx.dart';

class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key, required this.song, required this.take, this.notesJsonPath, this.player});
  final Song song;
  final TakeInfo take;

  /// Reference notes the take was judged on (an imported replay carries the
  /// sharer's notes); defaults to the song's own notes.json.
  final String? notesJsonPath;

  /// Name of whoever sang an imported replay.
  final String? player;

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> with SingleTickerProviderStateMixin {
  ReplaySession? _session;
  Ticker? _ticker;
  String? _error;
  NoteList? _notes;
  F0Curve? _refF0;
  LiveTrace? _trace;
  Lyrics? _lyrics;
  ScoreData? _score;
  double _pitchShift = 0;
  double _videoAspect = 16 / 9;
  List<JudgementMark> _judgements = const [];
  String _backing = '';
  double _offset = 0;
  bool _remixing = false;
  final _keys = FocusNode(debugLabel: 'replay-keys');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final files = services.library.files(widget.song);
      final take = widget.take;
      var track = 'inst';
      try {
        final info = jsonDecode(await File(take.infoJson).readAsString()) as Map<String, dynamic>;
        _pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
        track = info['track'] as String? ?? 'inst';
      } catch (_) {}
      var backing = track == 'mix' ? files.mixWav : files.instWav;
      if (!await File(backing).exists()) backing = await File(files.instWav).exists() ? files.instWav : files.mixWav;
      final offset = await SingSession.takeTimeOffset(take);

      final notesPath = widget.notesJsonPath ?? files.notesJson;
      final notes = await NoteList.load(notesPath);
      final refF0 = await F0Curve.load(files.refF0Json, confidenceThreshold: 0.5);
      try {
        final nj = jsonDecode(await File(notesPath).readAsString()) as Map<String, dynamic>;
        maskCurve(refF0, excludedSpansFromJson(nj));
      } catch (_) {}
      final score = await ScoringBridge.load(take.scoreJson);
      final takeF0 = await F0Curve.load(take.f0Json, confidenceThreshold: 0.4, timeOffset: offset);
      final trace = buildTakeTrace(notes, takeF0, shift: (score?.shift ?? 0).toDouble(), pitchShift: _pitchShift);
      Lyrics? lyrics;
      try {
        final lf = File(files.lyricsJson);
        if (await lf.exists()) {
          final l = Lyrics.fromJson(jsonDecode(await lf.readAsString()) as Map<String, dynamic>);
          if (!l.isEmpty) lyrics = l;
        }
      } catch (_) {}
      // Rhythm judgements of the take, placed at their notes' onsets; the
      // signed onset error (sung minus expected) gives FAST / LATE.
      final judgements = <JudgementMark>[];
      final rj = score?.raw['rhythm'];
      if (rj is Map) {
        final errors = <int, double>{};
        final nm = score?.raw['note_metrics'];
        if (nm is Map) {
          for (final e in (nm['per_note'] as List? ?? const [])) {
            if (e is Map && e['index'] is num && e['onset_error_ms'] is num) {
              errors[(e['index'] as num).toInt()] = (e['onset_error_ms'] as num).toDouble();
            }
          }
        }
        for (final n in (rj['notes'] as List? ?? const [])) {
          final i = (n['index'] as num).toInt();
          if (i < 0 || i >= notes.length) continue;
          final err = errors[i];
          judgements.add(JudgementMark(
            time: notes.onset[i],
            tier: n['onset'] as String,
            midi: notes.pitch[i] + _pitchShift,
            fast: err == null || err == 0 ? null : err < 0,
          ));
        }
        judgements.sort((a, b) => a.time.compareTo(b.time));
      }

      _backing = backing;
      _offset = offset;
      final wav = await _mix();
      final s = ReplaySession(services.engine, services.settings);
      await s.open(wav);
      if (!mounted) {
        s.dispose();
        return;
      }
      setState(() {
        _session = s;
        _notes = notes;
        _refF0 = refF0;
        _trace = trace;
        _lyrics = lyrics;
        _score = score;
        _judgements = judgements;
      });
      _ticker = createTicker((_) => s.tick())..start();
      s.togglePlay(); // start right away
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Builds (or reuses) the replay audio with the current reverb setting.
  Future<String> _mix() {
    final services = context.read<AppServices>();
    final st = services.settings;
    return ensureReplayMix(
      services.sidecars,
      takeDir: widget.take.dir,
      voiceWav: widget.take.wav,
      backingWav: _backing,
      offsetSeconds: _offset,
      pitchShift: _pitchShift,
      reverbMix: st.reverbOn ? st.reverbMix : 0,
      renderReverb: (i, o, mix) => services.engine.renderReverb(i, o, mix: mix),
    );
  }

  /// Re-renders the mix after the reverb panel closed with a change.
  Future<void> _applyReverb() async {
    final s = _session;
    if (s == null || _remixing) return;
    setState(() => _remixing = true);
    try {
      final wav = await _mix();
      if (mounted && _session == s) s.reload(wav);
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('${tr('error')}: $e')));
    } finally {
      if (mounted) setState(() => _remixing = false);
    }
  }

  @override
  void dispose() {
    _keys.dispose();
    _ticker?.dispose();
    _session?.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) return KeyEventResult.ignored;
    final s = _session;
    if (s == null) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (ev is KeyDownEvent) s.togglePlay();
      return KeyEventResult.handled;
    }
    final d = switch (k) {
      LogicalKeyboardKey.arrowLeft => -5.0,
      LogicalKeyboardKey.arrowRight => 5.0,
      LogicalKeyboardKey.keyJ => -10.0,
      LogicalKeyboardKey.keyL => 10.0,
      _ => 0.0,
    };
    if (d != 0) {
      s.seek(s.position.value + d);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _session;
    final score = _score;
    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerUp: (_) {
          if (!_keys.hasPrimaryFocus) _keys.requestFocus();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text('${tr('replay.title')} — ${widget.song.title}${(widget.player ?? '').isEmpty ? '' : ' · ${widget.player}'}'),
            actions: [
              if (score != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(score.total.toStringAsFixed(1), style: theme.textTheme.titleLarge?.copyWith(color: rankColor(score.rank), fontWeight: FontWeight.w800)),
                    const SizedBox(width: 8),
                    RankChip(rank: score.rank),
                  ]),
                ),
            ],
          ),
          body: _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('${tr('error')}: $_error')))
              : s == null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(tr('replay.preparing')),
                      ]),
                    )
                  : ListenableBuilder(
                      listenable: s,
                      builder: (context, _) => Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Column(children: [
                          Expanded(child: _stage(s)),
                          const SizedBox(height: 10),
                          _controls(s, theme),
                        ]),
                      ),
                    ),
        ),
      ),
    );
  }

  Widget _stage(ReplaySession s) {
    final notes = _notes!;
    final hasVideo = widget.song.hasVideo;
    final range = pitchRangeFor(notes, _pitchShift);
    final files = context.read<AppServices>().library.files(widget.song);
    final stage = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(fit: StackFit.expand, children: [
        if (hasVideo) const ColoredBox(color: Colors.black),
        if (hasVideo)
          Positioned.fill(
            child: VideoPane(
              session: s,
              path: files.videoMp4,
              background: true,
              onAspectRatio: (a) {
                if (mounted && (a - _videoAspect).abs() > 0.01) setState(() => _videoAspect = a);
              },
            ),
          ),
        PianoRollView(
          notes: notes,
          refF0: _refF0!,
          trace: _trace,
          minMidi: range.min,
          maxMidi: range.max,
          position: s.position,
          pitchShift: _pitchShift,
          overlay: hasVideo,
          traceUntilPlayhead: true,
        ),
        if (_lyrics != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: LyricsOverlay(lyrics: _lyrics!, position: s.position, noteOnsets: notes.onset, noteOffsets: notes.offset),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: JudgementLayer(position: s.position, marks: _judgements, minMidi: range.min, maxMidi: range.max),
          ),
        ),
      ]),
    );
    if (!hasVideo) return stage;
    return LayoutBuilder(builder: (context, c) {
      var w = c.maxWidth, h = w / _videoAspect;
      if (h > c.maxHeight) {
        h = c.maxHeight;
        w = h * _videoAspect;
      }
      return Align(alignment: Alignment.topCenter, child: SizedBox(width: w, height: h, child: stage));
    });
  }

  Widget _controls(ReplaySession s, ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          IconButton.filledTonal(
            tooltip: s.playing ? tr('sing.pause') : tr('sing.play'),
            onPressed: s.togglePlay,
            icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(tooltip: tr('sing.restart'), onPressed: () => s.seek(0), icon: const Icon(Icons.replay)),
          if (_remixing)
            const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else
            VoiceFxButton(showReturn: false, offColor: theme.colorScheme.onSurfaceVariant, onClosed: _applyReverb),
          const SizedBox(width: 8),
          ValueListenableBuilder<double>(
            valueListenable: s.position,
            builder: (context, pos, _) => SizedBox(
              width: 100,
              child: Text('${formatDuration(pos)} / ${formatDuration(s.duration)}', style: theme.textTheme.labelMedium),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: s.position,
              builder: (context, pos, _) => Slider(
                value: s.duration > 0 ? pos.clamp(0, s.duration) : 0,
                max: s.duration > 0 ? s.duration : 1,
                onChanged: s.seek,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
