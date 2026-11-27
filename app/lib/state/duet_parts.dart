// Duet parts: the lyrics split between two singers, A and B, and lines they
// sing together (C, [DuetPart.both]). Verses go back and forth A, B, A, B;
// a chorus starts with A, then B, then both together (A B C, or A B C C C
// for a longer one). Each singer picks A or B and sings their own lines and
// the C lines.
//
// How the lyrics are read:
// 1. Phrases. Subtitle lines are often half a sung phrase ("把沒說的話" /
//    "都寫成旋律"), so a short line (under [_shortLine]) is joined to the
//    neighbour it sits closer to, when that is near enough and the two stay
//    short; a line that comes back elsewhere joins only one that does too.
//    The parts are dealt out per phrase.
// 2. Repetition. A phrase is repeated when one more than [_apart] seconds
//    away reads alike (character bigrams, Dice >= [_alike]). Choruses come
//    back most often, so a phrase scores how often it comes back against the
//    most-repeated one in the song. A changed word in a repeat ("寫成" ->
//    "化作") is bridged by its neighbours: a phrase between two repeated ones
//    counts as nearly repeated.
// 3. Lift. Choruses are louder and sit higher: the music's level over the
//    phrase and the melody's mean pitch, each as a z-score across the song,
//    add to the score (this is what finds a last chorus with new words).
// 4. Sections. Each phrase is verse or chorus by a two-state Viterbi pass:
//    chorus earns score - [_chorusBar], every change costs [_switchCost], so
//    one odd phrase does not flip a section. A lone chorus phrase is verse.
// 5. Blocks. A chorus run splits where the singing pauses ([_blockGap]) or
//    comes back to its first phrase (a chorus sung twice), then into pieces
//    of at most five phrases, as even as can be (12 -> 4 4 4); each piece is
//    A, B, then C. A piece of one or two phrases is all C. Each verse run
//    goes back and forth starting with whoever has sung less so far, so the
//    two parts come out about even.
import 'dart:math' as math;

import '../services/song_library.dart';
import 'energy_curve.dart';
import 'lyrics.dart';
import 'song_data.dart';

enum DuetPart {
  a,
  b,
  both;

  /// The part shown to a singer who chose [mine]: their own or both.
  bool sungBy(DuetPart mine) => this == both || this == mine;
}

enum DuetSection { verse, chorus }

class DuetPlan {
  DuetPlan({required this.parts, required this.sections, required this.phrases, this.debug = const []});

  /// Per phrase: repetition, level and pitch z-scores and the chorus score
  /// (for tuning).
  final List<({double rep, double loud, double pitch, double score, int count})> debug;

  /// Per lyric line, in the order given.
  final List<DuetPart> parts;
  final List<DuetSection> sections;

  /// The phrase each line belongs to (lines of one phrase share a part).
  final List<int> phrases;

  int get length => parts.length;

  /// The lines [mine] sings (their own part and the together lines).
  List<int> linesOf(DuetPart mine) => [for (var i = 0; i < parts.length; i++) if (parts[i].sungBy(mine)) i];

  /// Seconds of singing each part gets (C counts for both).
  Map<DuetPart, double> secondsOf(List<LyricLine> lines) {
    final m = {for (final p in DuetPart.values) p: 0.0};
    for (var i = 0; i < parts.length; i++) {
      m[parts[i]] = m[parts[i]]! + (lines[i].end - lines[i].start);
    }
    return m;
  }

  static final empty = DuetPlan(parts: const [], sections: const [], phrases: const []);
}

// Phrases.
const _shortLine = 3.0; // seconds
const _joinGap = 0.6; // seconds between lines that may be joined
const _phraseMax = 7.5; // seconds a joined phrase may last
// Repetition.
const _alike = 0.6;
const _apart = 12.0; // seconds
// Sections.
const _chorusBar = 0.6;
const _switchCost = 0.5;
const _liftLoud = 0.35, _liftPitch = 0.25;
// Blocks.
const _blockGap = 3.0; // seconds
const _pieceMax = 5;

