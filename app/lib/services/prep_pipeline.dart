// Song preparation pipeline:
//   acquire (yt-dlp | copy file) -> decode (ffmpeg -> mix.wav) -> video.mp4
//   -> separate vocals (Kim_Vocal_2) [-> separate instrumental (Inst_HQ_4)]
//   -> transcribe (GAME) -> reference F0 (SwiftF0) -> done
// Each stage is skipped when its artifact already exists, so a failed or
// cancelled prep can be resumed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import '../state/i18n.dart';
import '../state/loudness.dart';
import '../state/lyrics.dart';
import '../state/romaji.dart';
import 'backend_manager.dart';
import 'model_registry.dart';
import 'settings.dart';
import 'sidecars.dart';
import 'song_library.dart';

class PrepStatus {
  PrepStatus({required this.songId, required this.stage, this.fraction = 0, this.message = ''});
  final String songId;
  final PrepStage stage;
  final double fraction; // within the stage
  final String message;
}

class PrepPipeline extends ChangeNotifier {
  PrepPipeline({
    required this.library,
    required this.sidecars,
    required this.models,
    required this.backend,
    required this.settings,
  });

  final SongLibrary library;
  final Sidecars sidecars;
  final ModelStore models;
  final BackendManager backend;
  final AppSettings settings;

  final Map<String, PrepStatus> _status = {};
  final Map<String, Completer<void>> _cancels = {};
  final Map<String, Completer<void>> _finished = {};
  final Set<String> _cancelling = {};
  final List<String> _queue = [];
  bool _running = false;

  PrepStatus? statusOf(String songId) => _status[songId];

  /// A song is being prepared or waiting in the queue.
  bool get isBusy => _running || _queue.isNotEmpty;
  bool isQueued(String songId) => _queue.contains(songId) || _status[songId] != null;

  void _emit(Song s, PrepStage stage, {double fraction = 0, String message = ''}) {
    if (_cancelling.contains(s.id) && stage != PrepStage.failed) message = tr('library.cancelling');
    _status[s.id] = PrepStatus(songId: s.id, stage: stage, fraction: fraction, message: message);
    notifyListeners();
  }

  /// Enqueues a song. Returns immediately; the queue runs one song at a time.
  void enqueue(Song s) {
    if (isQueued(s.id)) return;
    _queue.add(s.id);
    _emit(s, PrepStage.pending, message: '');
    _pump();
  }

  /// Stops a song's preparation. A song still waiting in the queue leaves it
  /// at once (marked failed, so it can be retried); a running one stops at
  /// its next step. Completes when nothing runs for the song any more.
  Future<void> cancel(String songId) {
    if (_queue.remove(songId)) {
      _status.remove(songId);
      final song = library.byId(songId);
      if (song != null) {
        song
          ..stage = PrepStage.failed
          ..error = tr('library.cancelled');
        unawaited(library.save(song));
      }
      notifyListeners();
      return Future<void>.value();
    }
    final c = _cancels[songId];
    if (c == null) return Future<void>.value();
    if (!c.isCompleted) {
      c.complete();
      _cancelling.add(songId);
      final st = _status[songId];
      if (st != null) {
        _status[songId] = PrepStatus(songId: songId, stage: st.stage, fraction: st.fraction, message: tr('library.cancelling'));
        notifyListeners();
      }
    }
    return _finished[songId]?.future ?? Future<void>.value();
  }

