// Timing lyrics the user pasted (plain lines, no times):
//  * alignToNotes: from the transcribed notes (GAME). Notes know when
//    something is sung, not what, so lines are matched to runs of notes by
//    syllable count, preferring breaks at rests. Instant, no download.
//  * alignToSegments: from Whisper's recognised text. Lines are matched to
//    the recognised characters (longest common subsequence), so they land
//    on the right phrase; line starts are then snapped to note onsets.
// Pure Dart (no Flutter) so it can be unit tested.
import 'dart:math' as math;
import 'dart:typed_data';

import 'lyrics.dart';

/// A recognised piece of text with its time span (a Whisper segment).
class TimedText {
  const TimedText(this.start, this.end, this.text);
  final double start;
  final double end;
  final String text;
}

/// Text Whisper is known to invent over music (credits, video outros).
final _hallucination = RegExp(
  r'^(作词|作詞|作曲|词曲|詞曲|编曲|編曲|演唱|原唱|混音|母带|母帶|监制|監製|制作人|製作人|和声|和聲|词|詞|曲)\s*[:：]'
  r'|^(作词|作詞|作曲|词曲|詞曲|编曲|編曲|演唱|原唱|混音|和声|和聲)\s'
  r'|字幕|订阅|訂閱|点赞|點贊|打赏|打賞|感谢观看|感謝觀看|谢谢观看|謝謝觀看|ご視聴|チャンネル登録|amara\.org|thanks? for watching|subtitles? by|please subscribe',
  caseSensitive: false,
);

bool isLikelyHallucination(String text) => _hallucination.hasMatch(text.trim());

/// Recognised text cut into phrases (Whisper often returns a whole verse as
/// one segment): at punctuation and at spaces between CJK characters, then
/// short neighbours joined again up to [maxSyllables].
List<String> splitPhrases(String text, {int maxSyllables = 12}) {
  final parts = text
      .split(RegExp(r'[，。、！？；,.!?;]+|\s{2,}|　|(?<=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー])\s+(?=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])', unicode: true))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final out = <String>[];
  for (final p in parts) {
    if (out.isNotEmpty && syllableCount(out.last) + syllableCount(p) <= maxSyllables) {
      out[out.length - 1] = '${out.last} $p';
    } else {
      out.add(p);
    }
  }
  return out;
}

/// Splits pasted text into lyric lines (trimmed, empty rows dropped).
List<String> splitLyricLines(String text) =>
    text.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

// ---------------------------------------------------------------------------
// Units: what is compared and counted
// ---------------------------------------------------------------------------

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _cjkOrKana = RegExp(r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]', unicode: true);
final _smallKana = RegExp('[ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ]');

/// Comparable characters of [s]: letters and digits only, lower case,
/// full-width ASCII folded, katakana folded to hiragana.
List<int> comparableUnits(String s) {
  final out = <int>[];
  for (final r in s.toLowerCase().runes) {
    var c = r;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0; // full width -> ASCII
    if (c >= 0x30A1 && c <= 0x30F6) c -= 0x60; // katakana -> hiragana
    final ch = String.fromCharCode(c);
    if (_letterOrDigit.hasMatch(ch)) out.add(c);
  }
  return out;
}

/// Roughly how many sung syllables (≈ notes) a line has: one per CJK
/// character or kana (small kana join the one before), one per vowel group
/// of a Latin word.
int syllableCount(String line) {
  var n = 0;
  for (final r in line.runes) {
    final ch = String.fromCharCode(r);
    if (_cjkOrKana.hasMatch(ch) && !_smallKana.hasMatch(ch) && ch != 'ー') n++;
  }
  for (final w in RegExp(r'[A-Za-zÀ-ÿ]+').allMatches(line)) {
    final groups = RegExp(r'[aeiouyàâäéèêëïîôöùûü]+', caseSensitive: false).allMatches(w.group(0)!).length;
    var s = math.max(1, groups);
    if (s > 1 && w.group(0)!.toLowerCase().endsWith('e') && !w.group(0)!.toLowerCase().endsWith('le')) s--; // silent e
    n += s;
  }
  return math.max(1, n);
}

// ---------------------------------------------------------------------------
// GAME notes
// ---------------------------------------------------------------------------

