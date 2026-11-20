// Exporting takes as replay files and keeping imported replays.
//
//   <data>/replays/<id>/replay.json   the imported replay JSON (as received)
//                       meta.json     title, player, score, linked song
//                       notes.json    the reference notes it was judged on
//                       take_f0.json  score.json  take.json  take.wav.json
//                       vocal.mp3     the vocal as received (when included)
//                       lyrics.json   the player's own subtitles (when shared)
//                       song.mp3      the song itself (when the player included it)
//                       cover.jpg     its cover image (when included with it)
//                       backing.mp3   the player's own backing track for it (likewise)
//                       take.wav      the vocal decoded for playback
//
// Exports are a .zip: "<title> <score>.json" plus "<title> <score> vocal.mp3"
// (the dry recording), which the JSON names in voice.file. The JSON carries
// the song's YouTube video id when it has one, so the importer can fetch it,
// and the subtitles the player added themselves (imported, pasted, typed or
// recognised), which are added to the song the first time the replay is
// watched with it. A song from a local file may also bring the song itself
// ("<title> <score> song.mp3", named by song_audio.file) when the player chose
// to include it, with the cover image the player set for it ("... cover.jpg");
// the receiver prepares it like an imported file, so the take lines up with
// exactly the audio it was sung to, and the cover comes along. A backing
// track the player imported for the song ("... backing.mp3", aligned to it)
// travels too and is applied to that song once it is prepared.
//
// The take files use the same names as a song's takes/<id>/ folder, so the
// replay screen plays an imported replay like one of the user's own takes.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../scoring/models.dart' show upgradeScoreJson;
import '../state/lyrics.dart';
import '../state/replay_archive.dart';
import '../state/replay_file.dart';
import 'app_paths.dart';
import 'backing_import.dart';
import 'prep_pipeline.dart';
import 'replay_mix.dart';
import 'sidecars.dart';
import 'song_cover.dart' show isJpeg;
import 'song_library.dart';
import '../state/track_timeline.dart';

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
    this.hasSongAudio = false,
    this.hasCover = false,
    this.hasBacking = false,
    this.youtubeId,
    this.durationSec,
    this.language = '',
    this.sourceType = 'file',
    this.songId,
    this.lyricsAddedTo,
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

  /// The song came with the replay (song.mp3), ready to be prepared.
  final bool hasSongAudio;

  /// The included song's cover came with it (cover.jpg).
  final bool hasCover;

  /// The player's own backing track came with the included song (backing.mp3).
  final bool hasBacking;

  /// The song prepared from the included copy (the backing fits only that one).
  String? includedSongId;

  /// The song the included backing track was applied to (once).
  String? backingAddedTo;
  final String? youtubeId;
  final double? durationSec;
  final String language;
  final String sourceType;

  /// Local song this replay plays against (null until found / added).
  String? songId;

  /// The song the shared subtitles were last added to, so they are added
  /// once (and stay deleted if the user removes them).
  String? lyricsAddedTo;

  String get notesJson => p.join(dir, 'notes.json');
  String get lyricsJson => p.join(dir, 'lyrics.json');
  String get songAudio => p.join(dir, 'song.mp3');
  String get cover => p.join(dir, 'cover.jpg');
  String get backingAudio => p.join(dir, 'backing.mp3');
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
        if (hasSongAudio) 'has_song_audio': true,
        if (hasCover) 'has_cover': true,
        if (hasBacking) 'has_backing': true,
        'included_song_id': ?includedSongId,
        'backing_added_to': ?backingAddedTo,
        'youtube_id': youtubeId,
        'duration_sec': durationSec,
        'language': language,
        'source_type': sourceType,
        'song_id': songId,
        'lyrics_added_to': ?lyricsAddedTo,
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
        hasSongAudio: j['has_song_audio'] == true,
        hasCover: j['has_cover'] == true,
        hasBacking: j['has_backing'] == true,
        youtubeId: j['youtube_id'] as String?,
        durationSec: (j['duration_sec'] as num?)?.toDouble(),
        language: j['language'] as String? ?? '',
        sourceType: j['source_type'] as String? ?? 'file',
        songId: j['song_id'] as String?,
        lyricsAddedTo: j['lyrics_added_to'] as String?,
      )
        ..includedSongId = j['included_song_id'] as String?
        ..backingAddedTo = j['backing_added_to'] as String?;
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
      // The cached audio was built over the previous song's backing track.
      await deleteReplayCache(r.dir);
    }
    r.songId = songId;
    await File(p.join(r.dir, 'meta.json')).writeAsString(jsonEncode(r.toJson()));
    notifyListeners();
  }

  /// Adds the replay's shared subtitles to [song] (once per song). Returns
  /// whether the song's lyrics changed.
  Future<bool> addSharedLyrics(ImportedReplay r, Song song, PrepPipeline pipeline) async {
    if (r.lyricsAddedTo == song.id) return false;
    final f = File(r.lyricsJson);
    if (!await f.exists()) return false;
    final Lyrics shared;
    try {
      shared = Lyrics.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return false;
    }
    final lyrics = await pipeline.loadLyrics(song);
    final changed = mergeSharedLyrics(lyrics, shared);
    if (changed) await pipeline.saveLyrics(song, lyrics);
    r.lyricsAddedTo = song.id;
    await File(p.join(r.dir, 'meta.json')).writeAsString(jsonEncode(r.toJson()));
    return changed;
  }

  /// Adds the song that came with [r] to the library (like an imported
  /// file), starts preparing it and links the replay to it.
  Future<Song> prepareIncludedSong(ImportedReplay r, PrepPipeline pipeline, {required String language}) async {
    if (!r.hasSongAudio || !await File(r.songAudio).exists()) throw StateError('this replay has no song included');
    final song = await pipeline.importFile(r.songAudio, title: r.title, language: language);
    await adoptCover(r, pipeline.library.files(song));
    r.includedSongId = song.id;
    await link(r, song.id);
    return song;
  }

  final Set<String> _backingInFlight = {};

  /// Applies the backing track that came with [r] to [song], once, when that
  /// song was prepared from the included copy (the backing is aligned to
  /// exactly that audio) and is ready. Returns whether it was applied.
  Future<bool> addIncludedBacking(ImportedReplay r, Song song, BackingImport backing) async {
    if (!r.hasBacking || r.includedSongId != song.id || r.backingAddedTo == song.id) return false;
    if (song.stage != PrepStage.done || !await File(r.backingAudio).exists()) return false;
    if (!_backingInFlight.add(r.id)) return false;
    try {
      // The user may have imported a backing of their own meanwhile: keep it.
      final applied = !backing.library.files(song).hasUserInst;
      if (applied) await backing.apply(song, r.backingAudio, 0, sourceName: r.player.isEmpty ? 'replay' : 'replay · ${r.player}');
      r.backingAddedTo = song.id;
      await File(p.join(r.dir, 'meta.json')).writeAsString(jsonEncode(r.toJson()));
      return applied;
    } finally {
      _backingInFlight.remove(r.id);
    }
  }

  /// Gives the song prepared from [r]'s included copy the cover that came with it.
  static Future<void> adoptCover(ImportedReplay r, SongFiles files) async {
    if (!r.hasCover || !await File(r.cover).exists()) return;
    await Directory(files.dir).create(recursive: true);
    await File(r.cover).copy(files.coverJpg);
  }

  Future<void> delete(ImportedReplay r) async {
    final d = Directory(r.dir);
    if (await d.exists()) await d.delete(recursive: true);
    _items.removeWhere((x) => x.id == r.id);
    notifyListeners();
  }

  /// Imports a replay file: the app's .zip export (JSON + vocal MP3, and the
  /// song's MP3 when included), any zip holding replay .json files with their
  /// MP3s (all valid ones are imported), or a plain JSON (its MP3s are looked
  /// up next to it). Throws
  /// [ReplayFormatException] when nothing in the file is a valid replay.
  Future<List<ImportedReplay>> import(String path) async {
    final f = File(path);
    if (await f.length() > ReplayFile.maxTextBytes + ReplayFile.maxVoiceBytes + 2 * ReplayFile.maxSongAudioBytes + ReplayFile.maxCoverBytes) {
      throw ReplayFormatException('tooLarge');
    }
    final bytes = await f.readAsBytes();
    final bundle = await Isolate.run(() => unpackReplays(bytes));
    final imported = <ImportedReplay>[];
    Object? firstError;
    for (final entry in bundle.replays) {
      try {
        imported.add(await _store(entry.text, (name) async {
          final inArchive = bundle.voiceFor(entry, name);
          if (inArchive != null) return inArchive;
          // A JSON picked on its own (e.g. after unzipping): the vocal sits beside it.
          final sibling = File(p.join(p.dirname(path), name));
          if (await sibling.exists() && await sibling.length() <= ReplayFile.maxSongAudioBytes) return sibling.readAsBytes();
          return null;
        }));
      } catch (e) {
        firstError ??= e;
      }
    }
    if (imported.isEmpty) throw firstError ?? ReplayFormatException('emptyArchive');
    return imported;
  }

  Future<ImportedReplay> _store(String text, Future<Uint8List?> Function(String name) findAudio) async {
    final r = ReplayFile.parse(text);
    final id = const Uuid().v4();
    final dir = p.join(root, id);
    await Directory(dir).create(recursive: true);
    try {
      await File(p.join(dir, 'replay.json')).writeAsString(text);
      await File(p.join(dir, 'notes.json')).writeAsString(jsonEncode(r.notes));
      await File(p.join(dir, 'take_f0.json')).writeAsString(jsonEncode(r.takeF0));
      await File(p.join(dir, 'score.json')).writeAsString(jsonEncode(r.score));
      await File(p.join(dir, 'take.json')).writeAsString(jsonEncode({
        'pitch_shift': r.pitchShift,
        'track': r.track,
        if (r.trackTimeline.isNotEmpty) 'track_timeline': [for (final e in r.trackTimeline) e.toJson()],
        'imported': true,
      }));
      // The replay screen maps take time with track_start_offset - latency.
      await File(p.join(dir, 'take.wav.json')).writeAsString(jsonEncode({'track_start_offset': r.timeOffset, 'latency': 0.0}));
      if (r.lyrics != null) await File(p.join(dir, 'lyrics.json')).writeAsString(jsonEncode(r.lyrics!.toJson()));
      var hasVoice = false;
      if (r.voiceFile != null) {
        // voiceFile is a validated bare name, so it is only a lookup key here.
        final data = await findAudio(r.voiceFile!);
        if (data != null) hasVoice = await _decodeVoice(data, dir);
      }
      var hasSongAudio = false;
      if (r.songAudioFile != null) {
        final data = await findAudio(r.songAudioFile!);
        if (data != null && data.length <= ReplayFile.maxSongAudioBytes) {
          await File(p.join(dir, 'song.mp3')).writeAsBytes(data);
          hasSongAudio = true;
        }
      }
      var hasCover = false;
      if (hasSongAudio && r.songCoverFile != null) {
        final data = await findAudio(r.songCoverFile!);
        if (data != null && data.length <= ReplayFile.maxCoverBytes && isJpeg(data)) {
          await File(p.join(dir, 'cover.jpg')).writeAsBytes(data);
          hasCover = true;
        }
      }
      var hasBacking = false;
      if (hasSongAudio && r.backingFile != null) {
        final data = await findAudio(r.backingFile!);
        if (data != null && data.length <= ReplayFile.maxSongAudioBytes) {
          await File(p.join(dir, 'backing.mp3')).writeAsBytes(data);
          hasBacking = true;
        }
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
        hasSongAudio: hasSongAudio,
        hasCover: hasCover,
        hasBacking: hasBacking,
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

  /// Keeps the received vocal as vocal.mp3 and decodes it to take.wav.
  Future<bool> _decodeVoice(Uint8List data, String dir) async {
    final vocal = p.join(dir, 'vocal.mp3');
    await File(vocal).writeAsBytes(data);
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) return false;
    try {
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', vocal, '-ac', '1', '-ar', '44100', '-c:a', 'pcm_s16le', p.join(dir, 'take.wav')]);
      return code == 0 && await File(p.join(dir, 'take.wav')).exists();
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- export

  /// Builds the export .zip for one of the user's takes:
  /// `<baseName>.json` and, when the take has a recording,
  /// `<baseName> vocal.mp3` (the dry a cappella voice, MP3 128 kbps mono).
  /// With [includeSong] (songs from a local file), also `<baseName> song.mp3`:
  /// the song's audio (MP3 192 kbps), on the timeline the take was sung to,
  /// with its cover (`<baseName> cover.jpg`) and the backing track the player
  /// imported for it (`<baseName> backing.mp3`, already aligned) when present.
  /// [baseName] must already be a safe file name (see replayBaseName).
  Future<Uint8List> export({
    required Song song,
    required SongFiles files,
    required TakeInfo take,
    required String player,
    required String baseName,
    bool includeSong = false,
  }) async {
    Map<String, dynamic> readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    var pitchShift = 0.0, track = 'inst', start = 0.0, latency = 0.0;
    var timeline = const <TrackSwitch>[];
    try {
      final info = readJson(take.infoJson);
      pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
      track = info['track'] as String? ?? 'inst';
      timeline = TrackSwitch.listFromJson(info['track_timeline']);
    } catch (_) {}
    try {
      final side = readJson('${take.wav}.json');
      start = (side['track_start_offset'] as num?)?.toDouble() ?? 0;
      latency = (side['latency'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    String? vocalName;
    Uint8List? vocal;
    if (await File(take.wav).exists()) {
      final ff = await sidecars.resolve(SidecarKind.ffmpeg);
      if (ff == null) throw StateError('ffmpeg not available');
      final tmp = p.join(paths.cache, 'export_${take.id}.mp3');
      await Directory(paths.cache).create(recursive: true);
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', take.wav, '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '128k', tmp]);
      if (code != 0) throw StateError('ffmpeg voice export exited with $code');
      vocal = await File(tmp).readAsBytes();
      await File(tmp).delete();
      vocalName = '$baseName vocal.mp3';
      if (!ReplayFile.isVoiceFileName(vocalName)) vocalName = 'vocal.mp3';
    }
    String? songName, coverName, backingName;
    Uint8List? songAudio, coverBytes, backingAudio;
    if (includeSong && song.sourceType == SourceType.file) {
      if (!await File(files.mixWav).exists()) throw StateError('the song audio (mix.wav) is missing');
      final ff = await sidecars.resolve(SidecarKind.ffmpeg);
      if (ff == null) throw StateError('ffmpeg not available');
      final tmp = p.join(paths.cache, 'export_${take.id}_song.mp3');
      await Directory(paths.cache).create(recursive: true);
      Future<Uint8List> mp3(String wav) async {
        final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', wav, '-c:a', 'libmp3lame', '-b:a', '192k', tmp]);
        if (code != 0) throw StateError('ffmpeg song export exited with $code');
        final bytes = await File(tmp).readAsBytes();
        await File(tmp).delete();
        if (bytes.length > ReplayFile.maxSongAudioBytes) throw StateError('the song is too long to include');
        return bytes;
      }

      songAudio = await mp3(files.mixWav);
      if (files.hasUserInst) {
        backingAudio = await mp3(files.userInstWav);
        backingName = '$baseName backing.mp3';
        if (!ReplayFile.isVoiceFileName(backingName)) backingName = 'backing.mp3';
      }
      songName = '$baseName song.mp3';
      if (!ReplayFile.isVoiceFileName(songName) || songName == vocalName) songName = 'song.mp3';
      if (backingName != null && (backingName == vocalName || backingName == songName)) backingName = 'backing.mp3';
      final cover = File(files.coverJpg);
      if (await cover.exists() && await cover.length() <= ReplayFile.maxCoverBytes) {
        coverBytes = await cover.readAsBytes();
        coverName = '$baseName cover.jpg';
        if (!ReplayFile.isCoverFileName(coverName)) coverName = 'cover.jpg';
      }
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
        // A song added from a link whose title lookup failed has no id yet.
        youtubeId: song.youtubeId ?? youtubeIdFromUrl(song.sourceUrl),
        durationSec: song.durationSec,
      ),
      createdAt: take.createdAt,
      pitchShift: pitchShift,
      track: track,
      trackTimeline: timeline,
      timeOffset: start - latency,
      notes: readJson(await take.notesFor(files.notesJson)),
      takeF0: readJson(take.f0Json),
      score: upgradeScoreJson(readJson(take.scoreJson)),
      voiceFile: vocalName,
      songAudioFile: songName,
      songCoverFile: coverName,
      backingFile: backingName,
      lyrics: await _sharedLyrics(files.lyricsJson),
    );
    final zip = Archive()..addFile(ArchiveFile.string('$baseName.json', file.encode()));
    // MP3 is already compressed: store it as is.
    if (vocal != null) zip.addFile(ArchiveFile.noCompress(vocalName!, vocal.length, vocal));
    if (songAudio != null) zip.addFile(ArchiveFile.noCompress(songName!, songAudio.length, songAudio));
    if (coverBytes != null) zip.addFile(ArchiveFile.noCompress(coverName!, coverBytes.length, coverBytes));
    if (backingAudio != null) zip.addFile(ArchiveFile.noCompress(backingName!, backingAudio.length, backingAudio));
    return ZipEncoder().encodeBytes(zip);
  }

  static Future<Lyrics?> _sharedLyrics(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return sharedLyrics(Lyrics.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
    } catch (_) {
      return null;
    }
  }
}
