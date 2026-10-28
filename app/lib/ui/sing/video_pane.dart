// Muted media_kit video kept in sync with the engine clock (±80 ms).
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
      return _Placeholder(session: widget.session, message: _error == null ? tr('sing.noVideo') : '${tr('sing.noVideo')} ($_error)');
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Video(controller: c, controls: NoVideoControls, fill: Colors.black, wakelock: false, pauseUponEnteringBackgroundMode: false),
    );
  }
}

/// Simple level-driven visualiser used when the song has no video.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.session, required this.message});
  final SingSession session;
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: Colors.black,
        child: ValueListenableBuilder<SingHud>(
          valueListenable: session.hud,
          builder: (context, hud, _) {
            final level = ((hud.levelDb + 60) / 60).clamp(0.0, 1.0);
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 80 + 160 * level,
                  height: 80 + 160 * level,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [cs.primary.withValues(alpha: 0.6), cs.primary.withValues(alpha: 0.0)]),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.music_note, size: 42, color: cs.onSurface.withValues(alpha: 0.5)),
                    const SizedBox(height: 8),
                    Text(message, style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5))),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
