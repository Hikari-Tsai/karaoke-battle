// What a singer last set for one song on the sing screen (track, key,
// volume, metronome, roll window, octave folding), kept in the song folder so
// each song comes back as it was left and songs never share these. Device,
// latency and microphone settings (vocal return, reverb, noise gate) stay
// global in AppSettings.
import 'dart:convert';
import 'dart:io';

class SongSingSettings {
  const SongSingSettings({
    this.track,
    this.pitchShift = 0,
    this.volume = 1.0,
    this.octaveAlign = true,
    this.windowSeconds = 8,
    this.metronomeOn,
    this.metronomeGain,
  });

  /// 'inst' or 'mix'; null = the default (instrumental when there is one).
  final String? track;
  final double pitchShift; // semitones, -6..6
  final double volume; // 0..1.5
  final bool octaveAlign;
  final double windowSeconds; // 4..16

  /// Null until set for this song: the global setting is used.
  final bool? metronomeOn;
  final double? metronomeGain; // 0..1.5

  static const fileName = 'sing_settings.json';

  /// Reads [path]; a missing or unreadable file gives the defaults.
  static Future<SongSingSettings> load(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return const SongSingSettings();
      final j = jsonDecode(await f.readAsString());
      return j is Map<String, dynamic> ? SongSingSettings.fromJson(j) : const SongSingSettings();
    } catch (_) {
      return const SongSingSettings();
    }
  }

  /// Written through a temporary file, so a crash never leaves half a file.
  Future<void> save(String path) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(path);
  }

  factory SongSingSettings.fromJson(Map<String, dynamic> j) {
    double? num_(String k, double lo, double hi) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : null;
    }

    final track = j['track'];
    return SongSingSettings(
      track: track == 'inst' || track == 'mix' ? track as String : null,
      pitchShift: num_('pitch_shift', -6, 6)?.roundToDouble() ?? 0,
      volume: num_('volume', 0, 1.5) ?? 1.0,
      octaveAlign: j['octave_align'] is bool ? j['octave_align'] as bool : true,
      windowSeconds: num_('window_seconds', 4, 16) ?? 8,
      metronomeOn: j['metronome_on'] is bool ? j['metronome_on'] as bool : null,
      metronomeGain: num_('metronome_gain', 0, 1.5),
    );
  }

  Map<String, dynamic> toJson() => {
        'track': ?track,
        'pitch_shift': pitchShift,
        'volume': volume,
        'octave_align': octaveAlign,
        'window_seconds': windowSeconds,
        'metronome_on': ?metronomeOn,
        'metronome_gain': ?metronomeGain,
      };
}
