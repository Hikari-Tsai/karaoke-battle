// The sung pitch line of a recorded take, ready for the piano roll: pitches
// are moved by the scoring shift, folded to the octave of the reference note
// and coloured by distance (good <= 50 cents, near <= 100, off beyond).
import 'live_trace.dart';
import 'song_data.dart';

LiveTrace buildTakeTrace(NoteList notes, F0Curve takeF0, {double shift = 0, double pitchShift = 0}) {
  final trace = LiveTrace(takeF0.length + 1);
  for (var i = 0; i < takeF0.length; i++) {
    final m = takeF0.midi[i];
    if (m.isNaN) continue;
    final refRaw = notes.pitchAt(takeF0.times[i]);
    final ref = refRaw.isNaN ? double.nan : refRaw + pitchShift;
    var display = m + shift;
    var cents = double.nan;
    var cat = PitchCategory.none;
    if (!ref.isNaN) {
      display = foldToOctaveOf(m + shift, ref);
      cents = (display - ref) * 100;
      final a = cents.abs();
      cat = a <= 50 ? PitchCategory.good : (a <= 100 ? PitchCategory.near : PitchCategory.off);
    }
    trace.add(takeF0.times[i], m, display, cents, cat);
  }
  return trace;
}
