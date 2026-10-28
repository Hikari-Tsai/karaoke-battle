/// Synthetic song / F0 generators shared by the scoring tests.
library;

import 'dart:math' as math;

import 'package:karaoke_battle/scoring/scoring.dart';

/// Deterministic random melody. Consecutive notes always differ by at least
/// one semitone so the take segmentation can separate them.
List<ReferenceNote> makeMelody({
  int seed = 1,
  double duration = 30,
  double startTime = 0.5,
  List<double> durations = const [0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.8],
}) {
  final rng = math.Random(seed);
  final notes = <ReferenceNote>[];
  var t = startTime;
  var pitch = 62.0;
  while (t < duration - 1.0) {
    final dur = durations[rng.nextInt(durations.length)];
    notes.add(ReferenceNote(onset: t, offset: t + dur, pitch: pitch));
    t += dur;
    if (rng.nextInt(4) == 0) t += 0.1 + rng.nextDouble() * 0.4; // rest
    var step = 1 + rng.nextInt(5);
    if (rng.nextBool()) step = -step;
    var next = (pitch + step).clamp(55.0, 72.0);
    if (next == pitch) next = pitch + (pitch > 63 ? -2 : 2);
    pitch = next;
  }
  return notes;
}

/// A melody made only of long notes (for vibrato / long-tone tests).
List<ReferenceNote> makeLongNoteMelody({
  int count = 8,
  double noteSeconds = 1.0,
}) {
  final notes = <ReferenceNote>[];
  var t = 0.5;
  var pitch = 60.0;
  for (var i = 0; i < count; i++) {
    notes.add(ReferenceNote(onset: t, offset: t + noteSeconds, pitch: pitch));
    t += noteSeconds + 0.3;
    pitch += i.isEven ? 2 : -1;
  }
  return notes;
}

/// Pitch (MIDI) of the note sounding at [t], or null during rests.
double? midiOfNotes(List<ReferenceNote> notes, double t) {
  var lo = 0;
  var hi = notes.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final n = notes[mid];
    if (t < n.onset) {
      hi = mid - 1;
    } else if (t >= n.offset) {
      lo = mid + 1;
    } else {
      return n.pitch;
    }
  }
  return null;
}

/// Synthesises an [F0Track] on a uniform grid from a pitch function.
F0Track synthesizeTrack(
  double duration,
  double? Function(double t) midiAt, {
  double hop = 0.016,
}) {
  final n = (duration / hop).ceil() + 1;
  final times = List<double>.generate(n, (g) => g * hop);
  final f0 = List<double>.filled(n, 0.0);
  final conf = List<double>.filled(n, 0.0);
  for (var g = 0; g < n; g++) {
    final m = midiAt(times[g]);
    if (m != null) {
      f0[g] = midiToHz(m);
      conf[g] = 1.0;
    }
  }
  return F0Track(times: times, f0: f0, confidence: conf, hop: hop);
}

/// A loudness curve that swells and decays inside every note.
EnergyCurve synthesizeEnergy(
  List<ReferenceNote> notes,
  double duration, {
  double hop = 0.016,
  double delay = 0,
}) {
  final n = (duration / hop).ceil() + 1;
  final times = List<double>.generate(n, (g) => g * hop);
  final rms = List<double>.generate(n, (g) {
    final t = times[g] - delay;
    for (final note in notes) {
      if (t >= note.onset && t < note.offset) {
        final phase = (t - note.onset) / note.duration;
        return -30.0 +
            15.0 * math.sin(math.pi * phase) +
            2.0 * (note.pitch - 62);
      }
    }
    return -60.0;
  });
  return EnergyCurve(times: times, rmsDb: rms);
}

double songEnd(List<ReferenceNote> notes) => notes.last.offset + 0.5;