  /// The song is stopping after [cancel].
  bool isCancelling(String songId) => _cancelling.contains(songId);

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.removeAt(0);
        final song = library.byId(id);
        if (song == null) continue;
        final cancel = Completer<void>();
        _cancels[id] = cancel;
        final finished = _finished[id] = Completer<void>();
        try {
          await _run(song, cancel.future);
        } catch (e) {
          final message = cancel.isCompleted ? tr('library.cancelled') : '$e';
          song.stage = PrepStage.failed;
          song.error = message;
          // Not when the song was deleted meanwhile: saving would bring its
          // folder back.
          if (library.byId(id) != null) await library.save(song);
          _emit(song, PrepStage.failed, message: message);
        } finally {
          _cancels.remove(id);
          _cancelling.remove(id);
          _finished.remove(id);
          finished.complete();
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (_status[id]?.stage == PrepStage.done || _status[id]?.stage == PrepStage.failed) {
              _status.remove(id);
              notifyListeners();
            }
          });
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _ensureModels(Song song, Future<void> cancel) async {
    final needed = <ModelSpec>[
      ModelRegistry.swiftF0,
      ModelRegistry.mdxVocals,
      if (settings.separationQuality == SeparationQuality.best) ModelRegistry.mdxInstrumental,
      ModelRegistry.byId(settings.gameModelId),
      ModelRegistry.beatThis,
    ];
    for (final m in needed) {
      if (await models.isInstalled(m)) continue;
      await models.install(m, cancel: cancel, onProgress: (file, dp, done, total) {
        _emit(song, PrepStage.pending, fraction: total > 0 ? done / total : 0, message: '${m.title}: $file');
      });
    }
  }

  Future<void> _run(Song song, Future<void> cancel) async {
    final f = library.files(song);
    var cancelled = false;
    cancel.then((_) => cancelled = true);
    void checkCancel() {
      if (cancelled) throw StateError('cancelled');
    }

    await _ensureModels(song, cancel);
    checkCancel();

    // 1. acquire ---------------------------------------------------------------
    if (song.sourceFile == null || !await File(song.sourceFile!).exists()) {
      song.stage = PrepStage.acquire;
      await library.save(song);
      if (song.sourceType == SourceType.youtube) {
        _emit(song, PrepStage.acquire, message: '');
        final out = await sidecars.downloadVideo(song.sourceUrl!, f.dir, cancel: cancel, onProgress: (frac, line) {
          _emit(song, PrepStage.acquire, fraction: frac < 0 ? 0 : frac, message: line);
        });
        song.sourceFile = out;
      } else {
        throw StateError('source file missing');
      }
      await library.save(song);
    }
    checkCancel();
    song.durationSec ??= await sidecars.duration(song.sourceFile!);
    song.hasVideo = await sidecars.hasVideo(song.sourceFile!);

    // 2. decode ---------------------------------------------------------------
    if (!await File(f.mixWav).exists()) {
      song.stage = PrepStage.decode;
      await library.save(song);
      _emit(song, PrepStage.decode, message: 'WAV');
      await sidecars.toWav(song.sourceFile!, f.mixWav, cancel: cancel, onProgress: (fr) => _emit(song, PrepStage.decode, fraction: fr, message: 'WAV'));
    }
    checkCancel();

    // 3. video ----------------------------------------------------------------
    if (song.hasVideo && !await File(f.videoMp4).exists()) {
      song.stage = PrepStage.video;
      await library.save(song);
      _emit(song, PrepStage.video, message: '');
      try {
        await sidecars.toVideoOnlyMp4(song.sourceFile!, f.videoMp4, cancel: cancel);
      } catch (e) {
        song.hasVideo = false; // audio-only fallback
      }
    }
    checkCancel();

    // 3b. thumbnail, subtitles and romaji (never fatal)
    await ensureThumbnail(song);
    await ensureLyrics(song, ask: true);
    await ensureRomaji(song);
    checkCancel();

    final rt = await backend.runtime();

    // 4. separate vocals ----------------------------------------------------------
    final quality = settings.separationQuality;
    if (!await File(f.vocalsWav).exists()) {
      song.stage = PrepStage.separateVocals;
      await library.save(song);
      final m = ModelRegistry.mdxVocals;
      final job = rt.separate(
        modelPath: models.pathOf(m, m.files.first.name),
        params: m.params,
        inputWav: f.mixWav,
        primaryOut: f.vocalsWav,
        secondaryOut: quality == SeparationQuality.fast ? f.instWav : null,
      );
      await _await(job, cancel, (pr) => _emit(song, PrepStage.separateVocals, fraction: pr.fraction, message: pr.stage));
    }
    checkCancel();

    // 5. separate instrumental ------------------------------------------------------
    if (!await File(f.instWav).exists()) {
      song.stage = PrepStage.separateInstrumental;
      await library.save(song);
      final m = ModelRegistry.mdxInstrumental;
      final job = rt.separate(
        modelPath: models.pathOf(m, m.files.first.name),
        params: m.params,
        inputWav: f.mixWav,
        primaryOut: f.instWav,
      );
      await _await(job, cancel, (pr) => _emit(song, PrepStage.separateInstrumental, fraction: pr.fraction, message: pr.stage));
    }
    checkCancel();

    // 6. transcribe -------------------------------------------------------------------
    if (!await File(f.notesJson).exists()) {
      song.stage = PrepStage.transcribe;
      await library.save(song);
      final m = ModelRegistry.byId(settings.gameModelId);
      final job = rt.transcribe(
        modelDir: models.dirOf(m),
        inputWav: f.vocalsWav,
        options: {'language': song.language},
        notesOut: f.notesJson,
      );
      await _await(job, cancel, (pr) => _emit(song, PrepStage.transcribe, fraction: pr.fraction, message: pr.stage));
      song.gameModelId = m.id;
    }
    checkCancel();

    // 7. reference F0 ---------------------------------------------------------------
    if (!await File(f.refF0Json).exists()) {
      song.stage = PrepStage.referenceF0;
      await library.save(song);
      final m = ModelRegistry.swiftF0;
      final job = rt.f0Extract(modelPath: models.pathOf(m, 'model.onnx'), inputWav: f.vocalsWav, f0Out: f.refF0Json);
      await _await(job, cancel, (pr) => _emit(song, PrepStage.referenceF0, fraction: pr.fraction, message: ''));
    }

    // 8. beats / tempo (Beat This!) -- never fatal --------------------------------
    if (!await File(f.beatsJson).exists()) {
      song.stage = PrepStage.beats;
      await library.save(song);
      try {
        final job = rt.beats(modelDir: models.dirOf(ModelRegistry.beatThis), inputWav: f.mixWav, beatsOut: f.beatsJson);
        await _await(job, cancel, (pr) => _emit(song, PrepStage.beats, fraction: pr.fraction, message: pr.stage));
      } catch (e) {
        checkCancel();
        debugPrint('beats: $e');
      }
    }
    checkCancel();

    // 9. loudness, for the automatic volume -- never fatal -----------------------------
    await ensureLoudness(song);
    checkCancel();

    song.stage = PrepStage.done;
    song.error = null;
    song.separationQuality = quality.name;
    await library.save(song);
    _emit(song, PrepStage.done, fraction: 1, message: '');
  }

  final Set<String> _lyricsInFlight = {};
  final _noLyrics = StreamController<Song>.broadcast();

  /// Songs whose preparation found no lyrics, so the user can be asked to
  /// import a subtitle file or type them in.
  Stream<Song> get noLyrics => _noLyrics.stream;

  /// Downloads a YouTube song's subtitle tracks once and writes lyrics.json
  /// (an empty one when there are none, so it is not retried; local files
  /// always get an empty one). Network failures leave no file, so a later
  /// call retries. With [ask], an empty result is reported on [noLyrics].
  Future<void> ensureLyrics(Song song, {bool ask = false}) async {
    final f = library.files(song);
    if (await File(f.lyricsJson).exists()) return;
    if (!_lyricsInFlight.add(song.id)) return;
    try {
      final url = song.sourceUrl;
      final lyrics = Lyrics.empty();
      if (song.sourceType == SourceType.youtube && url != null) {
        final tracks = await sidecars.subtitleTracks(url);
        final plan = planSubtitles(manual: tracks.manual, auto: tracks.auto, songLanguage: song.language, uiLanguage: I18n.lang);
        lyrics
          ..primary = plan.primary
          ..secondary = plan.secondary;
        if (!plan.isEmpty) {
          await Directory(f.subsDir).create(recursive: true);
          if (plan.manual.isNotEmpty) await sidecars.downloadSubtitles(url, f.subsDir, plan.manual, auto: false);
          if (plan.auto != null) await sidecars.downloadSubtitles(url, f.subsDir, [plan.auto!], auto: true);
          for (final key in [...plan.manual, ?plan.auto]) {
            final file = File(p.join(f.subsDir, 'subs.$key.vtt'));
            if (!await file.exists()) continue;
            final lines = parseVtt(await file.readAsString());
            if (lines.isNotEmpty) lyrics.tracks.add(LyricTrack(lang: key, auto: key == plan.auto, lines: lines));
          }
        }
        if (lyrics.track(lyrics.primary) == null) lyrics.primary = lyrics.tracks.isEmpty ? null : lyrics.tracks.first.lang;
        if (lyrics.track(lyrics.secondary) == null) lyrics.secondary = null;
      }
      await File(f.lyricsJson).writeAsString(jsonEncode(lyrics.toJson()));
      notifyListeners();
      if (ask && lyrics.isEmpty) _noLyrics.add(song);
    } catch (_) {
    } finally {
      _lyricsInFlight.remove(song.id);
    }
  }

  /// The song's lyrics.json, or empty lyrics when it is missing or unreadable.
  Future<Lyrics> loadLyrics(Song song) async {
    try {
      final j = jsonDecode(await File(library.files(song).lyricsJson).readAsString());
      return Lyrics.fromJson((j as Map).cast<String, dynamic>());
    } catch (_) {
      return Lyrics.empty();
    }
  }

  /// Bumped on every [saveLyrics], so a romaji run that read older lyrics
  /// does not write them back.
  final Map<String, int> _lyricsGen = {};
  final Set<String> _romajiAgain = {};

  /// Writes lyrics.json and adds romaji to new Japanese lines.
  Future<void> saveLyrics(Song song, Lyrics lyrics) async {
    _lyricsGen[song.id] = (_lyricsGen[song.id] ?? 0) + 1;
    await File(library.files(song).lyricsJson).writeAsString(jsonEncode(lyrics.toJson()));
    notifyListeners();
    unawaited(ensureRomaji(song).then((_) => notifyListeners()));
  }

  /// Reads a subtitle file (SRT / WebVTT / LRC) into a new track that becomes
  /// the main lyrics. Throws [SubtitleFormatException] for unreadable files.
  Future<LyricTrack> importSubtitles(Song song, String path) async {
    final lines = parseSubtitleFile(p.basename(path), await File(path).readAsBytes());
    final lyrics = await loadLyrics(song);
    final track = LyricTrack(
      lang: lyrics.uniqueKey('${song.language}-x-import'),
      auto: false,
      lines: lines,
      source: LyricSource.imported,
      label: p.basename(path),
    );
    lyrics.putPrimary(track);
    await saveLyrics(song, lyrics);
    return track;
  }

  final Set<String> _beatsQueued = {};
  Future<void> _beatsChain = Future<void>.value();

  final Map<String, Future<SongLoudness?>> _loudnessInFlight = {};

  /// Measures the loudness of a song's instrumental and original tracks once
  /// (loudness.json), for songs prepared before this existed too. Returns
  /// what is known; never throws.
  Future<SongLoudness?> ensureLoudness(Song song) {
    return _loudnessInFlight[song.id] ??= () async {
      try {
        final f = library.files(song);
        final known = await SongLoudness.load(f.loudnessJson);
        if (known != null && known.inst != null && known.mix != null) return known;
        Future<TrackLoudness?> measure(String wav, TrackLoudness? had) async =>
            had ?? (await File(wav).exists() ? await sidecars.measureLoudness(wav) : null);
        final l = SongLoudness(inst: await measure(f.instWav, known?.inst), mix: await measure(f.mixWav, known?.mix));
        if (l.inst == null && l.mix == null) return known;
        if (await Directory(f.dir).exists()) await l.save(f.loudnessJson);
        return l;
      } catch (e) {
        debugPrint('loudness: $e');
        return null;
      } finally {
        _loudnessInFlight.remove(song.id);
      }
    }();
  }

  /// Detects beats for a song prepared before beat tracking existed. Jobs run
  /// one at a time (they share the inference runtime); never fatal.
  Future<void> ensureBeats(Song song) {
    if (song.stage != PrepStage.done || !_beatsQueued.add(song.id)) return _beatsChain;
    _beatsChain = _beatsChain.then((_) async {
      try {
        final f = library.files(song);
        if (await File(f.beatsJson).exists() || !await File(f.mixWav).exists()) return;
        final m = ModelRegistry.beatThis;
        if (!await models.isInstalled(m)) await models.install(m);
        final rt = await backend.runtime();
        await rt.beats(modelDir: models.dirOf(m), inputWav: f.mixWav, beatsOut: f.beatsJson).done;
        notifyListeners();
      } catch (e) {
        debugPrint('beats: $e');
      } finally {
        _beatsQueued.remove(song.id);
      }
    });
    return _beatsChain;
  }

  final Set<String> _romajiInFlight = {};

  /// Adds romaji to the Japanese subtitle tracks of [song]'s lyrics.json.
  /// Downloads the reading pack (kuromoji + IPADIC) on first use and runs it
  /// with Deno. Never fatal: on failure the lyrics simply have no romaji.
  Future<void> ensureRomaji(Song song) async {
    final f = library.files(song);
    final file = File(f.lyricsJson);
    if (!await file.exists()) return;
    if (!_romajiInFlight.add(song.id)) {
      _romajiAgain.add(song.id); // saved while romanising: run again after
      return;
    }
    final gen = _lyricsGen[song.id] ?? 0;
    var rerun = false;
    try {
      final lyrics = Lyrics.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      final todo = lyrics.tracks.where((t) => t.isJapanese && t.romajiVersion < kRomajiVersion).toList();
      if (todo.isEmpty) return;
      final pack = await _ensureJaPack();
      for (final t in todo) {
        final inJson = p.join(sidecars.paths.cache, 'ja_in_${song.id}_${t.lang}.json');
        final outJson = p.join(sidecars.paths.cache, 'ja_out_${song.id}_${t.lang}.json');
        await Directory(sidecars.paths.cache).create(recursive: true);
        await File(inJson).writeAsString(jsonEncode([for (final l in t.lines) l.text]));
        try {
          await sidecars.readJapanese(pack, inJson, outJson);
          final tokens = jsonDecode(await File(outJson).readAsString()) as List;
          t.lines = [
            for (var i = 0; i < t.lines.length; i++)
              t.lines[i].withRomaji(i < tokens.length
                  ? tokensToRomaji([for (final e in tokens[i] as List) JaToken.fromJson((e as Map).cast<String, dynamic>())])
                  : null),
          ];
          t.romajiVersion = kRomajiVersion;
        } finally {
          for (final x in [inJson, outJson]) {
            final tmp = File(x);
            if (await tmp.exists()) await tmp.delete();
          }
        }
      }
      // The user saved newer lyrics meanwhile: never overwrite them.
      if ((_lyricsGen[song.id] ?? 0) != gen) {
        rerun = true;
      } else {
        await file.writeAsString(jsonEncode(lyrics.toJson()));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('romaji: $e');
    } finally {
      _romajiInFlight.remove(song.id);
      if (_romajiAgain.remove(song.id) || rerun) unawaited(ensureRomaji(song));
    }
  }

  /// Installs (download + verify) and extracts the Japanese reading pack;
  /// returns the extracted directory.
  Future<String> _ensureJaPack() async {
    final m = ModelRegistry.jaReading;
    if (!await models.isInstalled(m)) await models.install(m);
    final dir = p.join(models.dirOf(m), 'pack');
    if (!await File(p.join(dir, 'ja_reading.ts')).exists()) {
      final zip = models.pathOf(m, 'kuromoji-pack.zip');
      await Isolate.run(() => extractFileToDisk(zip, dir));
    }
    return dir;
  }

  final Set<String> _thumbInFlight = {};

  /// Makes `thumb.jpg` for the song when missing: the YouTube thumbnail when
  /// there is one, else a frame grabbed from the video at 25 %. Safe to call
  /// from the UI for songs prepared before thumbnails existed.
  Future<void> ensureThumbnail(Song song) async {
    final f = library.files(song);
    if (await File(f.thumbJpg).exists()) return;
    if (!_thumbInFlight.add(song.id)) return;
    try {
      var ok = false;
      if (song.thumbnailUrl != null) ok = await _downloadThumbnail(song.thumbnailUrl!, f.thumbJpg);
      final src = song.sourceFile;
      if (!ok && song.hasVideo && src != null && await File(src).exists()) {
        final at = ((song.durationSec ?? 0) * 0.25).clamp(1.0, 60.0);
        await sidecars.extractFrame(src, f.thumbJpg, atSeconds: at);
        ok = true;
      }
      if (ok) notifyListeners();
    } catch (_) {
    } finally {
      _thumbInFlight.remove(song.id);
    }
  }

  Future<bool> _downloadThumbnail(String url, String out) async {
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200 || resp.bodyBytes.length < 1024) return false;
      await File(out).writeAsBytes(resp.bodyBytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _await(EngineJob job, Future<void> cancel, void Function(JobProgress) onProgress) async {
    final sub = job.progress.listen(onProgress);
    final c = cancel.then((_) => job.cancel());
    try {
      await job.done;
    } finally {
      await sub.cancel();
      c.ignore();
    }
  }

  /// Imports a local media file into a new song folder and enqueues it.
  Future<Song> importFile(String path, {String? title, String language = 'zh'}) async {
    final song = await library.create(title: title ?? p.basenameWithoutExtension(path), sourceType: SourceType.file, language: language);
    final f = library.files(song);
    final dest = p.join(f.dir, 'source${p.extension(path)}');
    await File(path).copy(dest);
    song.sourceFile = dest;
    await library.save(song);
    enqueue(song);
    return song;
  }

  /// Adds a YouTube URL (title fetched via yt-dlp when possible) and enqueues it.
  Future<Song> addUrl(String url, {String language = 'zh'}) async {
    String title = url;
    String? ytId;
    String? thumb;
    double? duration;
    try {
      final info = await sidecars.probeUrl(url);
      title = info['title'] as String? ?? url;
      ytId = info['id'] as String?;
      thumb = info['thumbnail'] as String?;
      duration = (info['duration'] as num?)?.toDouble();
    } catch (_) {}
    final song = await library.create(title: title, sourceType: SourceType.youtube, sourceUrl: url, language: language);
    song.youtubeId = ytId;
    song.thumbnailUrl = thumb;
    song.durationSec = duration;
    await library.save(song);
    enqueue(song);
    return song;
  }
}
