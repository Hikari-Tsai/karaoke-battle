// Lyrics: WebVTT parsing (manual and rolling auto-generated captions),
// imported subtitle files (SRT / LRC), track selection and lyrics.json.
// Pure Dart (no Flutter) so it can be unit tested.
import 'dart:convert';
import 'dart:math' as math;

class LyricLine {
  const LyricLine(this.start, this.end, this.text, {this.romaji});
  final double start;
  final double end;
  final String text;

  /// Romanised reading (Japanese tracks only).
  final String? romaji;

  LyricLine withRomaji(String? r) => LyricLine(start, end, text, romaji: r);
  LyricLine shifted(double by) => by == 0 ? this : LyricLine(start + by, end + by, text, romaji: romaji);

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text, 'romaji': ?romaji};
  static LyricLine fromJson(Map<String, dynamic> j) =>
      LyricLine((j['start'] as num).toDouble(), (j['end'] as num).toDouble(), j['text'] as String? ?? '', romaji: j['romaji'] as String?);
}

/// Where a lyrics track came from.
enum LyricSource {
  youtube, // the video's subtitles
  imported, // a subtitle file the user picked
  edited, // the user's edit of another track
  manual, // typed in from scratch in the editor
  whisper, // speech recognition
  aligned, // pasted by the user, timed by the app (notes or Whisper)
}

class LyricTrack {
  LyricTrack({required this.lang, required this.auto, required this.lines, this.romajiVersion = 0, this.source = LyricSource.youtube, this.label, this.offset = 0});

  /// Unique key of the track within a song. For YouTube tracks the subtitle
  /// key (ja, zh-TW, en-orig); the app's own tracks add a private-use tag to
  /// the song's language (ja-x-import, zh-TW-x-edit), so [langFamily] still
  /// tells the language.
  final String lang;
  final bool auto; // automatically generated captions
  List<LyricLine> lines;
  final LyricSource source;

  /// Shown in menus: the imported file's name, or the edited track's label.
  final String? label;

  /// Seconds added to every line when shown (positive: the lyrics come
  /// later), set from the sing screen to fix subtitles that are out of sync.
  double offset;

  /// [lines] moved by [offset].
  List<LyricLine> get shownLines => offset == 0 ? lines : [for (final l in lines) l.shifted(offset)];

  /// Version of the romaji rules the lines were romanised with (0 = none);
  /// bumping [kRomajiVersion] re-romanises existing songs.
  int romajiVersion;

  bool get isJapanese => langFamily(lang) == 'ja';
  bool get hasRomaji => romajiVersion > 0 && lines.any((l) => l.romaji != null && l.romaji!.isNotEmpty);

  /// Index of the line sounding at [t] (start <= t < end), or -1.
  int indexAt(double t) {
    var lo = 0, hi = lines.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].start <= t) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (found >= 0 && t < lines[found].end) return found;
    return -1;
  }

  /// Index of the first line starting after [t], or -1.
  int nextAfter(double t) {
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].start > t) return i;
    }
    return -1;
  }

  /// The line overlapping [t] most closely (used to pair a translation with
  /// the current primary line): a line containing [t], else null.
  LyricLine? lineAt(double t) {
    final i = indexAt(t);
    return i < 0 ? null : lines[i];
  }

  Map<String, dynamic> toJson() => {
        'lang': lang,
        'auto': auto,
        if (source != LyricSource.youtube) 'source': source.name,
        'label': ?label,
        if (offset != 0) 'offset': offset,
        if (romajiVersion > 0) 'romaji_version': romajiVersion,
        'lines': [for (final l in lines) l.toJson()],
      };
  static LyricTrack fromJson(Map<String, dynamic> j) => LyricTrack(
        lang: j['lang'] as String? ?? '',
        auto: j['auto'] == true,
        source: LyricSource.values.asNameMap()[j['source']] ?? LyricSource.youtube,
        label: j['label'] as String?,
        offset: (j['offset'] as num?)?.toDouble() ?? 0,
        romajiVersion: (j['romaji_version'] as num?)?.toInt() ?? 0,
        lines: [for (final e in (j['lines'] as List? ?? const [])) LyricLine.fromJson((e as Map).cast<String, dynamic>())],
      );
}

