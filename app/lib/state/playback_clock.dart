// A playing track's clock, shared by the sing screen and the replay screen so
// the video, roll and lyrics widgets can follow either.
import 'package:flutter/foundation.dart';

abstract class PlaybackClock {
  /// Track time in seconds.
  ValueListenable<double> get position;

  bool get playing;
}