/// Times [lines] from notes ([onsets] / [offsets], sorted). Each line gets a
/// contiguous run of notes; notes between lines may be left over (ad-libs,
/// backing vocals). Returns one LyricLine per input line.
List<LyricLine> alignToNotes(
  List<String> lines,
  List<double> onsets,
  List<double> offsets, {
  // Tuned on a Chinese and a Japanese song against their YouTube subtitles.
  double skipCost = 0.2, // per note left out
  double mismatchCost = 2.0, // per relative syllable difference
  double restReward = 0.5, // for a line boundary on a rest (per second, capped at 1 s)
  List<double?>? startHints, // where each line probably starts (from Whisper), or null
  double hintWeight = 0.1, // per second away from the hint, up to [hintCap]
  double hintCap = 2.0,
}) {
  final n = onsets.length, l = lines.length;
  if (l == 0) return const [];
  if (n == 0) return _spread(lines, 0, lines.length * 3.0);
  final syl = [for (final s in lines) syllableCount(s)];
  // Rest before note k (0 for the first note) and after note k.
  double restBefore(int k) => k <= 0 ? 1.0 : math.max(0.0, onsets[k] - offsets[k - 1]);
  double restAfter(int k) => k >= n - 1 ? 1.0 : math.max(0.0, onsets[k + 1] - offsets[k]);

  double lineCost(int i, int from, int to) {
    final count = to - from;
    final s = syl[i];
    var c = mismatchCost * (count - s).abs() / s;
    final hint = startHints != null && i < startHints.length ? startHints[i] : null;
    if (hint != null) c += hintWeight * math.min((onsets[from] - hint).abs(), hintCap);
    c -= restReward * math.min(restBefore(from), 1.0);
    c -= restReward * math.min(restAfter(to - 1), 1.0);
    return c;
  }

  const inf = 1e18;
  // best[i][j]: cost of placing lines < i using notes < j (line i-1 ends at j).
  final best = List.generate(l + 1, (_) => Float64List(n + 1)..fillRange(0, n + 1, inf));
  final lineStart = List.generate(l + 1, (_) => Int32List(n + 1));
  final prevEnd = List.generate(l + 1, (_) => Int32List(n + 1));
  best[0][0] = 0;
  for (var i = 0; i < l; i++) {
    // Leaving notes out before line i: running minimum with a per-note cost.
    final start = Float64List(n + 1);
    final startAt = Int32List(n + 1);
    for (var k = 0; k <= n; k++) {
      final skipped = k == 0 ? inf : start[k - 1] + skipCost;
      if (best[i][k] <= skipped) {
        start[k] = best[i][k];
        startAt[k] = k;
      } else {
        start[k] = skipped;
        startAt[k] = startAt[k - 1];
      }
    }
    final maxLen = syl[i] * 3 + 6;
    for (var k = 0; k < n; k++) {
      if (start[k] >= inf) continue;
      for (var j = k + 1; j <= math.min(n, k + maxLen); j++) {
        final c = start[k] + lineCost(i, k, j);
        if (c < best[i + 1][j]) {
          best[i + 1][j] = c;
          lineStart[i + 1][j] = k;
          prevEnd[i + 1][j] = startAt[k];
        }
      }
    }
  }
  // Notes after the last line are left out too.
  var end = 0;
  var endCost = inf;
  for (var j = 0; j <= n; j++) {
    final c = best[l][j] + skipCost * (n - j);
    if (c < endCost) {
      endCost = c;
      end = j;
    }
  }
  if (endCost >= inf) return _spread(lines, onsets.first, offsets.last);
  final spans = List<(int, int)>.filled(l, (0, 0));
  for (var i = l; i > 0; i--) {
    spans[i - 1] = (lineStart[i][end], end);
    end = prevEnd[i][end];
  }
  return [
    for (var i = 0; i < l; i++) LyricLine(onsets[spans[i].$1], offsets[spans[i].$2 - 1], lines[i]),
  ];
}

/// Evenly spread lines over [start, end] (nothing to align to).
List<LyricLine> _spread(List<String> lines, double start, double end) {
  final step = (end - start) / lines.length;
  return [for (var i = 0; i < lines.length; i++) LyricLine(start + i * step, start + (i + 0.9) * step, lines[i])];
}

// ---------------------------------------------------------------------------
// Whisper segments
// ---------------------------------------------------------------------------