/// The language subtag of a track key without the app's private-use part
/// ('zh-TW-x-edit' -> 'zh-TW').
String baseLang(String key) {
  final i = key.indexOf('-x-');
  return i < 0 ? key : key.substring(0, i);
}

/// All subtitle tracks fetched for a song plus the user's choice of the main
/// lyrics and an optional translation shown under it.
/// Bump when the romaji rules change so existing songs are re-romanised.
const kRomajiVersion = 1;

class Lyrics {
  Lyrics({required this.tracks, this.primary, this.secondary});
  final List<LyricTrack> tracks;
  String? primary;
  String? secondary;

  static Lyrics empty() => Lyrics(tracks: []);
  bool get isEmpty => tracks.isEmpty;

  LyricTrack? track(String? lang) {
    if (lang == null) return null;
    for (final t in tracks) {
      if (t.lang == lang) return t;
    }
    return null;
  }

  /// [base] if no track uses it, else base2, base3, …
  String uniqueKey(String base) {
    if (track(base) == null) return base;
    for (var n = 2;; n++) {
      if (track('$base$n') == null) return '$base$n';
    }
  }

  /// Adds [t], or replaces the track with the same key, and makes it the
  /// main lyrics.
  void putPrimary(LyricTrack t) {
    final i = tracks.indexWhere((e) => e.lang == t.lang);
    if (i >= 0) {
      tracks[i] = t;
    } else {
      tracks.add(t);
    }
    primary = t.lang;
    if (secondary == primary) secondary = null;
  }

  /// Key an edit of [t] is saved under: the app's own tracks are edited in
  /// place; YouTube or recognised tracks keep the original and get an
  /// "-x-edit" sibling.
  static String editKeyFor(LyricTrack t) => switch (t.source) {
        LyricSource.youtube || LyricSource.whisper => '${baseLang(t.lang)}-x-edit',
        _ => t.lang,
      };

  /// The lyrics as shown: every track's [LyricTrack.offset] applied to its
  /// lines (this object itself when no track has one).
  Lyrics shifted() {
    if (tracks.every((t) => t.offset == 0)) return this;
    return Lyrics(
      tracks: [
        for (final t in tracks)
          LyricTrack(lang: t.lang, auto: t.auto, lines: t.shownLines, romajiVersion: t.romajiVersion, source: t.source, label: t.label),
      ],
      primary: primary,
      secondary: secondary,
    );
  }

  LyricTrack? get primaryTrack => track(primary) ?? (tracks.isEmpty ? null : tracks.first);
  LyricTrack? get secondaryTrack => secondary == primaryTrack?.lang ? null : track(secondary);

