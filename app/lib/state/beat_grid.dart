// Beat grid of a song: detected beats (Beat This!, beats.json) combined with
// the user's tempo override (tempo.json): BPM, beats per bar and the time of
// the first downbeat (songs often start with silence or an intro, so the grid
// must be offset to line up). Pure Dart, unit tested.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class DetectedBeats {
  const DetectedBeats({required this.beats, required this.downbeats, this.bpm, this.signature, this.mode = 'unavailable'});
  final List<double> beats;
  final List<double> downbeats;
  final double? bpm;
  final int? signature;
  final String mode; // constant | variable | average | unavailable

  double? get firstDownbeat => downbeats.isNotEmpty ? downbeats.first : (beats.isNotEmpty ? beats.first : null);

  static DetectedBeats fromJson(Map<String, dynamic> j) => DetectedBeats(
        beats: [for (final v in (j['beats'] as List? ?? const [])) (v as num).toDouble()],
        downbeats: [for (final v in (j['downbeats'] as List? ?? const [])) (v as num).toDouble()],
        bpm: (j['bpm'] as num?)?.toDouble(),
        signature: (j['signature_beats'] as num?)?.toInt(),
        mode: j['tempo_mode'] as String? ?? 'unavailable',
      );

  static Future<DetectedBeats?> load(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

/// The user's tempo settings for one song (all optional).
class TempoOverride {
  const TempoOverride({this.bpm, this.firstBeat, this.beatsPerBar});
  final double? bpm;
  final double? firstBeat; // seconds of a downbeat (bar 1, beat 1)
  final int? beatsPerBar;

  bool get isEmpty => bpm == null && firstBeat == null && beatsPerBar == null;

  Map<String, dynamic> toJson() => {'bpm': ?bpm, 'first_beat': ?firstBeat, 'beats_per_bar': ?beatsPerBar};
  static TempoOverride fromJson(Map<String, dynamic> j) => TempoOverride(
        bpm: (j['bpm'] as num?)?.toDouble(),
        firstBeat: (j['first_beat'] as num?)?.toDouble(),
        beatsPerBar: (j['beats_per_bar'] as num?)?.toInt(),
      );

  static Future<TempoOverride> load(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return const TempoOverride();
      return fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return const TempoOverride();
    }
  }

  Future<void> save(String path) async {
    final f = File(path);
    if (isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await f.writeAsString(jsonEncode(toJson()));
  }
}

class BeatGrid {
  const BeatGrid({required this.times, required this.accents, this.bpm, required this.beatsPerBar, this.firstBeat, this.manual = false});
  final List<double> times; // sorted, seconds
  final List<bool> accents; // bar starts
  final double? bpm;
  final int beatsPerBar;
  final double? firstBeat;

  /// Built from a manual BPM (evenly spaced) rather than detected beats.
  final bool manual;

  bool get isEmpty => times.isEmpty;
  static const empty = BeatGrid(times: [], accents: [], beatsPerBar: 4);

  /// Combines detection and override. With a manual BPM the grid is evenly
  /// spaced from the first downbeat (extended back to 0 s so the intro has
  /// beats too); otherwise the detected beats are used, shifted when only the
  /// first beat was moved, with bar accents from the detected downbeats or,
  /// when the bar length was overridden, counted from the first downbeat.
  static BeatGrid build(DetectedBeats? d, TempoOverride o, {required double duration}) {
    final perBar = (o.beatsPerBar ?? d?.signature ?? 4).clamp(1, 16);
    final bpm = o.bpm;
    if (bpm != null && bpm > 0) {
      final period = 60.0 / bpm;
      final first = o.firstBeat ?? d?.firstDownbeat ?? 0.0;
      final k0 = -(first / period).floor();
      final times = <double>[], accents = <bool>[];
      for (var k = k0;; k++) {
        final t = first + k * period;
        if (t > duration) break;
        if (t < 0) continue;
        times.add(t);
        accents.add(((k % perBar) + perBar) % perBar == 0);
      }
      return BeatGrid(times: times, accents: accents, bpm: bpm, beatsPerBar: perBar, firstBeat: first, manual: true);
    }
    if (d == null || d.beats.isEmpty) return BeatGrid(times: const [], accents: const [], beatsPerBar: perBar);
    final detectedFirst = d.firstDownbeat!;
    final shift = o.firstBeat == null ? 0.0 : o.firstBeat! - detectedFirst;
    final times = [for (final t in d.beats) if (t + shift >= 0 && t + shift <= duration) t + shift];
    final List<bool> accents;
    if (o.beatsPerBar == null && d.downbeats.isNotEmpty) {
      final down = {for (final t in d.downbeats) (t * 1000).round()};
      accents = [for (final t in times) down.contains(((t - shift) * 1000).round())];
    } else {
      // Count bars from the beat closest to the (shifted) first downbeat.
      final anchor = detectedFirst + shift;
      var ai = 0;
      for (var i = 1; i < times.length; i++) {
        if ((times[i] - anchor).abs() < (times[ai] - anchor).abs()) ai = i;
      }
      accents = [for (var i = 0; i < times.length; i++) (((i - ai) % perBar) + perBar) % perBar == 0];
    }
    return BeatGrid(times: times, accents: accents, bpm: d.bpm, beatsPerBar: perBar, firstBeat: detectedFirst + shift);
  }

  /// Tap tempo: a least-squares line through the tap times (first tap = a
  /// downbeat). Needs at least 2 taps; null when the taps are not usable.
  static ({double bpm, double firstBeat})? fromTaps(List<double> taps) {
    if (taps.length < 2) return null;
    final n = taps.length;
    final mid = (n - 1) / 2;
    final mean = taps.reduce((a, b) => a + b) / n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (i - mid) * (taps[i] - mean);
      den += (i - mid) * (i - mid);
    }
    final period = num / den;
    if (!(period > 60 / 400) || period > 60 / 20) return null; // 20..400 BPM
    final first = mean - period * mid;
    return (bpm: (60 / period * 10).round() / 10, firstBeat: math.max(0, first));
  }
}
