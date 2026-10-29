// Exporting takes as replay files and keeping imported replays.
//
//   <data>/replays/<id>/replay.json   the imported file (as received)
//                       meta.json     title, player, score, linked song
//                       notes.json    the reference notes it was judged on
//                       take_f0.json  score.json  take.json  take.wav.json
//                       take.wav      decoded voice (when included)
//
// The take files use the same names as a song's takes/<id>/ folder, so the
// replay screen plays an imported replay like one of the user's own takes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../state/replay_file.dart';
import 'app_paths.dart';
import 'sidecars.dart';
import 'song_library.dart';

class ImportedReplay {
  ImportedReplay({
    required this.id,
    required this.dir,
    required this.title,
    required this.player,
    required this.total,
    required this.rank,
    required this.importedAt,
    required this.createdAt,
    required this.hasVoice,
    this.youtubeId,
    this.durationSec,
    this.language = '',
    this.sourceType = 'file',
    this.songId,
  });

  final String id;
  final String dir;
  final String title;
  final String player;
  final double total;
  final String rank;
  final DateTime importedAt;
  final DateTime createdAt;
  final bool hasVoice;
  final String? youtubeId;
  final double? durationSec;
  final String language;
  final String sourceType;

  /// Local song this replay plays against (null until found / added).
  String? songId;

  String get notesJson => p.join(dir, 'notes.json');
  TakeInfo get take => TakeInfo(id: id, dir: dir, createdAt: createdAt, total: total, rank: rank);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'player': player,
        'total': total,
        'rank': rank,
        'imported_at': importedAt.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'has_voice': hasVoice,
        'youtube_id': youtubeId,
        'duration_sec': durationSec,
        'language': language,
        'source_type': sourceType,
        'song_id': songId,
      };

  static ImportedReplay fromJson(String dir, Map<String, dynamic> j) => ImportedReplay(
        id: j['id'] as String,
        dir: dir,
        title: j['title'] as String? ?? '',
        player: j['player'] as String? ?? '',
        total: (j['total'] as num?)?.toDouble() ?? 0,
        rank: j['rank'] as String? ?? 'D',
        importedAt: DateTime.tryParse(j['imported_at'] as String? ?? '') ?? DateTime.now(),
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
        hasVoice: j['has_voice'] == true,
        youtubeId: j['youtube_id'] as String?,
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        language: j['language'] as String? ?? '',
        sourceType: j['source_type'] as String? ?? 'file',
        songId: j['song_id'] as String?,
      );
}

class ReplayLibrary extends ChangeNotifier {
  ReplayLibrary(this.paths, this.sidecars);
  final AppPaths paths;
  final Sidecars sidecars;

  String get root => p.join(paths.root, 'replays');

  final List<ImportedReplay> _items = [];
  List<ImportedReplay> get items => List.unmodifiable(_items);

