// Shareable replay (.json): everything needed to re-watch someone's take on
// another computer: how to find the song, the reference notes the take was
// judged against, the sung pitch curve and the score. The dry vocal travels
// as an MP3 next to it (`voice.file` names it); exports are a .zip of both.
// Only format version 2 is read; earlier development formats are refused.
// Subtitles the player added themselves (imported, pasted, typed or
// recognised; not the video's own) travel in the optional `lyrics` field,
// so the receiver sees the same lyrics; older apps ignore it.
// A song from a local file may bring the song itself, when the player chose
// to include it: an MP3 of the song's audio named by the optional
// `song_audio.file`, so the receiver can prepare the very same song (and the
// take lines up with it), plus its cover image (JPEG, `song_cover.file`) when
// the player set one and the backing track they imported for it (MP3,
// `backing_audio.file`, already aligned to the song). Older apps ignore them.
//
// Imported files are untrusted: every field is type- and size-checked, no
// path from the file is ever used, and only a YouTube video id is kept for
// finding the song; a file without one (songs from local files) simply has
// no link.
import 'dart:convert';

import '../scoring/models.dart' show upgradeScoreJson;
import 'lyrics.dart';
import 'track_timeline.dart';

class ReplayFormatException implements Exception {
  ReplayFormatException(this.code, [this.detail = '']);

