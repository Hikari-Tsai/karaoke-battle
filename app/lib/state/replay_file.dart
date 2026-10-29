// Shareable replay (.json): everything needed to re-watch someone's take on
// another computer: how to find the song, the reference notes the take was
// judged against, the sung pitch curve, the score and the voice recording.
// Exports are a .zip holding this JSON plus the dry vocal as its own audio
// file (`voice.file` names it, next to the JSON). Version-1 files written
// before that embed the voice as base64 AAC (`voice.base64`); both import.
//
// Imported files are untrusted: every field is type- and size-checked, no
// path from the file is ever used, and only a YouTube video id (not a URL)
// is kept for finding the song.
import 'dart:convert';

class ReplayFormatException implements Exception {
  ReplayFormatException(this.code, [this.detail = '']);

  /// notJson | wrongFormat | newerVersion | missing | invalid | tooLarge
  final String code;
  final String detail;

  @override
  String toString() => 'ReplayFormatException($code${detail.isEmpty ? '' : ': $detail'})';
}

class ReplaySong {
  const ReplaySong({required this.title, this.artist = '', this.language = '', this.youtubeId, this.durationSec, this.sourceType = 'file'});
  final String title;
  final String artist;
  final String language;
  final String? youtubeId;
  final double? durationSec;
  final String sourceType; // youtube | file

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'language': language,
        'source_type': sourceType,
        'youtube_id': ?youtubeId,
        'duration_sec': ?durationSec,
      };
}

class ReplayFile {
  ReplayFile({
    required this.player,
    required this.exportedAt,
    required this.appVersion,
    required this.song,
    required this.createdAt,
    required this.pitchShift,
    required this.track,
    required this.timeOffset,
    required this.notes,
    required this.takeF0,
    required this.score,
    this.voiceAacBase64,
    this.voiceFile,
  });

  static const formatName = 'karaoke-battle-replay';
  static const formatVersion = 1;

  // Limits for imported files.
  static const maxTextBytes = 48 * 1024 * 1024;
  static const maxVoiceBase64 = 40 * 1024 * 1024;
  static const maxNotes = 20000;
  static const maxF0Frames = 400000; // ~107 min at 16 ms
  static const maxString = 300;
  static const maxVoiceBytes = 40 * 1024 * 1024;

  /// Audio file types a replay's `voice.file` may name.
  static const voiceExtensions = ['m4a', 'aac', 'mp3', 'wav', 'flac', 'ogg', 'opus'];

  /// A bare file name (no folders) with an allowed audio extension.
  static bool isVoiceFileName(String name) {
    if (name.isEmpty || name.length > 200 || name.startsWith('.')) return false;
    if (RegExp(r'[/\\:\x00-\x1f]').hasMatch(name) || name.contains('..')) return false;
    final dot = name.lastIndexOf('.');
    return dot > 0 && voiceExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  final String player;
  final DateTime exportedAt;
  final String appVersion;
  final ReplaySong song;
  final DateTime createdAt;
  final double pitchShift;
  final String track; // inst | mix
  final double timeOffset; // take time + offset = track time
  final Map<String, dynamic> notes; // notes.json (notes, excluded_spans)
  final Map<String, dynamic> takeF0; // take_f0.json
  final Map<String, dynamic> score; // score.json
  final String? voiceAacBase64; // legacy: voice embedded in the JSON
  final String? voiceFile; // voice stored next to the JSON (bare file name)

  bool get hasVoice => (voiceAacBase64 != null && voiceAacBase64!.isNotEmpty) || voiceFile != null;
  double get total => (score['total'] as num).toDouble();
  String get rank => score['rank'] as String;

  Map<String, dynamic> toJson() => {
        'format': formatName,
        'version': formatVersion,
        'app_version': appVersion,
        'exported_at': exportedAt.toIso8601String(),
        'player': player,
        'song': song.toJson(),
        'take': {
          'created_at': createdAt.toIso8601String(),
          'pitch_shift': pitchShift,
          'track': track,
          'time_offset': timeOffset,
        },
        'notes': notes,
        'take_f0': takeF0,
        'score': score,
        'voice': voiceFile != null
            ? {'codec': 'aac', 'container': 'm4a', 'file': voiceFile}
            : (hasVoice ? {'codec': 'aac', 'container': 'm4a', 'base64': voiceAacBase64} : null),
      };

  String encode() => jsonEncode(toJson());

  // ---------------------------------------------------------------- parsing

  static ReplayFile parse(String text) {
    if (text.length > maxTextBytes) throw ReplayFormatException('tooLarge');
    final Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      throw ReplayFormatException('notJson');
    }
    if (root is! Map || root['format'] != formatName) throw ReplayFormatException('wrongFormat');
    final version = root['version'];
    if (version is! int) throw ReplayFormatException('invalid', 'version');
    if (version > formatVersion) throw ReplayFormatException('newerVersion');

    final song = _map(root['song'], 'song');
    final take = _map(root['take'], 'take');
    final ytRaw = song['youtube_id'];
    final yt = ytRaw is String && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(ytRaw) ? ytRaw : null;
    final track = _str(take['track'], 'take.track', fallback: 'inst');

    final voiceRaw = root['voice'];
    String? voice, voiceFile;
    if (voiceRaw is Map && voiceRaw['file'] != null) {
      final f = voiceRaw['file'];
      if (f is! String || !isVoiceFileName(f)) throw ReplayFormatException('invalid', 'voice.file');
      voiceFile = f;
    } else if (voiceRaw is Map) {
      final b = voiceRaw['base64'];
      if (b is! String) throw ReplayFormatException('invalid', 'voice');
      if (b.length > maxVoiceBase64) throw ReplayFormatException('tooLarge', 'voice');
      if (!RegExp(r'^[A-Za-z0-9+/=\s]*$').hasMatch(b.length > 4096 ? b.substring(0, 4096) : b)) throw ReplayFormatException('invalid', 'voice');
      voice = b;
    }

    return ReplayFile(
      player: _str(root['player'], 'player', fallback: ''),
      exportedAt: _date(root['exported_at']),
      appVersion: _str(root['app_version'], 'app_version', fallback: ''),
      song: ReplaySong(
        title: _str(song['title'], 'song.title'),
        artist: _str(song['artist'], 'song.artist', fallback: ''),
        language: _str(song['language'], 'song.language', fallback: ''),
        sourceType: song['source_type'] == 'youtube' ? 'youtube' : 'file',
        youtubeId: yt,
        durationSec: _numOrNull(song['duration_sec']),
      ),
      createdAt: _date(take['created_at']),
      pitchShift: _num(take['pitch_shift'], 'take.pitch_shift').clamp(-24.0, 24.0),
      track: track == 'mix' ? 'mix' : 'inst',
      timeOffset: _num(take['time_offset'], 'take.time_offset').clamp(-30.0, 30.0),
      notes: _validNotes(_map(root['notes'], 'notes')),
      takeF0: _validF0(_map(root['take_f0'], 'take_f0')),
      score: _validScore(_map(root['score'], 'score')),
      voiceAacBase64: voice,
      voiceFile: voiceFile,
    );
  }