/// Splits [lines] into duet parts. [loudness] is the music's level over each
/// line (dB, null where unknown) and [notes] the song's melody; both are
/// optional, the repetition alone is used without them.
DuetPlan planDuet(List<LyricLine> lines, {List<double?>? loudness, NoteList? notes}) {
  if (lines.isEmpty) return DuetPlan.empty;
  // Lines that come back elsewhere (a repeated short line keeps to repeated
  // neighbours, so a chorus does not lose its first line to the verse).
  final lineKeys = [for (final l in lines) _bigrams(l.text)];
  final lineRep = [
    for (var i = 0; i < lines.length; i++)
      [for (var j = 0; j < lines.length; j++) j].any((j) => (lines[i].start - lines[j].start).abs() >= _apart && _dice(lineKeys[i], lineKeys[j]) >= _alike),
  ];
  final phrases = _phrases(lines, lineRep);
  final n = phrases.length;
  double start(int p) => lines[phrases[p].first].start;
  double end(int p) => lines[phrases[p].last].end;
  final keys = [for (final ph in phrases) _bigrams(ph.map((i) => lines[i].text).join())];

  // 2. Repetition: how many alike phrases come back elsewhere.
  final count = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i == j || (start(i) - start(j)).abs() < _apart) continue;
      if (_dice(keys[i], keys[j]) >= _alike) count[i]++;
    }
  }
  final most = count.fold(0, math.max);
  final rep = [for (final c in count) most == 0 ? 0.0 : math.min(1.0, c / most)];
  // A changed word: between two repeated phrases counts as nearly repeated.
  final bridged = [
    for (var i = 0; i < n; i++)
      i > 0 && i < n - 1 ? math.max(rep[i], 0.8 * math.min(rep[i - 1], rep[i + 1])) : rep[i],
  ];

  // 3. Lift: level and pitch as z-scores.
  List<double> z(List<double?> v) {
    final known = v.whereType<double>().where((x) => x.isFinite).toList();
    if (known.length < 3) return List.filled(v.length, 0);
    final mean = known.reduce((a, b) => a + b) / known.length;
    final sd = math.sqrt(known.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / known.length);
    if (sd < 1e-6) return List.filled(v.length, 0);
    return [for (final x in v) x == null || !x.isFinite ? 0.0 : ((x - mean) / sd).clamp(-2.0, 2.0)];
  }

  final loudZ = loudness == null || loudness.length != lines.length
      ? List<double>.filled(n, 0)
      : z([
          for (final ph in phrases)
            () {
              final v = ph.map((i) => loudness[i]).whereType<double>().toList();
              return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
            }(),
        ]);
  final pitchZ = notes == null || notes.isEmpty ? List<double>.filled(n, 0) : z([for (var p = 0; p < n; p++) _meanPitch(notes, start(p), end(p))]);
  final score = [for (var p = 0; p < n; p++) bridged[p] + _liftLoud * loudZ[p] + _liftPitch * pitchZ[p]];

  // 4. Sections: Viterbi over verse (0) / chorus (1).
  final chorus = _viterbi(score);
  // A lone chorus phrase is verse.
  for (var p = 0; p < n; p++) {
    if (chorus[p] && (p == 0 || !chorus[p - 1]) && (p == n - 1 || !chorus[p + 1])) chorus[p] = false;
  }

  // 5. Blocks and parts, per phrase.
  final part = List<DuetPart>.filled(n, DuetPart.a);
  var sungA = 0.0, sungB = 0.0;
  var p = 0;
  while (p < n) {
    var q = p + 1;
    while (q < n && chorus[q] == chorus[p]) {
      q++;
    }
    if (!chorus[p]) {
      // Back and forth, starting with whoever has sung less so far.
      final first = sungA <= sungB ? DuetPart.a : DuetPart.b;
      final second = first == DuetPart.a ? DuetPart.b : DuetPart.a;
      for (var k = p; k < q; k++) {
        part[k] = (k - p).isEven ? first : second;
      }
    } else {
      // Blocks: a pause, or back to the block's first phrase.
      var b0 = p;
      for (var k = p + 1; k <= q; k++) {
        final cut = k == q ||
            start(k) - end(k - 1) >= _blockGap ||
            (k - b0 >= 3 && _dice(keys[k], keys[b0]) >= _alike) ||
            // Into a more repeated stretch: the pre-chorus ends, the chorus starts.
            (k - b0 >= 2 && count[k] > count[k - 1] && count[k] == count.skip(k).take(3).reduce(math.min));
        if (!cut) continue;
        _dealChorus(part, b0, k);
        b0 = k;
      }
    }
    for (var k = p; k < q; k++) {
      if (part[k] == DuetPart.a) sungA += end(k) - start(k);
      if (part[k] == DuetPart.b) sungB += end(k) - start(k);
    }
    p = q;
  }

  final parts = List<DuetPart>.filled(lines.length, DuetPart.a);
  final sections = List<DuetSection>.filled(lines.length, DuetSection.verse);
  final phraseOf = List<int>.filled(lines.length, 0);
  for (var k = 0; k < n; k++) {
    for (final i in phrases[k]) {
      parts[i] = part[k];
      sections[i] = chorus[k] ? DuetSection.chorus : DuetSection.verse;
      phraseOf[i] = k;
    }
  }
  return DuetPlan(
    parts: parts,
    sections: sections,
    phrases: phraseOf,
    debug: [for (var k = 0; k < n; k++) (rep: bridged[k], loud: loudZ[k], pitch: pitchZ[k], score: score[k], count: count[k])],
  );
}

