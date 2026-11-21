// What yt-dlp's metadata (`yt-dlp -J`) tells about a song: its singer, the
// year it came out and its language, for the achievements (the hot songs
// charts are asked first; this is for songs not on them).

/// The singer: the music metadata YouTube keeps for official tracks first
/// (artist, creator), else the channel, without the " - Topic" of auto-made
/// artist channels or a trailing "VEVO". For a cover, the channel is the one
/// singing it.
String? youtubeArtist(Map<String, dynamic> info) {
  String? clean(Object? v) {
    if (v is! String) return null;
    var s = v.trim();
    if (s.endsWith(' - Topic')) s = s.substring(0, s.length - 8).trim();
    if (s.length > 4 && s.endsWith('VEVO')) s = s.substring(0, s.length - 4).trim();
    return s.isEmpty ? null : s;
  }

  final artists = info['artists'];
  if (artists is List && artists.isNotEmpty) {
    final first = clean(artists.first);
    if (first != null) return first;
  }
  // "A, B" credits the first.
  final artist = clean(info['artist']) ?? clean(info['creator']);
  if (artist != null) return artist.split(',').first.trim();
  return clean(info['channel']) ?? clean(info['uploader']);
}

/// The year the song came out, from YouTube's music metadata (release year
/// or date), only for videos YouTube knows as a music track (with a track
/// name): an ordinary video's "release" is its premiere, as late as an
/// upload. The upload date is never used: a 1990s song uploaded in 2020 is
/// not a 2020s song.
int? youtubeYear(Map<String, dynamic> info) {
  final track = info['track'];
  if (track is! String || track.trim().isEmpty) return null;
  int? valid(int? y) => y != null && y > 1900 && y <= DateTime.now().year + 1 ? y : null;
  final year = info['release_year'];
  if (year is num) return valid(year.toInt());
  final date = info['release_date'];
  if (date is String && date.length >= 4) return valid(int.tryParse(date.substring(0, 4)));
  return null;
}

/// The song's language as the app names them (zh, yue, ja, en, ko), from
/// the video's language; null when YouTube does not say or it is another one.
String? youtubeLanguage(Map<String, dynamic> info) {
  final l = info['language'];
  if (l is! String || l.trim().isEmpty) return null;
  final s = l.trim().toLowerCase();
  if (s.startsWith('yue') || s == 'zh-hk') return 'yue';
  if (s.startsWith('zh') || s.startsWith('cmn')) return 'zh';
  if (s.startsWith('nan')) return 'nan';
  for (final code in const ['ja', 'en', 'ko']) {
    if (s == code || s.startsWith('$code-')) return code;
  }
  return null;
}
