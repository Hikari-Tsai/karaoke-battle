// Muted media_kit video kept in sync with the engine clock (±80 ms), or an
// animated pitch/level visualiser when the song has no video.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../state/i18n.dart';
import '../../state/sing_session.dart';

class VideoPane extends StatefulWidget {
  const VideoPane({super.key, required this.session, required this.path});
  final SingSession session;
  final String? path;

  @override
  State<VideoPane> createState() => _VideoPaneState();
}

class _VideoPaneState extends State<VideoPane> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
  bool _opened = false;

  static const _maxDriftMs = 80;

  @override
  void initState() {
    super.initState();
    if (widget.path != null) _open(widget.path!);
    widget.session.position.addListener(_sync);
  }

  Future<void> _open(String path) async {
    try {
      final p = Player();
      final c = VideoController(p);
      _player = p;
      _controller = c;
      await p.setVolume(0);
      await p.open(Media(path), play: false);
      _opened = true;
      if (mounted) setState(() {});
    } catch (e) {
      _error = '$e';
      if (mounted) setState(() {});
    }
  }

  void _sync() {
    final p = _player;
    if (p == null || !_opened) return;
    final s = widget.session;
    final st = p.state;
    if (s.playing != st.playing) {
      s.playing ? p.play() : p.pause();
    }
    final driftMs = (st.position.inMilliseconds - (s.position.value * 1000).round()).abs();
    final now = DateTime.now();
    if (driftMs > _maxDriftMs && now.difference(_lastSeek).inMilliseconds > 300) {
      _lastSeek = now;
      p.seek(Duration(milliseconds: (s.position.value * 1000).round()));
    }
  }

  @override
  void dispose() {
    widget.session.position.removeListener(_sync);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (widget.path == null || _error != null) {
      return Visualizer(session: widget.session, message: _error == null ? tr('sing.noVideo') : '${tr('sing.noVideo')} ($_error)');
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Video(controller: c, controls: NoVideoControls, fill: Colors.black, wakelock: false, pauseUponEnteringBackgroundMode: false),
    );
  }
}

/// Animated visualiser for songs without video: a ring of bars that breathes
/// with the microphone level, a core that glows with pitch accuracy, drifting
/// particles, and the current / reference note in the middle.
class Visualizer extends StatefulWidget {
  const Visualizer({super.key, required this.session, required this.message});
  final SingSession session;
  final String message;

  @override
  State<Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<Visualizer> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
  double _level = 0; // smoothed 0..1
  double _accuracy = 0; // smoothed 0..1 (1 = in tune)
  double _voiced = 0; // smoothed 0..1

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.session;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AnimatedBuilder(
        animation: Listenable.merge([_anim, s.hud, s.position]),
        builder: (context, _) {
          final hud = s.hud.value;
          final targetLevel = ((hud.levelDb + 60) / 60).clamp(0.0, 1.0);
          final targetAcc = hud.voiced && !hud.cents.isNaN ? (1 - (hud.cents.abs() / 100)).clamp(0.0, 1.0) : 0.0;
          _level += (targetLevel - _level) * 0.2;
          _accuracy += (targetAcc - _accuracy) * 0.15;
          _voiced += ((hud.voiced ? 1.0 : 0.0) - _voiced) * 0.15;
          final tone = Color.lerp(const Color(0xFFFF453A), const Color(0xFF30D158), _accuracy)!;
          final accent = Color.lerp(cs.primary, tone, _voiced)!;
          return CustomPaint(
            painter: _VisualizerPainter(
              t: _anim.value,
              level: _level,
              voiced: _voiced,
              accent: accent,
              base: cs.primary,
              playing: s.playing,
              position: s.position.value,
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hud.noteName,
                        style: TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                          color: Colors.white.withValues(alpha: 0.4 + 0.6 * _voiced),
                          shadows: [Shadow(color: accent.withValues(alpha: 0.8 * _voiced), blurRadius: 24)],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hud.voiced && !hud.cents.isNaN ? '${hud.cents >= 0 ? '+' : ''}${hud.cents.round()} cents' : '',
                        style: TextStyle(fontSize: 14, color: tone.withValues(alpha: 0.9 * _voiced), fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${tr('sing.refNote')} ${hud.refNoteName}',
                        style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.55)),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 10,
                  bottom: 8,
                  child: Row(
                    children: [
                      Icon(Icons.music_note, size: 14, color: Colors.white.withValues(alpha: 0.35)),
                      const SizedBox(width: 4),
                      Text(widget.message, style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.35))),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  _VisualizerPainter({
    required this.t,
    required this.level,
    required this.voiced,
    required this.accent,
    required this.base,
    required this.playing,
    required this.position,
  });
  final double t; // 0..1 slow cycle
  final double level;
  final double voiced;
  final Color accent;
  final Color base;
  final bool playing;
  final double position;

  static const _bars = 72;
  static const _particles = 28;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c = rect.center;
    final minSide = math.min(size.width, size.height);

    // Background: deep gradient that slowly shifts hue with the accent.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFF0B0E1A), base, 0.10)!,
            Color.lerp(const Color(0xFF05060C), accent, 0.08)!,
          ],
        ).createShader(rect),
    );