/// Times [lines] with both: the notes give the exact times, Whisper's
/// recognised text where each line roughly is (a light pull, so it only
/// matters where counting notes alone would drift onto the wrong phrase).
/// On a Mandarin and a Japanese test song the notes alone were already the
/// most accurate; this weight keeps that while bounding large drifts.
List<LyricLine> alignWithWhisper(List<String> lines, List<TimedText> segments, List<double> onsets, List<double> offsets) {
  if (onsets.isEmpty) return alignToSegments(lines, segments);
  final m = _segmentMatch(lines, segments);
  // Whisper's line starts came out ~0.3 s early against subtitle timings.
  return alignToNotes(lines, onsets, offsets, startHints: [for (final h in m.matched) h == null ? null : h + 0.3]);
}

/// Lyric lines from recognised [segments]: a segment may hold a whole
/// verse, so it is cut into phrases at punctuation, which are timed on the
/// notes sung within it.
List<LyricLine> linesFromSegments(List<TimedText> segments, List<double> onsets, List<double> offsets) {
  final lines = <LyricLine>[];
  for (final s in segments) {
    final phrases = splitPhrases(s.text);
    if (phrases.isEmpty) continue;
    final on = <double>[], off = <double>[];
    for (var i = 0; i < onsets.length; i++) {
      if (onsets[i] >= s.start - 0.4 && onsets[i] < s.end) {
        on.add(onsets[i]);
        off.add(offsets[i]);
      }
    }
    final timed = phrases.length > 1 && on.length >= phrases.length
        ? alignToNotes(phrases, on, off)
        : [LyricLine(snapToOnset(onsets, s.start), s.end, phrases.join(' '))];
    for (final l in timed) {
      final start = lines.isNotEmpty && l.start < lines.last.end ? lines.last.end : l.start;
      if (l.end > start) lines.add(LyricLine(start, l.end, l.text));
    }
  }
  return lines;
}

/// True when [text] only repeats the style prompt (Whisper sometimes
/// continues the prompt instead of listening).
bool echoesPrompt(String text, String prompt) {
  final t = String.fromCharCodes(comparableUnits(text));
  return t.isNotEmpty && String.fromCharCodes(comparableUnits(prompt)).contains(t);
}

/// Times [lines] from recognised [segments] only. Lines without enough
/// matched characters are placed between their neighbours by length. With
/// note [onsets], line starts snap to the nearest onset within 0.4 s.
List<LyricLine> alignToSegments(List<String> lines, List<TimedText> segments, {List<double>? onsets}) {
  final l = lines.length;
  if (l == 0) return const [];
  final m = _segmentMatch(lines, segments);
  final start = [...m.matched], end = [...m.matchedEnd];
  final lineUnits = m.units;
  // Unmatched lines: between their neighbours, by length.
  for (var i = 0; i < l;) {
    if (start[i] != null) {
      i++;
      continue;
    }
    var j = i;
    while (j < l && start[j] == null) {
      j++;
    }
    final from = i > 0 ? end[i - 1]! : (j < l ? math.max(0.0, start[j]! - 3.0 * (j - i)) : 0.0);
    final to = j < l ? start[j]! : from + 3.0 * (j - i);
    final total = [for (var k = i; k < j; k++) math.max(1, lineUnits[k])].fold(0, (a, b) => a + b);
    var t = from;
    for (var k = i; k < j; k++) {
      final d = (to - from) * math.max(1, lineUnits[k]) / total;
      start[k] = t;
      end[k] = t + d * 0.9;
      t += d;
    }
    i = j;
  }
  // Snap starts to note onsets, keep order and positive lengths.
  final out = <LyricLine>[];
  for (var i = 0; i < l; i++) {
    var s = start[i]!;
    if (onsets != null) s = snapToOnset(onsets, s);
    if (out.isNotEmpty && s < out.last.start + 0.05) s = out.last.start + 0.05;
    var e = math.max(end[i]!, s + 0.3);
    out.add(LyricLine(s, e, lines[i]));
  }
  for (var i = 0; i + 1 < out.length; i++) {
    if (out[i].end > out[i + 1].start) out[i] = LyricLine(out[i].start, math.max(out[i].start + 0.05, out[i + 1].start), out[i].text);
  }
  return out;
}

