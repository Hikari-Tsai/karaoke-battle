// Replay of a take: the recorded voice over the backing track (same key),
// with the video, lyrics, the reference notes and the sung pitch line drawn
// up to the playhead, and the rhythm judgement of each note popping up as it
// is reached.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/replay_mix.dart';
import '../../services/settings.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/live_trace.dart';
import '../../state/lyrics.dart';
import '../../state/replay_session.dart';
import '../../state/scoring_bridge.dart';
import '../../state/song_data.dart';
import '../sing/lyrics_overlay.dart';
import '../sing/piano_roll.dart';
import '../sing/video_pane.dart';
import '../widgets/rank.dart';
import '../widgets/judgement_popups.dart';
import '../widgets/voice_fx.dart';
import 'replay_data.dart';

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
  final _keys = FocusNode(debugLabel: 'replay-keys');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final d = await loadReplayData(services, widget.song, widget.take, notesJsonPath: widget.notesJsonPath);
      _pitchShift = d.pitchShift;
      final s = ReplaySession(services.engine, services.settings);
      await s.open(d.stems.backing, voice: d.stems.voice);
      if (!mounted) {
        s.dispose();
        return;
      }
      setState(() {
        _session = s;
        _notes = d.notes;
        _refF0 = d.refF0;
        _trace = d.trace;
        _lyrics = d.lyrics;
        _score = d.score;
        _judgements = d.judgements;
      });
      _ticker = createTicker((_) => s.tick())..start();
      s.togglePlay(); // start right away
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
          keyboard: context.watch<AppSettings>().rollKeyboard,
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
          const _KeyboardToggle(),
          // The engine reverberates the voice live: every change is heard at once.
          VoiceFxButton(showReturn: false, offColor: theme.colorScheme.onSurfaceVariant, onPreview: s.setReverb),
          if (s.hasVoice) _BalanceSlider(session: s),
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

/// MIX: the balance between the music (left) and the voice (right), heard
/// while dragging; clicking MIX puts it back in the middle (as mixed).
class _BalanceSlider extends StatefulWidget {
  const _BalanceSlider({required this.session});
  final ReplaySession session;

  @override
  State<_BalanceSlider> createState() => _BalanceSliderState();
}

class _BalanceSliderState extends State<_BalanceSlider> {
  double? _drag;

  String _label(double b) {
    final (music, voice) = replayStemGains(b);
    return tr('replay.balanceLevels', {'voice': '${(voice * 100).round()}', 'music': '${(music * 100).round()}'});
  }

  void _set(double b) {
    setState(() => _drag = null);
    context.read<AppSettings>().setReplayBalance(b);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = context.watch<AppSettings>().replayBalance;
    final b = _drag ?? saved;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: '${tr('replay.balanceTip')}\n${_label(b)}',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: b == 0 ? null : () {
            widget.session.setBalance(0);
            _set(0);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text('MIX',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: b == 0 ? muted.withValues(alpha: 0.45) : theme.colorScheme.primary,
                )),
          ),
        ),
        Icon(Icons.music_note, size: 16, color: muted),
        SizedBox(
          width: 140,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(showValueIndicator: ShowValueIndicator.onDrag),
            child: Slider(
              value: b,
              min: -1,
              max: 1,
              label: _label(b),
              onChanged: (v) {
                // Snaps to the middle near it, so "as mixed" is easy to find.
                final x = v.abs() < 0.05 ? 0.0 : v;
                setState(() => _drag = x);
                widget.session.setBalance(x);
              },
              onChangeEnd: (v) => _set(v.abs() < 0.05 ? 0.0 : v),
            ),
          ),
        ),
        Icon(Icons.mic, size: 16, color: muted),
      ]),
    );
  }
}

/// Piano keyboard in the roll's pitch column: on / off (shared with the
/// sing screen).
class _KeyboardToggle extends StatelessWidget {
  const _KeyboardToggle();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cs = Theme.of(context).colorScheme;
    final on = settings.rollKeyboard;
    return IconButton(
      tooltip: tr(on ? 'sing.keyboardOn' : 'sing.keyboardOff'),
      onPressed: () => settings.setRollKeyboard(!on),
      icon: Icon(Icons.piano, color: on ? cs.primary : cs.onSurfaceVariant.withValues(alpha: 0.5)),
    );
  }
}
