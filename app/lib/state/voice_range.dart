// How a song's melody sits for a male or a female voice, and the key change
// ("AI 移調") that moves it into each voice's comfortable range.
//
// The song's range is weighted by how long each note is held: the
// tessitura (where most of the singing is, 10th..90th percentile of sung
// time) decides the verdict, so one short high note does not make a song
// "too high" and a long high chorus does.
//
// The key change follows the same rule as the verdict, so a key that "fits"
// is never moved: keep the current key when it fits, else take the fitting
// key closest to the original (ties: less time spent above the range, then
// below), and when no key in reach fits, the one that leaves the tessitura
// least outside the range.
import 'dart:math' as math;

import 'song_data.dart';

enum VoiceType { male, female }

/// Comfortable singing range of an untrained voice (MIDI, inclusive):
/// male A2..F4, female F3..C5.
class VoiceZone {
  const VoiceZone(this.type, this.low, this.high);
  final VoiceType type;
  final double low, high;

  static const male = VoiceZone(VoiceType.male, 45, 65);
  static const female = VoiceZone(VoiceType.female, 53, 72);
  static const all = [male, female];

  static VoiceZone of(VoiceType t) => t == VoiceType.male ? male : female;
}

enum RangeFit { fits, high, low, wide }

class VoiceVerdict {
  const VoiceVerdict(this.zone, this.fit, this.bySemitones);
  final VoiceZone zone;
  final RangeFit fit;

  /// How far the tessitura leaves the zone (semitones, rounded; 0 = fits).
  final int bySemitones;
}

/// The melody's range in the original key (MIDI).
class SongRange {
  const SongRange({required this.lowest, required this.highest, required this.low, required this.high, required this.notes});

  /// Extremes of every note.
  final double lowest, highest;

  /// Tessitura: 10th and 90th percentile of the time spent singing.
  final double low, high;

  /// (pitch, seconds) of every note, for fitting.
  final List<(double, double)> notes;

  bool get isEmpty => notes.isEmpty;

  static const maxShift = 6;

  factory SongRange.of(NoteList n) {
    final notes = <(double, double)>[
      for (var i = 0; i < n.length; i++)
        if (n.offset[i] > n.onset[i] && n.pitch[i].isFinite) (n.pitch[i], n.offset[i] - n.onset[i]),
    ];
    if (notes.isEmpty) return const SongRange(lowest: 60, highest: 60, low: 60, high: 60, notes: []);
    final sorted = [...notes]..sort((a, b) => a.$1.compareTo(b.$1));
    final total = sorted.fold(0.0, (s, e) => s + e.$2);
    double quantile(double q) {
      var acc = 0.0;
      for (final e in sorted) {
        acc += e.$2;
        if (acc >= q * total) return e.$1;
      }
      return sorted.last.$1;
    }

    return SongRange(
      lowest: sorted.first.$1,
      highest: sorted.last.$1,
      low: quantile(0.1),
      high: quantile(0.9),
      notes: notes,
    );
  }

  /// How the tessitura sits in [zone] after a key change of [shift].
  VoiceVerdict verdict(VoiceZone zone, double shift) {
    final over = (high + shift - zone.high).round();
    final under = (zone.low - (low + shift)).round();
    // One semitone of slack either way.
    if (over > 1 && under > 1) return VoiceVerdict(zone, RangeFit.wide, math.max(over, under));
    if (over > 1) return VoiceVerdict(zone, RangeFit.high, over);
    if (under > 1) return VoiceVerdict(zone, RangeFit.low, under);
    return VoiceVerdict(zone, RangeFit.fits, 0);
  }

  /// Share of the sung time above / below [zone] after [shift] (0..1).
  (double above, double below) outside(VoiceZone zone, double shift) {
    var above = 0.0, below = 0.0, total = 0.0;
    for (final (p, d) in notes) {
      final q = p + shift;
      if (q > zone.high + 0.5) above += d;
      if (q < zone.low - 0.5) below += d;
      total += d;
    }
    return total > 0 ? (above / total, below / total) : (0.0, 0.0);
  }

  /// The key change (-6..+6) for [zone] (see the header): [current] stays
  /// when it already fits.
  int bestShift(VoiceZone zone, {int current = 0}) {
    if (isEmpty) return current;
    if (verdict(zone, current.toDouble()).fit == RangeFit.fits) return current;
    final fitting = [
      for (var s = -maxShift; s <= maxShift; s++)
        if (verdict(zone, s.toDouble()).fit == RangeFit.fits) s,
    ];
    if (fitting.isNotEmpty) {
      int key(int s) => s.abs();
      fitting.sort((a, b) {
        final c = key(a).compareTo(key(b));
        if (c != 0) return c;
        final (aa, ab) = outside(zone, a.toDouble());
        final (ba, bb) = outside(zone, b.toDouble());
        final up = aa.compareTo(ba);
        return up != 0 ? up : ab.compareTo(bb);
      });
      return fitting.first;
    }
    // Nothing fits: the least amount of tessitura outside the range.
    var best = 0;
    var bestMiss = double.infinity;
    for (var s = -maxShift; s <= maxShift; s++) {
      final miss = math.max(high + s - zone.high, zone.low - (low + s));
      if (miss < bestMiss - 1e-9 || ((miss - bestMiss).abs() < 1e-9 && s.abs() < best.abs())) {
        bestMiss = miss;
        best = s;
      }
    }
    return best;
  }
}
