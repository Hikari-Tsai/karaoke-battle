// Loudness of a song's playback tracks (EBU R128 integrated loudness and
// sample peak, measured once with ffmpeg) and the gain that brings a track
// to the target loudness, so songs downloaded at very different levels play
// at about the same level. The volume slider starts at that gain until the
// singer moves it.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class TrackLoudness {
  const TrackLoudness({required this.lufs, required this.peakDb});

  /// Integrated loudness (LUFS); about -70 for silence.
  final double lufs;

  /// Sample peak (dBFS).
  final double peakDb;

  Map<String, dynamic> toJson() => {'lufs': lufs, 'peak_db': peakDb};

  static TrackLoudness? fromJson(Object? j) {
    if (j is! Map) return null;
    final l = j['lufs'], pk = j['peak_db'];
    if (l is! num || pk is! num || !l.isFinite || !pk.isFinite) return null;
    return TrackLoudness(lufs: l.toDouble(), peakDb: pk.toDouble());
  }
}

class SongLoudness {
  const SongLoudness({this.inst, this.mix});
  final TrackLoudness? inst; // instrumental (inst.wav)
  final TrackLoudness? mix; // original (mix.wav)

  static const fileName = 'loudness.json';

  /// Target integrated loudness for the accompaniment. A little under the
  /// -14 LUFS of streaming platforms, leaving room for the voice on top.
  static const targetLufs = -16.0;

  /// The gain never pushes the peak above this (dBFS) ...
  static const peakCeilingDb = -1.0;

  /// ... and stays within the volume slider: -26 dB .. +12 dB.
  static const minGain = 0.05, maxGain = 3.981071705534972; // 10^(12/20)

  /// The volume slider works in decibels (an even feel from quiet to loud):
  /// its left end is mute, then [sliderMinDb] .. [sliderMaxDb].
  static const sliderMinDb = -30.0, sliderMaxDb = 12.0;

  /// Slider position (0..1) of a volume gain.
  static double sliderFromGain(double gain) {
    if (gain <= 0) return 0;
    final db = 20 * math.log(gain) / math.ln10;
    return ((db - sliderMinDb) / (sliderMaxDb - sliderMinDb)).clamp(0.0, 1.0);
  }

  /// Volume gain of a slider position (0..1); the left end mutes.
  static double gainFromSlider(double position) {
    if (position <= 0.005) return 0;
    final db = sliderMinDb + position.clamp(0.0, 1.0) * (sliderMaxDb - sliderMinDb);
    return math.pow(10, db / 20).toDouble();
  }

  /// "+4.0 dB", "-6.5 dB" or "mute" (null) for a gain.
  static String? gainDb(double gain) {
    if (gain <= 0) return null;
    final db = 20 * math.log(gain) / math.ln10;
    return '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';
  }

  TrackLoudness? of(String track) => track == 'mix' ? mix : inst;

  /// Volume that brings [track] ('inst' / 'mix') to [targetLufs], limited by
  /// its peak; null when it was not measured or is (nearly) silent.
  double? autoGain(String track) {
    final t = of(track);
    if (t == null || t.lufs < -60) return null;
    var db = targetLufs - t.lufs;
    db = math.min(db, peakCeilingDb - t.peakDb);
    final g = math.pow(10, db / 20).toDouble();
    return g.clamp(minGain, maxGain);
  }

  static Future<SongLoudness?> load(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      return SongLoudness(inst: TrackLoudness.fromJson(j['inst']), mix: TrackLoudness.fromJson(j['mix']));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String path) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode({'inst': ?inst?.toJson(), 'mix': ?mix?.toJson()}), flush: true);
    await tmp.rename(path);
  }
}

/// Reads ffmpeg's ebur128 summary (the integrated "I:" and the sample
/// "Peak:" lines); null when they are missing.
TrackLoudness? parseEbur128Summary(String stderr) {
  final summary = stderr.lastIndexOf('Summary:');
  final text = summary >= 0 ? stderr.substring(summary) : stderr;
  final i = RegExp(r'I:\s*(-?[\d.]+|-inf)\s*LUFS').firstMatch(text);
  final pk = RegExp(r'Peak:\s*(-?[\d.]+|-inf)\s*dBFS').firstMatch(text);
  if (i == null || pk == null) return null;
  double v(String s) => s == '-inf' ? -120 : double.parse(s);
  return TrackLoudness(lufs: v(i.group(1)!), peakDb: v(pk.group(1)!));
}
