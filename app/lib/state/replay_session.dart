// Plays a take replay (replay.wav) through the audio engine and exposes its
// clock for the video, roll and lyrics.
import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../services/settings.dart';
import 'playback_clock.dart';

class ReplaySession extends ChangeNotifier implements PlaybackClock {
  ReplaySession(this.engine, this.settings);
  final Engine engine;
  final AppSettings settings;

  LiveAudio? _live;
  @override
  final ValueNotifier<double> position = ValueNotifier<double>(0);
  @override
  bool playing = false;
  double duration = 0;

  Future<void> open(String wav) async {
    final l = LiveAudio.create(
      engine,
      captureDevice: settings.captureDeviceId,
      playbackDevice: settings.playbackDeviceId,
      sampleRate: settings.sampleRate,
    );
    _live = l;
    l.loadTrack(wav);
    duration = l.trackDuration;
    notifyListeners();
  }

  /// Swaps in a re-rendered mix, keeping the position and play state.
  void reload(String wav) {
    final l = _live;
    if (l == null) return;
    final pos = position.value;
    final wasPlaying = l.isPlaying;
    if (wasPlaying) l.pause();
    l.loadTrack(wav);
    duration = l.trackDuration;
    l.seek(pos.clamp(0.0, duration > 0 ? duration : pos));
    if (wasPlaying) l.play();
    tick();
    notifyListeners();
  }

  void tick() {
    final l = _live;
    if (l == null) return;
    final p = l.position;
    final pl = l.isPlaying;
    if (pl != playing) {
      playing = pl;
      notifyListeners();
    }
    position.value = p;
  }

  void togglePlay() {
    final l = _live;
    if (l == null) return;
    if (l.isPlaying) {
      l.pause();
    } else {
      if (duration > 0 && position.value >= duration - 0.05) l.seek(0);
      l.play();
    }
    tick();
  }

  void seek(double seconds) {
    _live?.seek(seconds.clamp(0.0, duration > 0 ? duration : seconds));
    tick();
  }

  @override
  void dispose() {
    final l = _live;
    _live = null;
    if (l != null) {
      try {
        if (l.isPlaying) l.pause();
      } catch (_) {}
      l.dispose();
    }
    position.dispose();
    super.dispose();
  }
}
