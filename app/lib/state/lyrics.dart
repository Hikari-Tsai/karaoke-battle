// Lyrics from YouTube subtitles: WebVTT parsing (manual and rolling
// auto-generated captions), track selection and the per-song lyrics.json.
// Pure Dart (no Flutter) so it can be unit tested.
import 'dart:math' as math;

class LyricLine {
  const LyricLine(this.start, this.end, this.text, {this.romaji});
  final double start;
  final double end;
  final String text;

  /// Romanised reading (Japanese tracks only).
  final String? romaji;

  LyricLine withRomaji(String? r) => LyricLine(start, end, text, romaji: r);

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text, 'romaji': ?romaji};
  static LyricLine fromJson(Map<String, dynamic> j) =>
      LyricLine((j['start'] as num).toDouble(), (j['end'] as num).toDouble(), j['text'] as String? ?? '', romaji: j['romaji'] as String?);
}

class LyricTrack {
  LyricTrack({required this.lang, required this.auto, required this.lines, this.romajiVersion = 0});
  final String lang; // YouTube subtitle key, e.g. ja, zh-TW, en-orig
  final bool auto; // automatically generated captions
  List<LyricLine> lines;

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
        if (romajiVersion > 0) 'romaji_version': romajiVersion,
        'lines': [for (final l in lines) l.toJson()],
      };
  static LyricTrack fromJson(Map<String, dynamic> j) => LyricTrack(
        lang: j['lang'] as String? ?? '',
        auto: j['auto'] == true,
        romajiVersion: (j['romaji_version'] as num?)?.toInt() ?? 0,
        lines: [for (final e in (j['lines'] as List? ?? const [])) LyricLine.fromJson((e as Map).cast<String, dynamic>())],
      );
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
        .map((l) => _decode(l.replaceAll(_tag, '')).trim())
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