  /// notJson | wrongFormat | oldVersion | newerVersion | missing | invalid | tooLarge | emptyArchive
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

final _youtubeIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

String youtubeWatchUrl(String id) => 'https://www.youtube.com/watch?v=$id';

/// The video id of a YouTube link (watch?v=, youtu.be/, shorts/, embed/,
/// live/, music.youtube.com), or null for anything else. Used on export for
/// a song added from a link whose id was never looked up.
String? youtubeIdFromUrl(String? url) {
  if (url == null || url.length > 2000) return null;
  final u = Uri.tryParse(url.trim());
  if (u == null || (u.scheme != 'https' && u.scheme != 'http')) return null;
  final host = u.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = u.pathSegments.isEmpty ? null : u.pathSegments.first;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    final seg = u.pathSegments;
    if (seg.isNotEmpty && seg.first == 'watch') {
      id = u.queryParameters['v'];
    } else if (seg.length >= 2 && const ['shorts', 'embed', 'live', 'v'].contains(seg.first)) {
      id = seg[1];
    }
  }
  return id != null && _youtubeIdPattern.hasMatch(id) ? id : null;
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
    this.voiceFile,
    this.songAudioFile,
    this.songCoverFile,
    this.backingFile,
    this.trackTimeline = const [],
    this.lyrics,
  });

  static const formatName = 'karaoke-battle-replay';
  static const formatVersion = 2;

  // Limits for imported files.
  static const maxTextBytes = 48 * 1024 * 1024;
  static const maxNotes = 20000;
  static const maxF0Frames = 400000; // ~107 min at 16 ms
  static const maxString = 300;
  static const maxVoiceBytes = 40 * 1024 * 1024;
  static const maxSongAudioBytes = 40 * 1024 * 1024; // ~28 min at 192 kbps
  static const maxCoverBytes = 4 * 1024 * 1024;
  static const maxLyricTracks = 8;
  static const maxLyricLines = 5000;
  static const maxLyricText = 500;

  /// Audio file types a replay's `voice.file` may name.
  static const voiceExtensions = ['mp3'];

  /// A bare file name (no folders) ending in .jpg: the included song's cover.
  static bool isCoverFileName(String name) => _bareName(name) && name.toLowerCase().endsWith('.jpg');

  static bool _bareName(String name) =>
      name.isNotEmpty && name.length <= 200 && !name.startsWith('.') && !RegExp(r'[/\\:\x00-\x1f]').hasMatch(name) && !name.contains('..');

  /// A bare file name (no folders) ending in .mp3.
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
  final String track; // inst | mix | midi: what played at the end of the take

  /// What played under the singer and when it changed (older files: none).
  /// Replays play the accompaniment; this is kept for a faithful replay later.
  final List<TrackSwitch> trackTimeline;
  final double timeOffset; // take time + offset = track time
  final Map<String, dynamic> notes; // notes.json (notes, excluded_spans)
  final Map<String, dynamic> takeF0; // take_f0.json
  final Map<String, dynamic> score; // score.json
  final String? voiceFile; // the vocal MP3 next to the JSON (bare file name)
  final String? songAudioFile; // the song's own audio MP3, when included (bare file name)
  final String? songCoverFile; // its cover JPEG, when included with it (bare file name)
  final String? backingFile; // the player's own backing track MP3 for it, aligned (bare file name)

  /// The player's own subtitle tracks (offsets applied, no romaji), or null.
  final Lyrics? lyrics;

  bool get hasVoice => voiceFile != null;
  bool get hasSongAudio => songAudioFile != null;
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
          if (trackTimeline.isNotEmpty) 'track_timeline': [for (final e in trackTimeline) e.toJson()],
          'time_offset': timeOffset,
        },
        'notes': notes,
        'take_f0': takeF0,
        'score': score,
        'voice': voiceFile != null ? {'codec': 'mp3', 'file': voiceFile} : null,
        if (songAudioFile != null) 'song_audio': {'codec': 'mp3', 'file': songAudioFile},
        if (songAudioFile != null && songCoverFile != null) 'song_cover': {'type': 'jpeg', 'file': songCoverFile},
        if (songAudioFile != null && backingFile != null) 'backing_audio': {'codec': 'mp3', 'file': backingFile},
        if (lyrics != null && !lyrics!.isEmpty)
          'lyrics': {
            'primary': lyrics!.primary,
            'tracks': [
              for (final t in lyrics!.tracks)
                {
                  'lang': t.lang,
                  'source': t.source.name,
                  'label': ?t.label,
                  'lines': [for (final l in t.lines) {'start': l.start, 'end': l.end, 'text': l.text}],
                },
            ],
          },
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
    if (version < formatVersion) throw ReplayFormatException('oldVersion');

    final song = _map(root['song'], 'song');
    final take = _map(root['take'], 'take');
    final ytRaw = song['youtube_id'];
    final yt = ytRaw is String && _youtubeIdPattern.hasMatch(ytRaw) ? ytRaw : null;
    final track = _str(take['track'], 'take.track', fallback: 'inst');

    final voiceRaw = root['voice'];
    String? voiceFile;
    if (voiceRaw != null) {
      final f = voiceRaw is Map ? voiceRaw['file'] : null;
      if (f is! String || !isVoiceFileName(f)) throw ReplayFormatException('invalid', 'voice.file');
      voiceFile = f;
    }
    // A bad song_audio only loses the included song, not the replay.
    final songAudioRaw = root['song_audio'];
    final sa = songAudioRaw is Map ? songAudioRaw['file'] : null;
    final songAudioFile = sa is String && isVoiceFileName(sa) && sa != voiceFile ? sa : null;
    final coverRaw = root['song_cover'];
    final sc = coverRaw is Map ? coverRaw['file'] : null;
    final songCoverFile = songAudioFile != null && sc is String && isCoverFileName(sc) ? sc : null;
    final backingRaw = root['backing_audio'];
    final bf = backingRaw is Map ? backingRaw['file'] : null;
    final backingFile = songAudioFile != null && bf is String && isVoiceFileName(bf) && bf != voiceFile && bf != songAudioFile ? bf : null;

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
      track: track == 'mix' || track == 'midi' ? track : 'inst',
      trackTimeline: TrackSwitch.listFromJson(take['track_timeline']),
      timeOffset: _num(take['time_offset'], 'take.time_offset').clamp(-30.0, 30.0),
      notes: _validNotes(_map(root['notes'], 'notes')),
      takeF0: _validF0(_map(root['take_f0'], 'take_f0')),
      score: _validScore(_map(root['score'], 'score')),
      voiceFile: voiceFile,
      songAudioFile: songAudioFile,
      songCoverFile: songCoverFile,
      backingFile: backingFile,
      lyrics: _validLyrics(root['lyrics']),
    );
  }

  static final _lyricKey = RegExp(r'^[A-Za-z0-9-]{1,40}$');

  /// The shared subtitles, checked like everything else; unusable tracks are
  /// dropped instead of refusing the replay. YouTube tracks are not accepted
  /// (the receiver fetches those from the video).
  static Lyrics? _validLyrics(Object? raw) {
    if (raw is! Map) return null;
    final tracksRaw = raw['tracks'];
    if (tracksRaw is! List) return null;
    final tracks = <LyricTrack>[];
    for (final t in tracksRaw.take(maxLyricTracks)) {
      if (t is! Map) continue;
      final lang = t['lang'], source = LyricSource.values.asNameMap()[t['source']], linesRaw = t['lines'];
      if (lang is! String || !_lyricKey.hasMatch(lang) || source == null || source == LyricSource.youtube) continue;
      if (linesRaw is! List || linesRaw.isEmpty || linesRaw.length > maxLyricLines) continue;
      if (tracks.any((e) => e.lang == lang)) continue;
      final lines = <LyricLine>[];
      for (final l in linesRaw) {
        if (l is! Map) continue;
        final a = l['start'], b = l['end'], text = l['text'];
        if (a is! num || b is! num || !a.isFinite || !b.isFinite || a < 0 || b < a || b > 24 * 3600) continue;
        if (text is! String || text.trim().isEmpty) continue;
        lines.add(LyricLine(a.toDouble(), b.toDouble(), text.length > maxLyricText ? text.substring(0, maxLyricText) : text));
      }
      if (lines.isEmpty) continue;
      lines.sort((x, y) => x.start.compareTo(y.start));
      final label = t['label'];
      tracks.add(LyricTrack(
        lang: lang,
        auto: false,
        lines: lines,
        source: source,
        label: label is String && label.isNotEmpty ? (label.length > maxString ? label.substring(0, maxString) : label) : null,
      ));
    }
    if (tracks.isEmpty) return null;
    final primary = raw['primary'];
    return Lyrics(tracks: tracks, primary: tracks.any((t) => t.lang == primary) ? primary as String : tracks.first.lang);
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
    // Re-encode so only plain JSON values survive, on the current score scale.
    return upgradeScoreJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
  }
}
