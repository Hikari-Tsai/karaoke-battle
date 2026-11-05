// Lyrics from the song itself:
//  * recognise: Whisper large-v3 transcribes the separated vocals into
//    timed lines (for songs without any lyrics);
//  * align: lyrics the user pasted get their times, from the GAME notes
//    (instant) or from Whisper (slower, finds the right phrase more often).
// The result is saved as a new track that becomes the main lyrics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/lyric_align.dart';
import '../state/lyrics.dart';
import '../state/song_data.dart';
import '../state/whisper_tokenizer.dart';
import 'backend_manager.dart';
import 'model_registry.dart';
import 'prep_pipeline.dart';
import 'song_library.dart';

/// Progress of a recognition: 0..1 and a stage key ('load', 'recognize').
typedef RecognizeProgress = void Function(double fraction, String stage);

class LyricsRecognizer {
  LyricsRecognizer({required this.library, required this.models, required this.backend, required this.pipeline});
  final SongLibrary library;
  final ModelStore models;
  final BackendManager backend;
  final PrepPipeline pipeline;

  static WhisperTokenizer? _tokenizer;

  ModelSpec get model => ModelRegistry.whisperLarge;
  Future<bool> get modelInstalled => models.isInstalled(model);

  /// The audio Whisper listens to: the vocal stem, else the full mix.
  String? audioFor(Song song) {
    final f = library.files(song);
    for (final path in [f.vocalsWav, f.mixWav]) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Notes from the song's preparation (GAME), possibly hand edited.
  Future<NoteList> _notes(Song song) async {
    try {
      final j = jsonDecode(await File(library.files(song).notesJson).readAsString());
      return NoteList.fromJson((j as Map).cast<String, dynamic>());
    } catch (_) {
      return NoteList.empty();
    }
  }

  bool hasNotes(Song song) => File(library.files(song).notesJson).existsSync();

  // ---- Whisper ------------------------------------------------------------------

  static String _whisperLang(String songLanguage) => switch (songLanguage) {
        'yue' => 'yue',
        'ja' => 'ja',
        'en' => 'en',
        'ko' => 'ko',
        _ => 'zh',
      };

  /// A short "previous text" that sets the script: Whisper writes
  /// Simplified Chinese unless the context is Traditional. Other languages
  /// get none (a Japanese prompt was echoed back instead of the lyrics).
  static String _stylePrompt(String songLanguage) => switch (songLanguage) {
        'yue' => '以下係粵語歌詞。',
        'zh' => '以下是繁體中文的歌詞。',
        _ => '',
      };

  /// Runs Whisper on [song]; returns the recognised segments.
  Future<List<TimedText>> _whisper(Song song, {RecognizeProgress? onProgress, Completer<void>? cancel}) async {
    final audio = audioFor(song);
    if (audio == null) throw StateError('not prepared');
    final dir = models.dirOf(model);
    final tok = _tokenizer ??= await WhisperTokenizer.load(dir);
    final lang = _whisperLang(song.language);
    final prompt = _stylePrompt(song.language);
    final options = <String, dynamic>{
      'language_token': tok.special('<|$lang|>') ?? tok.special('<|zh|>'),
      'task_token': tok.special('<|transcribe|>'),
      'prompt_tokens': tok.encode(prompt),
      'condition_on_previous': true,
    };
    final out = p.join(library.files(song).dir, 'whisper.json');
    final rt = await backend.runtime();
    final job = rt.whisper(modelDir: dir, inputWav: audio, options: options, out: out);
    final sub = job.progress.listen((pr) => onProgress?.call(pr.fraction, pr.stage));
    unawaited(cancel?.future.then((_) => job.cancel()));
    try {
      await job.done;
    } finally {
      await sub.cancel();
    }
    final j = jsonDecode(await File(out).readAsString()) as Map;
    return [
      for (final s in j['segments'] as List)
        TimedText((s['start'] as num).toDouble(), (s['end'] as num).toDouble(), tok.decode((s['tokens'] as List).cast<int>()).trim()),
    ].where((s) => s.text.isNotEmpty && !isLikelyHallucination(s.text) && !echoesPrompt(s.text, prompt)).toList();
  }

  /// Recognises the lyrics of [song] and makes them the main lyrics.
  Future<LyricTrack> recognize(Song song, {RecognizeProgress? onProgress, Completer<void>? cancel}) async {
    final segments = await _whisper(song, onProgress: onProgress, cancel: cancel);
    final notes = await _notes(song);
    final lines = linesFromSegments(segments, notes.onset, notes.offset);
    return _save(song, LyricSource.whisper, '${song.language}-x-whisper', lines);
  }

  /// Times the pasted [text] (one line per row) and makes it the main
  /// lyrics: with Whisper when [useWhisper], else from the notes.
  Future<LyricTrack> align(Song song, String text, {required bool useWhisper, RecognizeProgress? onProgress, Completer<void>? cancel}) async {
    final rows = splitLyricLines(text);
    if (rows.isEmpty) throw StateError('no lyrics');
    final notes = await _notes(song);
    final List<LyricLine> lines;
    if (useWhisper) {
      final segments = await _whisper(song, onProgress: onProgress, cancel: cancel);
      lines = alignWithWhisper(rows, segments, notes.onset, notes.offset);
    } else {
      onProgress?.call(0.5, 'align');
      lines = alignToNotes(rows, notes.onset, notes.offset);
    }
    return _save(song, LyricSource.aligned, '${song.language}-x-paste', lines);
  }

  Future<LyricTrack> _save(Song song, LyricSource source, String key, List<LyricLine> lines) async {
    final lyrics = await pipeline.loadLyrics(song);
    final track = LyricTrack(lang: lyrics.uniqueKey(key), auto: false, lines: lines, source: source);
    lyrics.putPrimary(track);
    await pipeline.saveLyrics(song, lyrics);
    return track;
  }
}
