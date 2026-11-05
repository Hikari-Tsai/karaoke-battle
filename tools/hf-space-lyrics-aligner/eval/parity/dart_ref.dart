// Runs app/lib/state/lyric_align.dart (the source of truth) on cases.json
// and prints the results as JSON; check_parity.mjs compares lib/lyric_align.js.
import 'dart:convert';
import 'dart:io';

import '../../../../app/lib/state/lyric_align.dart';

void main(List<String> args) {
  final input = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final out = <String, dynamic>{};
  List f(List ls) => [for (final l in ls) [l.start, l.end, l.text]];
  for (final c in (input['cases'] as List)) {
    final lines = (c['lines'] as List).cast<String>();
    final on = [for (final x in c['onsets'] as List) (x as num).toDouble()];
    final off = [for (final x in c['offsets'] as List) (x as num).toDouble()];
    final segs = [for (final s in (c['segments'] as List)) TimedText((s[0] as num).toDouble(), (s[1] as num).toDouble(), s[2] as String)];
    out[c['name']] = {
      'notes': f(alignToNotes(lines, on, off)),
      'whisper': f(alignWithWhisper(lines, segs, on, off)),
      'segments': f(alignToSegments(lines, segs)),
      'segments_snap': f(alignToSegments(lines, segs, onsets: on)),
      'from_segments': f(linesFromSegments(segs, on, off)),
      'syl': [for (final l in lines) syllableCount(l)],
      'units': [for (final l in lines) comparableUnits(l)],
      'phrases': [for (final s in segs) splitPhrases(s.text)],
      'halluc': [for (final s in segs) isLikelyHallucination(s.text)],
      'echo': [for (final s in segs) echoesPrompt(s.text, '以下是繁體中文的歌詞。')],
    };
  }
  print(jsonEncode(out));
}