/// Start / end of each line from the recognised characters it matched
/// (null when too few matched), and each line's character count.
({List<double?> matched, List<double?> matchedEnd, List<int> units}) _segmentMatch(List<String> lines, List<TimedText> segments) {
  final l = lines.length;
  // Recognised units with their times.
  final rec = <int>[];
  final recTime = <double>[];
  final recSegStart = <double?>[];
  final recSegEnd = <double?>[];
  for (final s in segments) {
    final u = comparableUnits(s.text);
    for (var k = 0; k < u.length; k++) {
      rec.add(u[k]);
      recTime.add(s.start + (k + 0.5) / u.length * (s.end - s.start));
      recSegStart.add(k == 0 ? s.start : null);
      recSegEnd.add(k == u.length - 1 ? s.end : null);
    }
  }
  // Lyric units with their line and position in it.
  final lyr = <int>[];
  final lineUnits = <int>[];
  for (var i = 0; i < l; i++) {
    final u = comparableUnits(lines[i]);
    lineUnits.add(u.length);
    lyr.addAll(u);
  }
  final match = _lcs(lyr, rec); // lyric unit -> recognised unit or -1

  final start = List<double?>.filled(l, null), end = List<double?>.filled(l, null);
  var u0 = 0;
  for (var i = 0; i < l; i++) {
    final len = lineUnits[i];
    final hits = <(int, int)>[]; // (position in line, recognised index)
    for (var k = 0; k < len; k++) {
      final r = match[u0 + k];
      if (r >= 0) hits.add((k, r));
    }
    u0 += len;
    if (hits.isEmpty || hits.length < math.max(1, (len * 0.25).ceil())) continue;
    final first = hits.first, last = hits.last;
    final rate = hits.length >= 2 && last.$1 > first.$1
        ? ((recTime[last.$2] - recTime[first.$2]) / (last.$1 - first.$1)).clamp(0.08, 0.8)
        : 0.3;
    start[i] = first.$1 == 0 && recSegStart[first.$2] != null ? recSegStart[first.$2]! : recTime[first.$2] - (first.$1 + 0.5) * rate;
    end[i] = last.$1 == len - 1 && recSegEnd[last.$2] != null ? recSegEnd[last.$2]! : recTime[last.$2] + (len - last.$1 - 0.5) * rate;
  }
  return (matched: start, matchedEnd: end, units: lineUnits);
}

/// [t] moved to the nearest of the [sorted] note onsets when one is within
/// [within] seconds.
double snapToOnset(List<double> sorted, double t, {double within = 0.4}) {
  if (sorted.isEmpty) return t;
  final o = _nearest(sorted, t);
  return (o - t).abs() <= within ? o : t;
}

double _nearest(List<double> sorted, double t) {
  var lo = 0, hi = sorted.length - 1;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] < t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final a = sorted[lo];
  final b = lo > 0 ? sorted[lo - 1] : a;
  return (a - t).abs() < (b - t).abs() ? a : b;
}

/// Longest common subsequence of [a] and [b]: for each index of [a] the
/// matched index of [b], or -1.
List<int> _lcs(List<int> a, List<int> b) {
  final n = a.length, m = b.length;
  final out = List<int>.filled(n, -1);
  if (n == 0 || m == 0) return out;
  // Direction table (2 bits would do; a byte keeps it simple): 0 diag, 1 up, 2 left.
  final dir = Uint8List(n * m);
  var prev = Int32List(m + 1), cur = Int32List(m + 1);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (a[i - 1] == b[j - 1]) {
        cur[j] = prev[j - 1] + 1;
        dir[(i - 1) * m + (j - 1)] = 0;
      } else if (prev[j] >= cur[j - 1]) {
        cur[j] = prev[j];
        dir[(i - 1) * m + (j - 1)] = 1;
      } else {
        cur[j] = cur[j - 1];
        dir[(i - 1) * m + (j - 1)] = 2;
      }
    }
    final t = prev;
    prev = cur;
    cur = t..fillRange(0, m + 1, 0);
  }
  var i = n, j = m;
  while (i > 0 && j > 0) {
    switch (dir[(i - 1) * m + (j - 1)]) {
      case 0:
        if (a[i - 1] == b[j - 1]) out[i - 1] = j - 1;
        i--;
        j--;
      case 1:
        i--;
      default:
        j--;
    }
  }
  return out;
}
