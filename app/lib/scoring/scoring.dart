/// Pure-Dart karaoke scoring: transposition-invariant pitch, DTW time
/// alignment, mir_eval-style frame and note metrics, technique metrics and a
/// weighted 0..100 score. Safe to run inside an isolate.
library;

export 'alignment.dart';
export 'frame_metrics.dart';
export 'live.dart';
export 'models.dart';
export 'note_metrics.dart';
export 'scorer.dart';
export 'technique.dart';
export 'tracks.dart';
