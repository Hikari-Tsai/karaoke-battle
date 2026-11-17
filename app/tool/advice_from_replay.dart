// Developer tool: build the "AI analysis" Markdown from an exported replay
// (.zip or its .json), to tune the analysis and the prompt on real takes.
//
//   dart run tool/advice_from_replay.dart <replay.zip|replay.json> [lang] [lyrics.json]
//
// lang is zh (default), en or ja. Replays carry no lyrics; pass the song's
// lyrics.json to get lyric lines. Prints the Markdown to stdout.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:karaoke_battle/advice/advice_prompt.dart';
import 'package:karaoke_battle/advice/take_analysis.dart';
import 'package:karaoke_battle/scoring/models.dart';
import 'package:karaoke_battle/state/lyrics.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/advice_from_replay.dart <replay.zip|replay.json> [lang] [lyrics.json]');
    exit(2);
  }
  final path = args[0];
  String text;
  if (path.toLowerCase().endsWith('.zip')) {
    final zip = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    final json = zip.files.firstWhere((f) => f.isFile && f.name.toLowerCase().endsWith('.json'));
    text = utf8.decode(json.content);
  } else {
    text = File(path).readAsStringSync();
  }
  final j = jsonDecode(text) as Map<String, dynamic>;
  final song = (j['song'] as Map).cast<String, dynamic>();
  final take = (j['take'] as Map).cast<String, dynamic>();
  var lyrics = const <LyricLine>[];
  if (args.length > 2) {
    final l = Lyrics.fromJson(jsonDecode(File(args[2]).readAsStringSync()) as Map<String, dynamic>).shifted();
    lyrics = l.primaryTrack?.lines ?? const [];
  }
  final analysis = analyzeTake(TakeAnalysisInput(
    notes: ReferenceNotes.fromJson((j['notes'] as Map).cast<String, dynamic>()).notes,
    score: (j['score'] as Map).cast<String, dynamic>(),
    takeCreatedAt: DateTime.tryParse(take['created_at'] as String? ?? '') ?? DateTime.now(),
    songTitle: song['title'] as String? ?? '',
    artist: song['artist'] as String? ?? '',
    lyrics: lyrics,
    pitchShift: (take['pitch_shift'] as num?)?.toDouble() ?? 0,
  ));
  stdout.write(buildAdvicePrompt(analysis, lang: args.length > 1 ? args[1] : 'zh', appVersion: j['app_version'] as String? ?? ''));
}