  Map<String, dynamic> toJson() => {
        'version': 1,
        'primary': primary,
        'secondary': secondary,
        'tracks': [for (final t in tracks) t.toJson()],
      };
  static Lyrics fromJson(Map<String, dynamic> j) => Lyrics(
        tracks: [for (final e in (j['tracks'] as List? ?? const [])) LyricTrack.fromJson((e as Map).cast<String, dynamic>())],
        primary: j['primary'] as String?,
        secondary: j['secondary'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Track selection
// ---------------------------------------------------------------------------

/// YouTube subtitle keys to try for a song / UI language, best first.
List<String> subtitlePrefs(String language) => switch (language) {
      'zh' => const ['zh-Hant', 'zh-TW', 'zh-HK', 'zh', 'zh-Hans', 'zh-CN'],
      'yue' => const ['yue', 'zh-HK', 'zh-Hant', 'zh-TW', 'zh'],
      'ja' => const ['ja'],
      'en' => const ['en', 'en-US', 'en-GB'],
      _ => [language],
    };

/// Language family of a subtitle key (zh-TW, zh-Hant, yue -> zh).
String langFamily(String key) {
  final base = key.split('-').first.toLowerCase();
  return base == 'yue' ? 'zh' : base;
}

String? matchSubtitle(List<String> keys, List<String> prefs) {
  for (final p in prefs) {
    if (keys.contains(p)) return p;
  }
  for (final p in prefs) {
    for (final k in keys) {
      if (k.toLowerCase().startsWith('${p.toLowerCase()}-')) return k;
    }
  }
  return null;
}

class SubtitlePlan {
  const SubtitlePlan({required this.manual, this.auto, this.primary, this.secondary});

  /// Uploader-provided tracks to download.
  final List<String> manual;

  /// Automatic caption to download when there is no usable manual track.
  final String? auto;
  final String? primary;
  final String? secondary;
  bool get isEmpty => manual.isEmpty && auto == null;
}

/// Decides which tracks to download and the default main / translation
/// tracks. Manual tracks are preferred (the uploader's lyrics); without them
/// the original-language automatic captions are used.
SubtitlePlan planSubtitles({
  required List<String> manual,
  required List<String> auto,
  required String songLanguage,
  required String uiLanguage,
  int maxManual = 6,
}) {
  final m = manual.where((k) => k != 'live_chat').toList();
  final songPrefs = subtitlePrefs(songLanguage);
  final uiPrefs = subtitlePrefs(uiLanguage);
  if (m.isNotEmpty) {
    final primary = matchSubtitle(m, songPrefs) ?? m.first;
    String? secondary = matchSubtitle(m, uiPrefs);
    if (secondary != null && langFamily(secondary) == langFamily(primary)) secondary = null;
    final picked = <String>[primary, ?secondary];
    for (final k in m) {
      if (picked.length >= maxManual) break;
      if (!picked.contains(k)) picked.add(k);
    }
    return SubtitlePlan(manual: picked, primary: primary, secondary: secondary);
  }
  // Automatic captions: the speech-recognised original is marked "-orig" by
  // yt-dlp; the others are machine translations of it.
  final orig = auto.where((k) => k.endsWith('-orig')).toList();
  final a = orig.isNotEmpty ? orig.first : matchSubtitle(auto, songPrefs);
  if (a == null) return const SubtitlePlan(manual: []);
  return SubtitlePlan(manual: const [], auto: a, primary: a);
}

// ---------------------------------------------------------------------------
// WebVTT
// ---------------------------------------------------------------------------

final _cueTime = RegExp(r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})');
final _tag = RegExp(r'<[^>]*>');
final _assTag = RegExp(r'\{\\[^}]*\}'); // {\an8} etc. in some SRT files
final _inlineTime = RegExp(r'<\d{1,2}:\d{2}[:.]\d{2}');
final _noise = RegExp(r'^[\[\(（【♪♫\s]*(music|音楽|音樂|音乐|拍手|applause|笑)?[\]\)）】♪♫\s]*$', caseSensitive: false);

double _parseTime(String s) {
  final parts = s.replaceAll(',', '.').split(':');
  var t = 0.0;
  for (final p in parts) {
    t = t * 60 + double.parse(p);
  }
  return t;
}

String _decode(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ');

/// Parses WebVTT into lyric lines. Handles manual captions (multi-line cues
/// are joined) and YouTube's rolling automatic captions, where each cue
/// repeats the previous line and the new line carries inline timestamps:
/// only the timestamped line is kept, ~10 ms transition cues are dropped and
/// consecutive duplicates are merged.
List<LyricLine> parseVtt(String vtt) {
  final rows = vtt.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <LyricLine>[];
  var i = 0;
  while (i < rows.length) {
    final m = _cueTime.firstMatch(rows[i]);
    if (m == null) {
      i++;
      continue;
    }
    final start = _parseTime(m.group(1)!);
    final end = _parseTime(m.group(2)!);
    i++;
    final raw = <String>[];
    // A cue ends at an empty row once it has some text, or at the next
    // timing row. YouTube's rolling captions put blank (space-only) rows
    // inside a cue, which some tools strip to empty rows.
    while (i < rows.length && !_cueTime.hasMatch(rows[i])) {
      final hasText = raw.any((l) => l.trim().isNotEmpty);
      if (rows[i].trim().isEmpty && hasText) break;
      raw.add(rows[i]);
      i++;
    }
    if (end - start < 0.05) continue; // rolling-caption transition cue
    final timed = raw.where((l) => _inlineTime.hasMatch(l)).toList();
    final source = timed.isNotEmpty ? timed : raw;
    final text = source
        .map((l) => _decode(l.replaceAll(_tag, '').replaceAll(_assTag, '')).trim())
        .where((l) => l.isNotEmpty && !_noise.hasMatch(l))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) continue;
    if (out.isNotEmpty && out.last.text == text && start - out.last.end < 0.5) {
      final prev = out.removeLast();
      out.add(LyricLine(prev.start, math.max(prev.end, end), text));
      continue;
    }
    out.add(LyricLine(start, end, text));
  }
  // Rolling captions overlap the next cue; clip so lines never overlap.
  for (var k = 0; k + 1 < out.length; k++) {
    if (out[k].end > out[k + 1].start && out[k + 1].start > out[k].start) {
      out[k] = LyricLine(out[k].start, out[k + 1].start, out[k].text);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Subtitle files the user imports (SRT / WebVTT / LRC) and exports
// ---------------------------------------------------------------------------

/// Extensions offered when importing.
const kSubtitleExtensions = ['srt', 'vtt', 'lrc'];

/// Thrown for a file that cannot be read as subtitles.
class SubtitleFormatException implements Exception {
  const SubtitleFormatException(this.reason);

  /// 'encoding' (not UTF-8 / UTF-16) or 'format' (no timed lines found).
  final String reason;
  @override
  String toString() => 'SubtitleFormatException($reason)';
}

/// Text of a subtitle file: UTF-8 (with or without BOM) or UTF-16 with a BOM.
/// Legacy encodings (Big5, GBK, Shift_JIS) are rejected rather than garbled.
String decodeSubtitleBytes(List<int> b) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
    final le = b[0] == 0xFF;
    final units = <int>[for (var i = 2; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]];
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(b);
  } on FormatException {
    throw const SubtitleFormatException('encoding');
  }
}

/// Lines of a subtitle file, chosen by extension (sniffed when unknown).
List<LyricLine> parseSubtitleFile(String fileName, List<int> bytes) {
  final text = decodeSubtitleBytes(bytes);
  final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
  final lines = switch (ext) {
    'lrc' => parseLrc(text),
    'srt' || 'vtt' => parseVtt(text),
    _ => text.contains('-->') ? parseVtt(text) : parseLrc(text),
  };
  if (lines.isEmpty) throw const SubtitleFormatException('format');
  return lines;
}

final _lrcStamp = RegExp(r'\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]');
final _lrcWordStamp = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
final _lrcOffset = RegExp(r'^\s*\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);

/// Parses LRC: `[mm:ss.xx]text`, several stamps per row for repeated lines,
/// `[offset:±ms]`, word stamps `<mm:ss.xx>` (dropped). LRC has no end
/// times: a line lasts until the next stamp (an empty one marks a break),
/// at most [maxLine] seconds.
List<LyricLine> parseLrc(String lrc, {double maxLine = 10, double lastLine = 6}) {
  var offset = 0.0;
  final stamps = <(double, String)>[];
  for (final row in lrc.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final o = _lrcOffset.firstMatch(row);
    if (o != null) {
      offset = int.parse(o.group(1)!) / 1000; // positive: lyrics come sooner
      continue;
    }
    var rest = row.trimLeft();
    final times = <double>[];
    while (true) {
      final m = _lrcStamp.matchAsPrefix(rest);
      if (m == null) break;
      times.add(int.parse(m.group(1)!) * 60 + double.parse(m.group(2)!.replaceAll(':', '.')));
      rest = rest.substring(m.end).trimLeft();
    }
    if (times.isEmpty) continue; // metadata ([ar:], [ti:]) or plain text
    final text = _decode(rest.replaceAll(_lrcWordStamp, '').replaceAll(_tag, '')).replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final t in times) {
      stamps.add((t, text));
    }
  }
  stamps.sort((a, b) => a.$1.compareTo(b.$1));
  final out = <LyricLine>[];
  for (var i = 0; i < stamps.length; i++) {
    final (t, text) = stamps[i];
    if (text.isEmpty || _noise.hasMatch(text)) continue;
    final start = math.max(0.0, t - offset);
    final next = i + 1 < stamps.length ? math.max(0.0, stamps[i + 1].$1 - offset) : start + lastLine;
    out.add(LyricLine(start, math.min(next, start + maxLine), text));
  }
  return out;
}

String _srtTime(double t) {
  final ms = (t * 1000).round();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
}

String toSrt(List<LyricLine> lines) {
  final b = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    b
      ..writeln(i + 1)
      ..writeln('${_srtTime(lines[i].start)} --> ${_srtTime(lines[i].end)}')
      ..writeln(lines[i].text)
      ..writeln();
  }
  return b.toString();
}

String _lrcTime(double t) {
  final cs = (t * 100).round();
  return '[${(cs ~/ 6000).toString().padLeft(2, '0')}:${(cs ~/ 100 % 60).toString().padLeft(2, '0')}.${(cs % 100).toString().padLeft(2, '0')}]';
}

/// LRC with an empty stamp where a line ends before the next one starts.
String toLrc(List<LyricLine> lines) {
  final b = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    b.writeln('${_lrcTime(l.start)}${l.text}');
    final next = i + 1 < lines.length ? lines[i + 1].start : null;
    if (next == null || next - l.end > 0.3) b.writeln(_lrcTime(l.end));
  }
  return b.toString();
}

/// `m:ss.cc` (or `h:mm:ss.cc`) for the editor.
String formatLyricTime(double t) {
  final cs = (t * 100).round();
  final h = cs ~/ 360000, m = cs ~/ 6000 % 60, s = cs ~/ 100 % 60, c = cs % 100;
  final tail = '${s.toString().padLeft(2, '0')}.${c.toString().padLeft(2, '0')}';
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$tail' : '$m:$tail';
}

/// Inverse of [formatLyricTime]; also takes plain seconds and a comma. Null
/// when [s] is not a time.
double? parseLyricTime(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (!RegExp(r'^(\d+:){0,2}\d+(\.\d+)?$').hasMatch(t)) return null;
  var v = 0.0;
  for (final part in t.split(':')) {
    v = v * 60 + double.parse(part);
  }
  return v;
}

// ---------------------------------------------------------------------------
// Note-driven karaoke wipe
// ---------------------------------------------------------------------------

/// How far (0..1) the sung highlight should have moved across [line] at time
/// [t], driven by the transcribed notes: the notes whose midpoint falls in
/// the line each get an equal share of the text, the share fills over that
/// note's duration and holds during the gaps between notes (so long notes
/// keep the wipe on one syllable and a pause stops it). Without any note in
/// the line it falls back to a linear wipe over the line's span.
/// [onsets] and [offsets] are sorted by onset and of equal length.
double noteWipeFraction(LyricLine line, List<double> onsets, List<double> offsets, double t, {double tolerance = 0.15}) {
  final n = onsets.length;
  // First note that could belong to the line (binary search on onset).
  var lo = 0, hi = n;
  final from = line.start - 2.0;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (onsets[mid] < from) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final idx = <int>[];
  for (var i = lo; i < n && onsets[i] <= line.end + tolerance; i++) {
    final m = (onsets[i] + offsets[i]) / 2;
    if (m >= line.start - tolerance && m <= line.end + tolerance) idx.add(i);
  }
  if (idx.isEmpty) {
    final span = line.end - line.start;
    return span <= 0 ? 1.0 : ((t - line.start) / span).clamp(0.0, 1.0);
  }
  final k = idx.length;
  for (var j = 0; j < k; j++) {
    final on = onsets[idx[j]];
    final off = offsets[idx[j]];
    if (t < on) return j / k;
    if (t < off) return (j + (off > on ? (t - on) / (off - on) : 1.0)) / k;
  }
  return 1.0;
}