    // Drifting particles (deterministic pseudo-random positions).
    final pp = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < _particles; i++) {
      final seed = i * 0.6180339887;
      final fx = (seed * 7.3) % 1.0;
      final fy = ((seed * 3.1) + t * (0.15 + (i % 5) * 0.05)) % 1.0;
      final r = 1.0 + (i % 3) + level * 1.5;
      final a = 0.08 + 0.25 * ((math.sin((t * 2 * math.pi) + i) + 1) / 2);
      pp.color = Colors.white.withValues(alpha: a);
      canvas.drawCircle(Offset(fx * size.width, (1 - fy) * size.height), r, pp);
    }

    // Core glow.
    final coreR = minSide * (0.16 + 0.10 * level);
    canvas.drawCircle(
      c,
      coreR * 1.9,
      Paint()
        ..shader = RadialGradient(
          colors: [accent.withValues(alpha: 0.28 + 0.3 * voiced), accent.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: c, radius: coreR * 1.9)),
    );

    // Ring of bars: a pseudo-spectrum that breathes with level and ripples
    // with time; it also slowly rotates while playing.
    final inner = minSide * 0.30;
    final rot = (playing ? position * 0.15 : 0) + t * 2 * math.pi * 0.25;
    final bp = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(2.0, minSide * 0.012);
    for (var i = 0; i < _bars; i++) {
      final ang = rot + i * 2 * math.pi / _bars;
      final ripple = 0.5 + 0.5 * math.sin(i * 0.55 + t * 2 * math.pi * 3) * math.sin(i * 0.21 - t * 2 * math.pi * 2);
      final len = minSide * (0.02 + 0.16 * level * (0.4 + 0.6 * ripple) + 0.015 * ripple);
      final a = 0.25 + 0.7 * (0.3 + 0.7 * ripple) * (0.35 + 0.65 * math.max(level, voiced * 0.5));
      bp.color = Color.lerp(base, accent, ripple)!.withValues(alpha: a.clamp(0.0, 1.0));
      final p1 = c + Offset(math.cos(ang), math.sin(ang)) * inner;
      final p2 = c + Offset(math.cos(ang), math.sin(ang)) * (inner + len);
      canvas.drawLine(p1, p2, bp);
    }

    // Thin outer orbit and a progress arc while playing.
    final orbitR = inner + minSide * 0.21;
    canvas.drawCircle(c, orbitR, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.08));
    final dotAng = -math.pi / 2 + t * 2 * math.pi;
    canvas.drawCircle(c + Offset(math.cos(dotAng), math.sin(dotAng)) * orbitR, 3, Paint()..color = accent.withValues(alpha: 0.7));
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter old) => true;
}