/// A chorus block from [from] to [to] (phrases): pieces of at most
/// [_pieceMax], as even as can be, each A, B, then C (all C when shorter
/// than three).
void _dealChorus(List<DuetPart> part, int from, int to) {
  final len = to - from;
  final pieces = (len / _pieceMax).ceil();
  var at = from;
  for (var k = 0; k < pieces; k++) {
    final size = len ~/ pieces + (k < len % pieces ? 1 : 0);
    for (var j = 0; j < size; j++) {
      part[at + j] = size < 3 ? DuetPart.both : (j == 0 ? DuetPart.a : (j == 1 ? DuetPart.b : DuetPart.both));
    }
    at += size;
  }
}

/// Lines joined into sung phrases (see the top of the file).
List<List<int>> _phrases(List<LyricLine> lines, List<bool> repeated) {
  final group = [for (var i = 0; i < lines.length; i++) <int>[i]];
  double dur(List<int> g) => lines[g.last].end - lines[g.first].start;
  var i = 0;
  while (i < group.length) {
    final g = group[i];
    if (g.length == 1 && dur(g) < _shortLine) {
      final prevGap = i > 0 ? lines[g.first].start - lines[group[i - 1].last].end : double.infinity;
      final nextGap = i < group.length - 1 ? lines[group[i + 1].first].start - lines[g.last].end : double.infinity;
      bool fits(int other) =>
          group[other].length == 1 &&
          dur([...group[math.min(i, other)], ...group[math.max(i, other)]]) <= _phraseMax &&
          (!repeated[g.first] || repeated[group[other].first]);
      // The closer neighbour first, else the other one.
      final order = nextGap <= prevGap ? [(i + 1, nextGap), (i - 1, prevGap)] : [(i - 1, prevGap), (i + 1, nextGap)];
      final pick = order.where((o) => o.$2 <= _joinGap && fits(o.$1)).firstOrNull;
      if (pick != null) {
        final lo = math.min(i, pick.$1);
        group[lo] = [...group[lo], ...group[lo + 1]];
        group.removeAt(lo + 1);
        i = lo + 1;
        continue;
      }
    }
    i++;
  }
  return group;
}

/// Character bigrams of [text] without spaces, punctuation and case.
Set<String> _bigrams(String text) {
  final s = text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  if (s.length < 2) return {s};
  return {for (var i = 0; i + 2 <= s.length; i++) s.substring(i, i + 2)};
}

double _dice(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final common = a.where(b.contains).length;
  return 2 * common / (a.length + b.length);
}

/// The melody's mean pitch from [a] to [b], weighted by how long each note
/// sounds there; null without notes.
double? _meanPitch(NoteList notes, double a, double b) {
  var sum = 0.0, w = 0.0;
  for (var i = 0; i < notes.length; i++) {
    if (notes.onset[i] >= b) break;
    final o = math.min(b, notes.offset[i]) - math.max(a, notes.onset[i]);
    if (o <= 0) continue;
    sum += notes.pitch[i] * o;
    w += o;
  }
  return w > 0 ? sum / w : null;
}

/// Verse (false) or chorus (true) per phrase: chorus earns score - bar,
/// verse nothing, each change of state costs [_switchCost].
List<bool> _viterbi(List<double> score) {
  final n = score.length;
  final from = List.generate(n, (_) => [0, 1]);
  var cur = [0.0, score[0] - _chorusBar - _switchCost];
  for (var i = 1; i < n; i++) {
    final gain = [0.0, score[i] - _chorusBar];
    final next = [0.0, 0.0];
    for (var s = 0; s < 2; s++) {
      final stay = cur[s], move = cur[1 - s] - _switchCost;
      from[i][s] = stay >= move ? s : 1 - s;
      next[s] = math.max(stay, move) + gain[s];
    }
    cur = next;
  }
  final out = List<bool>.filled(n, false);
  var s = cur[1] > cur[0] ? 1 : 0;
  for (var i = n - 1; i >= 0; i--) {
    out[i] = s == 1;
    if (i > 0) s = from[i][s];
  }
  return out;
}

