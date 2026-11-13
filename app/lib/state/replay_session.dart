// Plays a take replay (the backing and voice stems) through the audio engine
// and exposes its clock for the video, roll and lyrics. The hall reverb on the
// voice follows the settings live, while it plays.
import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../services/replay_mix.dart';
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

  Future<void> open(String backing, {String? voice}) async {
    final l = LiveAudio.create(
      engine,
      captureDevice: settings.captureDeviceId,
      playbackDevice: settings.playbackDeviceId,
      sampleRate: settings.sampleRate,
    );
    _live = l;
    l.loadTrack(backing, voice: voice);
    duration = l.trackDuration;
    hasVoice = voice != null;
    _applySettings();
    settings.addListener(_applySettings);
    notifyListeners();
  }

  /// False for a replay shared without its recording (nothing to balance).
  bool hasVoice = false;

  void _applySettings() {
    setReverb(settings.reverbOn, settings.reverbMix);
    setBalance(settings.replayBalance);
  }

  /// Music (-1) to voice (+1) balance, heard at once (see [replayStemGains]).
  void setBalance(double balance) {
    final (music, voice) = replayStemGains(balance);
    try {
      _live?.setStemGains(music, voice);
    } catch (_) {}
  }

  /// Reverb on the voice, heard at once (also while a slider is dragged,
  /// before the setting is saved).
  void setReverb(bool on, double mix) {
    try {
      _live?.setReverb(on, mix);
    } catch (_) {}
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
    settings.removeListener(_applySettings);
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
