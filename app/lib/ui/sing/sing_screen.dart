// The sing screen: video + HUD, scrolling piano roll, transport/record controls.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../results/results_screen.dart';
import 'piano_roll.dart';
import 'lyrics_overlay.dart';
import 'video_pane.dart';
import '../widgets/calibration.dart';

class SingScreen extends StatefulWidget {
  const SingScreen({super.key, required this.song});
  final Song song;

  @override
  State<SingScreen> createState() => _SingScreenState();
}

class _SingScreenState extends State<SingScreen> with SingleTickerProviderStateMixin {
  SingSession? _session;
  Ticker? _ticker;
  String? _loadError;
  bool _busy = false;
  Lyrics? _lyrics;

  Future<void> _loadLyrics(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final l = Lyrics.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      if (mounted && !l.isEmpty) setState(() => _lyrics = l);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      // First use without a latency measurement: offer it before the session
      // opens its own audio device (calibration needs the device to itself).
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await showCalibrationPromptIfNeeded(context, services);
      if (!mounted) return;
      final files = services.library.files(widget.song);
      _loadLyrics(files.lyricsJson);
      final notes = await NoteList.load(files.notesJson);
      final refF0 = await F0Curve.load(files.refF0Json, confidenceThreshold: 0.5);
      final s = SingSession(services: services, song: widget.song, notes: notes, refF0: refF0);
      await s.init();
      if (!mounted) {
        s.dispose();
        return;
      }
      _session = s;
      _ticker = createTicker((_) => s.tick())..start();
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _stopAndScore() async {
    final s = _session!;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final take = await s.stopRecording();
      if (take == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('sing.tooShort'))));
        return;
      }
      final score = await s.processTake(take);
      if (!mounted) return;
      // New personal best for this song? (compare with the other scored takes)
      double? previousBest;
      try {
        for (final t in await context.read<AppServices>().library.takes(widget.song)) {
          if (t.id == take.id || t.total == null) continue;
          if (previousBest == null || t.total! > previousBest) previousBest = t.total;
        }
      } catch (_) {}
      final newRecord = previousBest == null || score.total > previousBest;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ResultsScreen(song: widget.song, take: take, score: score, newRecord: newRecord, previousBest: previousBest),
      ));
    } catch (e) {
      s.processing.value = null;
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('error')),
            content: SelectableText('$e'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('ok')))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.song.title}${widget.song.artist.isNotEmpty ? ' — ${widget.song.artist}' : ''}'),
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: _loadError != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText('${tr('error')}: $_loadError')))
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : ListenableBuilder(
                  listenable: s,
                  builder: (context, _) => Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        child: Column(
                          children: [
                            if (s.initError != null)
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                                child: SelectableText('${tr('sing.audioInitFailed')}: ${s.initError}', style: TextStyle(color: cs.onErrorContainer)),
                              ),
                            // Video / visualiser at a fixed 16:9 (Full HD) aspect,
                            // HUD beside it; the roll takes the rest.
                            SizedBox(
                              height: (MediaQuery.sizeOf(context).height * 0.36).clamp(200.0, 460.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              VideoPane(session: s, path: widget.song.hasVideo ? s.files.videoMp4 : null),
                                              if (_lyrics != null && context.watch<AppSettings>().showLyrics)
                                                Positioned(left: 0, right: 0, bottom: 0, child: LyricsOverlay(lyrics: _lyrics!, position: s.position, noteOnsets: s.notes.onset, noteOffsets: s.notes.offset)),
                                              if (_lyrics != null)
                                                Positioned(
                                                  top: 4,
                                                  right: 4,
                                                  child: LyricsMenu(lyrics: _lyrics!, lyricsPath: s.files.lyricsJson, onChanged: () => setState(() {})),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 280, child: _HudPanel(session: s)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            Expanded(child: _RollArea(session: s)),
                            const SizedBox(height: 10),
                            _Controls(session: s, busy: _busy, onStop: _stopAndScore),
                          ],
                        ),
                      ),
                      ValueListenableBuilder<TakeProcessing?>(
                        valueListenable: s.processing,
                        builder: (context, p, _) => p == null
                            ? const SizedBox.shrink()
                            : Positioned.fill(
                                child: Container(
                                  color: Colors.black54,
                                  alignment: Alignment.center,
                                  child: Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(tr(p.stage), style: Theme.of(context).textTheme.titleMedium),
                                          const SizedBox(height: 16),
                                          SizedBox(width: 280, child: LinearProgressIndicator(value: p.fraction > 0 ? p.fraction : null)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _RollArea extends StatelessWidget {
  const _RollArea({required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final range = pitchRangeFor(session.notes, session.pitchShift);
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          session.setWindowSeconds(session.windowSeconds + (e.scrollDelta.dy > 0 ? 1 : -1));
        }
      },
      child: GestureDetector(
        onTapDown: (d) {
          // Click on the roll seeks (relative to the playhead at 30 %).
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final frac = (d.localPosition.dx - 46) / (box.size.width - 46);
          final t = session.position.value + (frac - 0.3) * session.windowSeconds;
          if (!session.recording) session.seek(t);
        },
        child: PianoRollView(
          notes: session.notes,
          refF0: session.refF0,
          trace: session.trace,
          minMidi: range.min,
          maxMidi: range.max,
          position: session.position,
          windowSeconds: session.windowSeconds,
          pitchShift: session.pitchShift,
        ),
      ),
    );
  }
}

class _HudPanel extends StatelessWidget {
  const _HudPanel({required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ValueListenableBuilder<SingHud>(
          valueListenable: session.hud,
          builder: (context, hud, _) {
            final cents = hud.cents;
            final hasCents = !cents.isNaN;
            final color = !hasCents
                ? cs.onSurface.withValues(alpha: 0.5)
                : (cents.abs() <= 50 ? const Color(0xFF4CD964) : (cents.abs() <= 100 ? const Color(0xFFFFCC00) : const Color(0xFFFF3B30)));
            final level = ((hud.levelDb + 60) / 60).clamp(0.0, 1.0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: _Stat(label: tr('sing.note'), value: hud.voiced ? hud.noteName : '—', big: true, color: color)),
                    Expanded(child: _Stat(label: tr('results.refPitch'), value: hud.refNoteName, big: true)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(tr('sing.cents'), style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                _CentsMeter(cents: hasCents ? cents : null, color: color),
                const SizedBox(height: 4),
                Text(hasCents ? '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)} ¢' : '—', style: theme.textTheme.titleMedium?.copyWith(color: color)),
                const Spacer(),
                Text(tr('sing.mic'), style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                _GatedLevelMeter(level: level, levelDb: hud.levelDb),
                const SizedBox(height: 8),
                Text('${tr('sing.latency')}: ${(session.latencyCompensation * 1000).toStringAsFixed(0)} ms', style: theme.textTheme.labelSmall),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Microphone level meter (PPM) whose noise-gate threshold is set by
/// clicking or dragging on the meter itself (far left = off). The gate is a
/// global setting: it is saved when changed and used for every song.
class _GatedLevelMeter extends StatelessWidget {
  const _GatedLevelMeter({required this.level, required this.levelDb});
  final double level; // 0..1 over -60..0 dBFS
  final double levelDb;

  static double _frac(double db) => ((db + 60) / 60).clamp(0.0, 1.0);

  void _setFromX(AppSettings settings, double x, double width) {
    final frac = (x / width).clamp(0.0, 1.0);
    final db = (-60 + 60 * frac).roundToDouble().clamp(AppSettings.noiseGateOff, AppSettings.noiseGateMax);
    if (db != settings.noiseGateDb) settings.setNoiseGateDb(db);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final gateOn = settings.noiseGateEnabled;
    final gateDb = settings.noiseGateDb;
    final gateFrac = _frac(gateDb);
    final open = !gateOn || levelDb >= gateDb;
    const gold = Color(0xFFFFC107);
    return Tooltip(
      message: tr('sing.gateHint'),
      waitDuration: const Duration(milliseconds: 600),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 22,
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth;
              final gx = w * gateFrac;
              return MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _setFromX(settings, d.localPosition.dx, w),
                  onHorizontalDragStart: (d) => _setFromX(settings, d.localPosition.dx, w),
                  onHorizontalDragUpdate: (d) => _setFromX(settings, d.localPosition.dx, w),
                  child: Stack(clipBehavior: Clip.none, children: [
                    // track
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 4,
                      bottom: 4,
                      child: Container(decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(4))),
                    ),
                    // gated (ignored) zone
                    if (gateOn)
                      Positioned(
                        left: 0,
                        top: 4,
                        bottom: 4,
                        width: gx,
                        child: Container(
                          decoration: BoxDecoration(
                            color: cs.onSurface.withValues(alpha: 0.14),
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(4)),
                          ),
                        ),
                      ),
                    // level
                    Positioned(
                      left: 0,
                      top: 7,
                      bottom: 7,
                      width: w * level,
                      child: Container(
                        decoration: BoxDecoration(
                          color: level > 0.95 ? cs.error : (open ? cs.primary : cs.onSurface.withValues(alpha: 0.35)),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    // threshold handle: line + triangles top and bottom
                    Positioned(
                      left: (gx - 6).clamp(-6.0, w - 6),
                      top: 0,
                      bottom: 0,
                      width: 12,
                      child: CustomPaint(painter: _GateHandlePainter(color: gateOn ? gold : cs.onSurfaceVariant.withValues(alpha: 0.6))),
                    ),
                  ]),
                ),
              );
            }),
          ),
          const SizedBox(height: 2),
          Row(children: [
            Text('${levelDb.toStringAsFixed(0)} dBFS', style: theme.textTheme.labelSmall),
            const Spacer(),
            Icon(Icons.filter_alt_outlined, size: 12, color: gateOn ? gold : cs.onSurfaceVariant),
            const SizedBox(width: 2),
            Text(
              '${tr('sing.gate')} ${gateOn ? '${gateDb.round()} dB' : tr('sing.gateOff')}',
              style: theme.textTheme.labelSmall?.copyWith(color: gateOn ? gold : cs.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ]),
        ],
      ),
    );
  }
}

class _GateHandlePainter extends CustomPainter {
  _GateHandlePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final paint = Paint()..color = color;
    canvas.drawRect(Rect.fromLTWH(cx - 1, 3, 2, size.height - 6), paint);
    canvas.drawPath(Path()..moveTo(cx - 5, 0)..lineTo(cx + 5, 0)..lineTo(cx, 5)..close(), paint);
    canvas.drawPath(Path()..moveTo(cx - 5, size.height)..lineTo(cx + 5, size.height)..lineTo(cx, size.height - 5)..close(), paint);
  }

  @override
  bool shouldRepaint(_GateHandlePainter old) => old.color != color;
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.big = false, this.color});
  final String label;
  final String value;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        Text(value, style: (big ? theme.textTheme.headlineMedium : theme.textTheme.titleMedium)?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _CentsMeter extends StatelessWidget {
  const _CentsMeter({required this.cents, required this.color});
  final double? cents;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 14,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final x = cents == null ? w / 2 : (w / 2 + (cents!.clamp(-100, 100) / 100) * (w / 2 - 4));
          return Stack(
            children: [
              Container(decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(4))),
              Positioned(left: w / 2 - w / 4, width: w / 2, top: 0, bottom: 0, child: Container(color: const Color(0xFF4CD964).withValues(alpha: 0.15))),
              Positioned(left: w / 2 - 1, width: 2, top: 0, bottom: 0, child: Container(color: cs.onSurface.withValues(alpha: 0.4))),
              if (cents != null)
                Positioned(left: x - 4, width: 8, top: 1, bottom: 1, child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)))),
            ],
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.session, required this.busy, required this.onStop});
  final SingSession session;
  final bool busy;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final cs = Theme.of(context).colorScheme;
    final enabled = s.ready && !busy;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: s.position,
                  builder: (context, pos, _) => SizedBox(
                    width: 100,
                    child: Text('${formatDuration(pos)} / ${formatDuration(s.duration)}', style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<double>(
                    valueListenable: s.position,
                    builder: (context, pos, _) => Slider(
                      value: s.duration > 0 ? pos.clamp(0, s.duration) : 0,
                      max: s.duration > 0 ? s.duration : 1,
                      onChanged: enabled && !s.recording ? (v) => s.seek(v) : null,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: s.playing ? tr('sing.pause') : tr('sing.play'),
                  onPressed: enabled ? s.togglePlay : null,
                  icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(tooltip: tr('sing.restart'), onPressed: enabled && !s.recording ? s.restart : null, icon: const Icon(Icons.replay)),
                const SizedBox(width: 8),
                SegmentedButton<TrackKind>(
                  segments: [
                    ButtonSegment(value: TrackKind.inst, label: Text(tr('sing.inst')), enabled: s.hasInst),
                    ButtonSegment(value: TrackKind.mix, label: Text(tr('sing.original')), enabled: s.hasMix),
                  ],
                  selected: {s.track},
                  showSelectedIcon: false,
                  onSelectionChanged: enabled ? (v) => s.setTrack(v.first) : null,
                ),
                const SizedBox(width: 16),
                Text(tr('sing.pitchShift')),
                IconButton(onPressed: enabled ? () => s.setPitchShift(s.pitchShift - 1) : null, icon: const Icon(Icons.remove)),
                SizedBox(width: 28, child: Text('${s.pitchShift >= 0 ? '+' : ''}${s.pitchShift.toInt()}', textAlign: TextAlign.center)),
                IconButton(onPressed: enabled ? () => s.setPitchShift(s.pitchShift + 1) : null, icon: const Icon(Icons.add)),
                const SizedBox(width: 8),
                const Icon(Icons.volume_up, size: 18),
                SizedBox(width: 120, child: Slider(value: s.volume, max: 1.5, onChanged: enabled ? s.setVolume : null)),
                const SizedBox(width: 8),
                Tooltip(
                  message: tr('sing.octaveAlign'),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.swap_vert, size: 18),
                    Switch(value: s.octaveAlign, onChanged: s.setOctaveAlign),
                  ]),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '${tr('sing.window')}: ${s.windowSeconds.toInt()} s',
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.zoom_in, size: 18),
                    SizedBox(width: 100, child: Slider(value: s.windowSeconds, min: 4, max: 16, divisions: 12, onChanged: s.setWindowSeconds)),
                  ]),
                ),
                const Spacer(),
                if (s.recording)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.fiber_manual_record, color: cs.error, size: 16),
                      const SizedBox(width: 4),
                      Text(tr('sing.recording')),
                    ]),
                  ),
                FilledButton.icon(
                  style: s.recording ? FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError) : null,
                  onPressed: enabled ? (s.recording ? onStop : s.startRecording) : null,
                  icon: Icon(s.recording ? Icons.stop : Icons.mic),
                  label: Text(s.recording ? tr('sing.stop') : tr('sing.record')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