  Future<void> reload() async {
    _items.clear();
    final d = Directory(root);
    if (await d.exists()) {
      await for (final e in d.list()) {
        if (e is! Directory) continue;
        try {
          final meta = File(p.join(e.path, 'meta.json'));
          _items.add(ImportedReplay.fromJson(e.path, jsonDecode(await meta.readAsString()) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    _items.sort((a, b) => b.importedAt.compareTo(a.importedAt));
    notifyListeners();
  }

  /// Finds the local song for a replay: same YouTube video, else same title
  /// with a duration within 2 s.
  static Song? findSong(SongLibrary library, ImportedReplay r) {
    if (r.songId != null) {
      final s = library.byId(r.songId!);
      if (s != null) return s;
    }
    final yt = r.youtubeId;
    if (yt != null) {
      for (final s in library.songs) {
        if (s.youtubeId == yt || (s.sourceUrl ?? '').contains(yt)) return s;
      }
    }
    final title = r.title.trim().toLowerCase();
    for (final s in library.songs) {
      if (s.title.trim().toLowerCase() != title) continue;
      final a = s.durationSec, b = r.durationSec;
      if (a == null || b == null || (a - b).abs() <= 2) return s;
    }
    return null;
  }

  Future<void> link(ImportedReplay r, String songId) async {
    if (r.songId != songId) {
      // The cached mix was built over the previous song's backing track.
      final mix = File(p.join(r.dir, 'replay.wav'));
      if (await mix.exists()) await mix.delete();
    }
    r.songId = songId;
    await File(p.join(r.dir, 'meta.json')).writeAsString(jsonEncode(r.toJson()));
    notifyListeners();
  }

  Future<void> delete(ImportedReplay r) async {
    final d = Directory(r.dir);
    if (await d.exists()) await d.delete(recursive: true);
    _items.removeWhere((x) => x.id == r.id);
    notifyListeners();
  }

  /// Imports a replay file; throws [ReplayFormatException] for bad files.
  Future<ImportedReplay> import(String path) async {
    final f = File(path);
    if (await f.length() > ReplayFile.maxTextBytes) throw ReplayFormatException('tooLarge');
    final text = await f.readAsString();
    final r = ReplayFile.parse(text);
    final id = const Uuid().v4();
    final dir = p.join(root, id);
    await Directory(dir).create(recursive: true);
    try {
      await File(p.join(dir, 'replay.json')).writeAsString(text);
      await File(p.join(dir, 'notes.json')).writeAsString(jsonEncode(r.notes));
      await File(p.join(dir, 'take_f0.json')).writeAsString(jsonEncode(r.takeF0));
      await File(p.join(dir, 'score.json')).writeAsString(jsonEncode(r.score));
      await File(p.join(dir, 'take.json')).writeAsString(jsonEncode({'pitch_shift': r.pitchShift, 'track': r.track, 'imported': true}));
      // The replay screen maps take time with track_start_offset - latency.
      await File(p.join(dir, 'take.wav.json')).writeAsString(jsonEncode({'track_start_offset': r.timeOffset, 'latency': 0.0}));
      var hasVoice = false;
      if (r.hasVoice) {
        hasVoice = await _decodeVoice(r.voiceAacBase64!, dir);
      }
      final item = ImportedReplay(
        id: id,
        dir: dir,
        title: r.song.title,
        player: r.player,
        total: r.total,
        rank: r.rank,
        importedAt: DateTime.now(),
        createdAt: r.createdAt,
        hasVoice: hasVoice,
        youtubeId: r.song.youtubeId,
        durationSec: r.song.durationSec,
        language: r.song.language,
        sourceType: r.song.sourceType,
      );
      await File(p.join(dir, 'meta.json')).writeAsString(jsonEncode(item.toJson()));
      _items.insert(0, item);
      notifyListeners();
      return item;
    } catch (_) {
      await Directory(dir).delete(recursive: true);
      rethrow;
    }
  }

  Future<bool> _decodeVoice(String base64Aac, String dir) async {
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) return false;
    final m4a = p.join(dir, 'voice.m4a');
    try {
      await File(m4a).writeAsBytes(base64.decode(base64Aac.replaceAll(RegExp(r'\s'), '')));
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', m4a, '-ac', '1', '-ar', '44100', '-c:a', 'pcm_s16le', p.join(dir, 'take.wav')]);
      return code == 0 && await File(p.join(dir, 'take.wav')).exists();
    } catch (_) {
      return false;
    } finally {
      final f = File(m4a);
      if (await f.exists()) await f.delete();
    }
  }

  // ---------------------------------------------------------------- export

  /// Builds the replay file text for one of the user's takes.
  Future<String> export({
    required Song song,
    required SongFiles files,
    required TakeInfo take,
    required String player,
    required bool includeVoice,
  }) async {
    Map<String, dynamic> readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    var pitchShift = 0.0, track = 'inst', start = 0.0, latency = 0.0;
    try {
      final info = readJson(take.infoJson);
      pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
      track = info['track'] as String? ?? 'inst';
    } catch (_) {}
    try {
      final side = readJson('${take.wav}.json');
      start = (side['track_start_offset'] as num?)?.toDouble() ?? 0;
      latency = (side['latency'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    String? voice;
    if (includeVoice && await File(take.wav).exists()) {
      final ff = await sidecars.resolve(SidecarKind.ffmpeg);
      if (ff == null) throw StateError('ffmpeg not available');
      final tmp = p.join(paths.cache, 'export_${take.id}.m4a');
      await Directory(paths.cache).create(recursive: true);
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', take.wav, '-ac', '1', '-c:a', 'aac', '-b:a', '64k', tmp]);
      if (code != 0) throw StateError('ffmpeg voice export exited with $code');
      voice = base64.encode(await File(tmp).readAsBytes());
      await File(tmp).delete();
    }
    final file = ReplayFile(
      player: player,
      exportedAt: DateTime.now(),
      appVersion: (await PackageInfo.fromPlatform()).version,
      song: ReplaySong(
        title: song.title,
        artist: song.artist,
        language: song.language,
        sourceType: song.sourceType == SourceType.youtube ? 'youtube' : 'file',
        youtubeId: song.youtubeId,
        durationSec: song.durationSec,
      ),
      createdAt: take.createdAt,
      pitchShift: pitchShift,
      track: track,
      timeOffset: start - latency,
      notes: readJson(files.notesJson),
      takeF0: readJson(take.f0Json),
      score: readJson(take.scoreJson),
      voiceAacBase64: voice,
    );
    return file.encode();
  }
}
