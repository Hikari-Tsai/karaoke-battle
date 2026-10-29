// Song preparation pipeline:
//   acquire (yt-dlp | copy file) -> decode (ffmpeg -> mix.wav) -> video.mp4
//   -> separate vocals (Kim_Vocal_2) [-> separate instrumental (Inst_HQ_4)]
//   -> transcribe (GAME) -> reference F0 (SwiftF0) -> done
// Each stage is skipped when its artifact already exists, so a failed or
// cancelled prep can be resumed.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
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
  final List<String> _queue = [];
  bool _running = false;

  PrepStatus? statusOf(String songId) => _status[songId];
  bool isQueued(String songId) => _queue.contains(songId) || _status[songId] != null;

  void _emit(Song s, PrepStage stage, {double fraction = 0, String message = ''}) {
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

  void cancel(String songId) {
    _queue.remove(songId);
    _cancels[songId]?.complete();
  }

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
        try {
          await _run(song, cancel.future);
        } catch (e) {
          song.stage = PrepStage.failed;
          song.error = '$e';
          await library.save(song);
          _emit(song, PrepStage.failed, message: '$e');
        } finally {
          _cancels.remove(id);
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

    // 3b. thumbnail (never fatal)
    await ensureThumbnail(song);
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

    song.stage = PrepStage.done;
    song.error = null;
    song.separationQuality = quality.name;
    await library.save(song);
    _emit(song, PrepStage.done, fraction: 1, message: '');
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
