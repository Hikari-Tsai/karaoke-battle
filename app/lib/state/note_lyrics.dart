// The lyric under each note, for the results' note table. Lyrics are timed
// by line only, so each line's text is spread over the notes that start in
// it: a character per note in Chinese / Japanese / Korean, a word per note
// otherwise; a note holding the previous syllable shows "～", and when there
// are fewer notes than syllables a note gets several. Rough by nature: the
// table says so.
import 'lyrics.dart';

/// Shown on a note that holds the previous note's syllable.
const lyricHold = '～';

/// One entry per onset (in the same order): its syllable(s), [lyricHold],
/// or null when no lyric line covers it.
List<String?> lyricsForNotes(List<double> onsets, List<LyricLine> lines) {
  final out = List<String?>.filled(onsets.length, null);
  if (lines.isEmpty || onsets.isEmpty) return out;
  final order = [for (var i = 0; i < onsets.length; i++) i]..sort((a, b) => onsets[a].compareTo(onsets[b]));
  final sortedLines = [...lines]..sort((a, b) => a.start.compareTo(b.start));
  final taken = <int>{};
  for (final line in sortedLines) {
    final units = lyricUnits(line.text);
    if (units.isEmpty) continue;
    // Notes starting in the line (a little early still counts).
    final inLine = [
      for (final i in order)
        if (!taken.contains(i) && onsets[i] >= line.start - 0.15 && onsets[i] < line.end) i,
    ];
    if (inLine.isEmpty) continue;
    taken.addAll(inLine);
    final k = inLine.length, m = units.length;
    final latin = units.any((u) => !_isCjkRune(u.runes.first));
    for (var j = 0; j < k; j++) {
      final a = (j * m / k).ceil(), b = ((j + 1) * m / k).ceil();
      out[inLine[j]] = b > a ? units.sublist(a, b).join(latin ? ' ' : '') : lyricHold;
    }
  }
  return out;
}

/// The sung units of a lyric line: CJK characters one by one (small kana and
/// the long vowel mark stay with the one before), other words whole;
/// punctuation and spaces dropped.
List<String> lyricUnits(String text) {
  final out = <String>[];
  final word = StringBuffer();
  void flush() {
    if (word.isNotEmpty) {
      out.add(word.toString());
      word.clear();
    }
  }

  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (_attaches(rune)) {
      flush();
      if (out.isNotEmpty) {
        out[out.length - 1] += ch;
      } else {
        out.add(ch);
      }
    } else if (_isCjkRune(rune)) {
      flush();
      out.add(ch);
    } else if (_wordChar.hasMatch(ch)) {
      word.write(ch);
    } else {
      flush();
    }
  }
  flush();
  return out;
}

final _wordChar = RegExp(r"[\p{L}\p{N}']", unicode: true);

bool _isCjkRune(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) || // CJK unified ideographs
    (r >= 0x3400 && r <= 0x4DBF) || // extension A
    (r >= 0xF900 && r <= 0xFAFF) || // compatibility ideographs
    (r >= 0x3040 && r <= 0x30FF) || // hiragana, katakana
    (r >= 0xAC00 && r <= 0xD7AF); // hangul syllables

/// Small kana and the long vowel mark: part of the syllable before.
bool _attaches(int r) => 'ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮー'.runes.contains(r);