  static Map<String, dynamic> _map(Object? v, String what) {
    if (v is! Map) throw ReplayFormatException('missing', what);
    return v.cast<String, dynamic>();
  }

  static String _str(Object? v, String what, {String? fallback}) {
    if (v == null && fallback != null) return fallback;
    if (v is! String) throw ReplayFormatException('invalid', what);
    return v.length > maxString ? v.substring(0, maxString) : v;
  }

  static double _num(Object? v, String what) {
    if (v is! num || !v.isFinite) throw ReplayFormatException('invalid', what);
    return v.toDouble();
  }

  static double? _numOrNull(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  static DateTime _date(Object? v) => (v is String ? DateTime.tryParse(v) : null) ?? DateTime.fromMillisecondsSinceEpoch(0);

  static List<double> _numbers(Object? v, String what, int max) {
    if (v is! List) throw ReplayFormatException('missing', what);
    if (v.length > max) throw ReplayFormatException('tooLarge', what);
    return [for (final x in v) _num(x, what)];
  }

  static Map<String, dynamic> _validNotes(Map<String, dynamic> j) {
    final raw = j['notes'];
    if (raw is! List) throw ReplayFormatException('missing', 'notes.notes');
    if (raw.length > maxNotes) throw ReplayFormatException('tooLarge', 'notes');
    final notes = <Map<String, double>>[];
    for (final n in raw) {
      if (n is! Map) throw ReplayFormatException('invalid', 'notes');
      notes.add({'onset': _num(n['onset'], 'note.onset'), 'offset': _num(n['offset'], 'note.offset'), 'pitch': _num(n['pitch'], 'note.pitch')});
    }
    final spans = <List<double>>[];
    final rs = j['excluded_spans'];
    if (rs is List) {
      if (rs.length > maxNotes) throw ReplayFormatException('tooLarge', 'excluded_spans');
      for (final s in rs) {
        if (s is List && s.length == 2) spans.add([_num(s[0], 'span'), _num(s[1], 'span')]);
      }
    }
    return {'notes': notes, 'excluded_spans': spans};
  }

  static Map<String, dynamic> _validF0(Map<String, dynamic> j) {
    final times = _numbers(j['times'], 'take_f0.times', maxF0Frames);
    final f0 = _numbers(j['f0'], 'take_f0.f0', maxF0Frames);
    final conf = j['confidence'] == null ? <double>[] : _numbers(j['confidence'], 'take_f0.confidence', maxF0Frames);
    if (f0.length != times.length || (conf.isNotEmpty && conf.length != times.length)) throw ReplayFormatException('invalid', 'take_f0');
    return {
      'hop': _numOrNull(j['hop']) ?? 0.016,
      'sample_rate': (j['sample_rate'] is int) ? j['sample_rate'] : 16000,
      'times': times,
      'f0': f0,
      'confidence': conf,
    };
  }

  static Map<String, dynamic> _validScore(Map<String, dynamic> j) {
    _num(j['total'], 'score.total');
    final rank = j['rank'];
    if (rank is! String || rank.length > 4) throw ReplayFormatException('invalid', 'score.rank');
    // Re-encode so only plain JSON values survive.
    return jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
  }
}
