// Song store: one folder per song under <support>/songs/<id>/ with meta.json.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'app_paths.dart';
import '../scoring/models.dart' show readScoreTotal;

enum SourceType { youtube, file }

enum PrepStage { pending, acquire, decode, video, separateVocals, separateInstrumental, transcribe, referenceF0, beats, done, failed }

class Song {
  Song({
    required this.id,
    required this.title,
    required this.sourceType,
    required this.createdAt,
    this.artist = '',
    this.sourceUrl,
    this.youtubeId,
    this.sourceFile,
    this.durationSec,
    this.language = 'zh',
    this.hasVideo = false,
    this.stage = PrepStage.pending,
    this.error,
    this.thumbnailUrl,
    this.gameModelId,
    this.separationQuality,
  });

  final String id;
  String title;
  String artist;
  final SourceType sourceType;
  final DateTime createdAt;
  String? sourceUrl;
  String? youtubeId;
  String? sourceFile; // path of the original media inside the song folder
  double? durationSec;
  String language;
  bool hasVideo;
  PrepStage stage;
  String? error;
  String? thumbnailUrl;
  String? gameModelId;
  String? separationQuality;

  bool get isReady => stage == PrepStage.done;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'source_type': sourceType.name,
        'created_at': createdAt.toIso8601String(),
        'source_url': sourceUrl,
        'youtube_id': youtubeId,
        'source_file': sourceFile,
        'duration_sec': durationSec,
        'language': language,
        'has_video': hasVideo,
        'stage': stage.name,
        'error': error,
        'thumbnail_url': thumbnailUrl,
        'game_model_id': gameModelId,
        'separation_quality': separationQuality,
      };

  static Song fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        sourceType: SourceType.values.byName(j['source_type'] as String? ?? 'file'),
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
        sourceUrl: j['source_url'] as String?,
        youtubeId: j['youtube_id'] as String?,
        sourceFile: j['source_file'] as String?,
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        language: j['language'] as String? ?? 'zh',
        hasVideo: j['has_video'] as bool? ?? false,
        stage: PrepStage.values.byName(j['stage'] as String? ?? 'pending'),
        error: j['error'] as String?,
        thumbnailUrl: j['thumbnail_url'] as String?,
        gameModelId: j['game_model_id'] as String?,
        separationQuality: j['separation_quality'] as String?,
      );
}

/// File names inside a song folder.
class SongFiles {
  SongFiles(this.dir);
  final String dir;
  String get meta => p.join(dir, 'meta.json');
  String get mixWav => p.join(dir, 'mix.wav');
  String get vocalsWav => p.join(dir, 'vocals.wav');
  String get instWav => p.join(dir, 'inst.wav');
  String get videoMp4 => p.join(dir, 'video.mp4');
  String get thumbJpg => p.join(dir, 'thumb.jpg');
  String get lyricsJson => p.join(dir, 'lyrics.json');
  String get beatsJson => p.join(dir, 'beats.json');
  String get tempoJson => p.join(dir, 'tempo.json');
  String get subsDir => p.join(dir, 'subs');
  String get notesJson => p.join(dir, 'notes.json');
  String get refF0Json => p.join(dir, 'ref_f0.json');
  String get takesDir => p.join(dir, 'takes');
  String takeDir(String takeId) => p.join(takesDir, takeId);
}

class TakeInfo {
  TakeInfo({required this.id, required this.dir, required this.createdAt, this.total, this.rank, this.subScores = const {}});
  final String id;
  final String dir;
  final DateTime createdAt;
  final double? total;
  final String? rank;

  /// Sub-scores in percent keyed as in `score.json` `sub_scores_flat`
  /// (pitch, rhythm, stability, vibrato, expression, long_tone); null = not evaluable.
  final Map<String, double?> subScores;
  String get wav => p.join(dir, 'take.wav');
  String get f0Json => p.join(dir, 'take_f0.json');
  String get scoreJson => p.join(dir, 'score.json');
  String get infoJson => p.join(dir, 'take.json');
}

class SongLibrary extends ChangeNotifier {
  SongLibrary(this.paths);
  final AppPaths paths;
  final List<Song> _songs = [];
  List<Song> get songs => List.unmodifiable(_songs);

  SongFiles files(Song s) => SongFiles(paths.songDir(s.id));
  SongFiles filesOf(String id) => SongFiles(paths.songDir(id));

  Future<void> reload() async {
    _songs.clear();
    final root = Directory(paths.songs);
    if (await root.exists()) {
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        final meta = File(p.join(e.path, 'meta.json'));
        if (!await meta.exists()) continue;
        try {
          _songs.add(Song.fromJson(jsonDecode(await meta.readAsString()) as Map<String, dynamic>));
        } catch (_) {}
      }
    }
    _songs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  Song? byId(String id) => _songs.where((s) => s.id == id).firstOrNull;

  Future<Song> create({required String title, required SourceType sourceType, String? sourceUrl, String language = 'zh'}) async {
    final s = Song(id: const Uuid().v4(), title: title, sourceType: sourceType, createdAt: DateTime.now(), sourceUrl: sourceUrl, language: language);
    await Directory(paths.songDir(s.id)).create(recursive: true);
    await save(s);
    _songs.insert(0, s);
    notifyListeners();
    return s;
  }

  Future<void> save(Song s) async {
    final f = File(files(s).meta);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
    notifyListeners();
  }

  Future<void> delete(Song s) async {
    final d = Directory(paths.songDir(s.id));
    if (await d.exists()) await d.delete(recursive: true);
    _songs.removeWhere((x) => x.id == s.id);
    notifyListeners();
  }

  Future<List<TakeInfo>> takes(Song s) async {
    final dir = Directory(files(s).takesDir);
    final out = <TakeInfo>[];
    if (!await dir.exists()) return out;
    await for (final e in dir.list()) {
      if (e is! Directory) continue;
      final id = p.basename(e.path);
      double? total;
      String? rank;
      var subScores = const <String, double?>{};
      final score = File(p.join(e.path, 'score.json'));
      if (await score.exists()) {
        try {
          final j = jsonDecode(await score.readAsString()) as Map<String, dynamic>;
          if (j['total'] is num) {
            // Older files hold raw totals; readScoreTotal converts them.
            final t = readScoreTotal(j);
            total = t.total;
            rank = t.rank;
          }
          final flat = j['sub_scores_flat'];
          if (flat is Map) {
            subScores = {for (final e in flat.entries) '${e.key}': (e.value as num?)?.toDouble()};
          }
        } catch (_) {}
      }
      out.add(TakeInfo(id: id, dir: e.path, createdAt: DateTime.tryParse(id.replaceAll('_', ':')) ?? e.statSync().modified, total: total, rank: rank, subScores: subScores));
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<TakeInfo> newTake(Song s) async {
    final id = DateTime.now().toIso8601String().replaceAll(':', '_').split('.').first;
    final dir = files(s).takeDir(id);
    await Directory(dir).create(recursive: true);
    return TakeInfo(id: id, dir: dir, createdAt: DateTime.now());
  }
}