/// The music's mean level (dB) over each line, from [energy]; null where
/// the curve has nothing.
List<double?> lineLoudness(EnergyData energy, List<LyricLine> lines) {
  final t = energy.times, v = energy.rmsDb;
  int lower(double x) {
    var lo = 0, hi = t.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (t[m] < x) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  return [
    for (final l in lines)
      () {
        var sum = 0.0, k = 0;
        for (var i = lower(l.start); i < t.length && t[i] < l.end; i++) {
          if (!v[i].isFinite) continue;
          sum += v[i];
          k++;
        }
        return k == 0 ? null : sum / k;
      }(),
  ];
}

/// The duet parts of a song's lyrics, with its mix's level and its notes.
Future<DuetPlan> loadDuetPlan(SongFiles files, List<LyricLine> lines) async {
  if (lines.isEmpty) return DuetPlan.empty;
  final energy = await wavEnergyCurve(files.mixWav, hop: 0.05);
  NoteList? notes;
  try {
    notes = await NoteList.load(files.notesJson);
  } catch (_) {}
  return planDuet(lines, loudness: energy == null ? null : lineLoudness(energy, lines), notes: notes);
}

/// A stretch of the song sung by one part (consecutive lines of the same
/// part joined).
class DuetSpan {
  const DuetSpan(this.start, this.end, this.part);
  final double start, end;
  final DuetPart part;
}

extension DuetPlanSpans on DuetPlan {
  /// The parts over time: consecutive lines of one part joined into a span
  /// (from the first line's start to the last one's end).
  List<DuetSpan> spans(List<LyricLine> lines) {
    final out = <DuetSpan>[];
    for (var i = 0; i < length && i < lines.length; i++) {
      final l = lines[i];
      if (out.isNotEmpty && out.last.part == parts[i] && l.start - out.last.end < _blockGap) {
        out[out.length - 1] = DuetSpan(out.last.start, l.end, parts[i]);
      } else {
        out.add(DuetSpan(l.start, l.end, parts[i]));
      }
    }
    return out;
  }
}

/// The note indices that belong to the other singer: notes lying mostly in a
/// line of the part that is not [mine] (and not both). Notes outside every
/// line are left to both.
Set<int> partnerNotes(NoteList notes, List<LyricLine> lines, DuetPlan plan, DuetPart mine) {
  final out = <int>{};
  if (mine == DuetPart.both || plan.length != lines.length) return out;
  for (var n = 0; n < notes.length; n++) {
    final on = notes.onset[n], off = notes.offset[n];
    var best = -1;
    var bestOverlap = 0.0;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.start >= off) break;
      final o = math.min(off, l.end) - math.max(on, l.start);
      if (o > bestOverlap) {
        bestOverlap = o;
        best = i;
      }
    }
    if (best >= 0 && bestOverlap >= 0.5 * (off - on) && !plan.parts[best].sungBy(mine)) out.add(n);
  }
  return out;
}

/// The song's notes.json without the other singer's notes (their spans
/// excluded, like notes deleted by hand), for a take sung as [mine]: the
/// take is judged on its own part and the lines sung together.
Map<String, dynamic> duetNotesJson(Map<String, dynamic> songNotes, List<LyricLine> lines, DuetPlan plan, DuetPart mine) {
  final notes = NoteList.fromJson(songNotes);
  final drop = partnerNotes(notes, lines, plan, mine);
  final raw = (songNotes['notes'] as List? ?? const []).cast<Map>();
  bool dropped(Map m) {
    final on = (m['onset'] as num).toDouble(), off = (m['offset'] as num).toDouble();
    return drop.any((n) => notes.onset[n] == on && notes.offset[n] == off);
  }

  return {
    ...songNotes,
    'notes': [for (final m in raw) if (!dropped(m)) m],
    'excluded_spans': [
      ...(songNotes['excluded_spans'] as List? ?? const []),
      for (final n in drop) [notes.onset[n], notes.offset[n]],
    ],
    'duet': mine.name,
    // The other part's lines, where neither the reference nor the take is
    // looked at (see scoring_bridge.dart): a voice there (a friend who sang
    // the whole song, humming along, the original leaking from speakers)
    // would otherwise pull the take's alignment onto the wrong lines.
    'duet_spans': [
      for (final s in plan.spans(lines))
        if (!s.part.sungBy(mine)) [s.start, s.end],
    ],
  };
}
