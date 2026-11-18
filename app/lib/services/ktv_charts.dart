// KTV song request charts (Holiday, Cashbox, JOYSOUND, DAM) and the KKBOX
// streaming charts, read from the KTV Charts site
// (https://hikari-tsai.github.io/ktv-charts): a daily ETL that scrapes the
// operators once and publishes one JSON file per source, enriched with genre,
// mood and instrument tags, BPM, the chorus range and links to Apple Music,
// Spotify and KKBOX. The app reads those files instead of scraping the
// operators from every computer.
//
// A source's file is cached in memory and on disk. It is fetched again when it
// is older than [KtvChartService.ttl]; when that fails, the last copy on disk
// is shown (marked offline) rather than an error.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// The chart sources. KKBOX is a streaming service rather than a KTV
/// operator, but its charts sit beside theirs.
enum KtvVendor { holiday, cashbox, joysound, dam, kkbox }

class KtvCharts {
  KtvCharts._();

  /// The KTV Charts site; `data/<source>.json` holds a source's charts.
  static const base = 'https://hikari-tsai.github.io/ktv-charts';

  static Uri dataUrl(KtvVendor v) => Uri.parse('$base/data/${v.name}.json');

  /// `tw` or `jp`.
  static String region(KtvVendor v) => v == KtvVendor.joysound || v == KtvVendor.dam ? 'jp' : 'tw';
}

/// One chart a source publishes, as listed in its file.
class ChartBoard {
  const ChartBoard(this.vendor, this.id, this.title, {this.sourceUrl});
  final KtvVendor vendor;

  /// The site's chart id (`tc`, `hot-01`, `all-weekly`, `song-weekly-297`…).
  final String id;

  /// Localised names by language (`zh`, `en`, `ja`).
  final Map<String, String> title;

  /// The chart on the operator's own website.
  final String? sourceUrl;

  String get key => '${vendor.name}-$id';

  String label(String lang) => title[lang] ?? title['zh'] ?? title['en'] ?? id;

  @override
  bool operator ==(Object other) => other is ChartBoard && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// The singer's chorus range from the site (MIDI notes) and how it suits male
/// and female voices: `v` is a verdict (`ok`, `high`, `vhigh`, `low`, `vlow`)
/// and `key` the suggested key change in semitones.
class ChartRange {
  const ChartRange({required this.low, required this.high, this.male, this.female, this.fit});
  final int low;
  final int high;
  final ({String verdict, int key})? male;
  final ({String verdict, int key})? female;

  /// `m` or `f`: whose range the song sits in.
  final String? fit;

  static ChartRange? fromJson(Object? j) {
    if (j is! Map) return null;
    final lo = (j['low'] as num?)?.toInt(), hi = (j['high'] as num?)?.toInt();
    if (lo == null || hi == null) return null;
    ({String verdict, int key})? voice(Object? v) =>
        v is Map && v['v'] is String ? (verdict: v['v'] as String, key: (v['key'] as num?)?.toInt() ?? 0) : null;
    return ChartRange(low: lo, high: hi, male: voice(j['m']), female: voice(j['f']), fit: j['fit'] as String?);
  }
}

/// A place to hear a song: a service's own page.
enum ListenService { apple, spotify, kkbox }

class ChartEntry {
  const ChartEntry({
    required this.rank,
    required this.title,
    required this.artist,
    this.songNo = '',
    this.lastRank,
    this.isNew = false,
    this.songUrl,
    this.genre,
    this.tags = const {},
    this.bpm,
    this.range,
    this.apple,
    this.spotify,
    this.kkbox,
  });

  final int rank;
  final String title;
  final String artist;

  /// The number entered on the operator's machines (JOYSOUND: its song id);
  /// empty when there is none (KKBOX).
  final String songNo;

  /// Last week's rank, when known and the song was on the chart.
  final int? lastRank;
  final bool isNew;

  /// The song's page on the operator's site, when given.
  final String? songUrl;

  /// From the iTunes Search API.
  final String? genre;

  /// Model tags by group (`genre`, `mood`, `instrument`, `vocal`).
  final Map<String, List<String>> tags;

  /// Estimated tempo (Beat This! on a 30 s preview); may be half or double.
  final int? bpm;
  final ChartRange? range;

  /// Apple Music `<country>/<track id>`, Spotify track id, KKBOX song id.
  final String? apple;
  final String? spotify;
  final String? kkbox;

  /// Places moved up (negative: down), or null when unknown or new.
  int? get movement => isNew || lastRank == null ? null : lastRank! - rank;

  String get _query => '$title $artist'.trim();

  /// A YouTube search for this song: a plain results page, no API key.
  Uri get youtubeSearchUrl => Uri.https('www.youtube.com', '/results', {'search_query': _query});

  /// The song's page on [s] (where it can be played), or a search there
  /// when the site has no match for it. Opened in the browser: the service
  /// plays it under its own terms; the app never handles the audio.
  Uri listenUrl(ListenService s, {String region = 'tw'}) {
    switch (s) {
      case ListenService.apple:
        final parts = apple?.split('/');
        if (parts != null && parts.length == 2 && parts[1].isNotEmpty) return Uri.https('music.apple.com', '/${parts[0]}/song/${parts[1]}');
        return Uri.https('music.apple.com', '/$region/search', {'term': _query});
      case ListenService.spotify:
        if (spotify != null && spotify!.isNotEmpty) return Uri.https('open.spotify.com', '/track/$spotify');
        return Uri.https('open.spotify.com', '/search/${Uri.encodeComponent(_query)}');
      case ListenService.kkbox:
        if (kkbox != null && kkbox!.isNotEmpty) return Uri.https('www.kkbox.com', '/tw/tc/song/$kkbox');
        return Uri.https('www.kkbox.com', '/tw/tc/search', {'q': _query});
    }
  }

  /// Whether [s] has this exact song (not just a search).
  bool hasListen(ListenService s) => switch (s) {
    ListenService.apple => (apple ?? '').contains('/'),
    ListenService.spotify => (spotify ?? '').isNotEmpty,
    ListenService.kkbox => (kkbox ?? '').isNotEmpty,
  };

  factory ChartEntry.fromJson(Map<String, dynamic> j) {
    final songUrl = j['song_url'] as String?;
    var songNo = (j['song_no'] ?? '').toString();
    // JOYSOUND gives its song page; its id is what the machines take.
    if (songNo.isEmpty && songUrl != null && songUrl.contains('joysound.com')) {
      songNo = RegExp(r'/song/(\d+)').firstMatch(songUrl)?.group(1) ?? '';
    }
    final tags = <String, List<String>>{};
    final t = j['tags'];
    if (t is Map) {
      for (final e in t.entries) {
        if (e.value is List) tags['${e.key}'] = [for (final v in e.value as List) '$v'];
      }
    }
    String? str(String k) {
      final v = j[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    return ChartEntry(
      rank: (j['rank'] as num).toInt(),
      title: j['title'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      songNo: songNo,
      lastRank: (j['last_rank'] as num?)?.toInt(),
      isNew: j['is_new'] == true,
      songUrl: songUrl,
      genre: str('genre'),
      tags: tags,
      bpm: (j['bpm'] as num?)?.toInt(),
      range: ChartRange.fromJson(j['range']),
      apple: str('apple'),
      spotify: str('spotify'),
      kkbox: str('kkbox'),
    );
  }
}

class KtvChart {
  const KtvChart({required this.board, required this.entries, this.period, this.fetchedAt, this.stale = false});

  final ChartBoard board;
  final List<ChartEntry> entries;

  /// Counting period, as the site gives it (`2026/11/10 ~ 2026/11/16`).
  final String? period;

  /// When the site last fetched this chart from the operator.
  final DateTime? fetchedAt;

  /// The site could not refresh it and kept an older copy.
  final bool stale;

  bool get hasMovement => entries.any((e) => e.lastRank != null || e.isNew);
  bool get hasSongNo => entries.any((e) => e.songNo.isNotEmpty);
}

/// Every chart of one source, as one file of the site.
class VendorCharts {
  const VendorCharts({required this.vendor, required this.charts, required this.downloadedAt, this.checkedAt, this.offline = false});
  final KtvVendor vendor;
  final List<KtvChart> charts;

  /// When the app downloaded this copy.
  final DateTime downloadedAt;

  /// When the site last checked the operator.
  final DateTime? checkedAt;

  /// The site could not be reached: this is the last copy on disk.
  final bool offline;

  List<ChartBoard> get boards => [for (final c in charts) c.board];

  KtvChart? chart(String id) {
    for (final c in charts) {
      if (c.board.id == id) return c;
    }
    return null;
  }

  VendorCharts asOffline() => VendorCharts(vendor: vendor, charts: charts, downloadedAt: downloadedAt, checkedAt: checkedAt, offline: true);
}

enum ChartErrorKind { timeout, network, http, format }

class ChartException implements Exception {
  const ChartException(this.kind, [this.detail = '']);
  final ChartErrorKind kind;
  final String detail;
  @override
  String toString() => 'ChartException(${kind.name}${detail.isEmpty ? '' : ': $detail'})';
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

/// One source's file from the site.
VendorCharts parseVendorCharts(KtvVendor vendor, String body, {required DateTime downloadedAt}) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException catch (e) {
    throw ChartException(ChartErrorKind.format, e.message);
  }
  if (root is! Map || root['charts'] is! List) throw const ChartException(ChartErrorKind.format, 'no charts');
  final charts = <KtvChart>[];
  for (final c in root['charts'] as List) {
    if (c is! Map || c['id'] is! String) continue;
    final title = <String, String>{};
    final t = c['title'];
    if (t is Map) {
      for (final e in t.entries) {
        if (e.value is String) title['${e.key}'] = e.value as String;
      }
    }
    final board = ChartBoard(vendor, c['id'] as String, title, sourceUrl: c['source_url'] as String?);
    final entries = <ChartEntry>[];
    for (final r in (c['rows'] as List? ?? const [])) {
      if (r is! Map || r['rank'] is! num) continue;
      try {
        entries.add(ChartEntry.fromJson(r.cast<String, dynamic>()));
      } catch (_) {
        // One odd row does not lose the chart.
      }
    }
    entries.sort((a, b) => a.rank.compareTo(b.rank));
    charts.add(KtvChart(board: board, entries: entries, period: c['period'] as String?, fetchedAt: _date(c['fetched_at']), stale: c['stale'] == true));
  }
  if (charts.isEmpty) throw const ChartException(ChartErrorKind.format, 'no charts');
  return VendorCharts(vendor: vendor, charts: charts, downloadedAt: downloadedAt, checkedAt: _date(root['checked_at']));
}

// --- service ---------------------------------------------------------------

class KtvChartService {
  KtvChartService({http.Client? client, this.cacheDir, this.ttl = const Duration(hours: 3), this.timeout = const Duration(seconds: 20), DateTime Function()? now})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _now = now ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  /// Where the files are kept between launches; memory only when null.
  final String? cacheDir;

  /// The site updates once a day; a copy younger than this is used as is.
  final Duration ttl;
  final Duration timeout;

  final _memory = <KtvVendor, VendorCharts>{};
  final _pending = <KtvVendor, Future<VendorCharts>>{};

  /// The charts of [vendor]: the cached copy while it is younger than [ttl],
  /// else downloaded; when the download fails, the last copy on disk (marked
  /// [VendorCharts.offline]). [force] skips the fresh-copy check. Throws
  /// [ChartException] only when there is no copy at all.
  Future<VendorCharts> load(KtvVendor vendor, {bool force = false}) {
    final pending = _pending[vendor];
    if (pending != null) return pending;
    // A block body: returning the removed future would make it wait on itself.
    final f = _load(vendor, force).whenComplete(() {
      _pending.remove(vendor);
    });
    _pending[vendor] = f;
    return f;
  }

  Future<VendorCharts> _load(KtvVendor vendor, bool force) async {
    final cached = _memory[vendor] ?? await _readDisk(vendor);
    if (!force && cached != null && _now().difference(cached.downloadedAt) < ttl) {
      return _memory[vendor] = cached;
    }
    try {
      final now = _now();
      final body = await _get(KtvCharts.dataUrl(vendor));
      final charts = parseVendorCharts(vendor, body, downloadedAt: now);
      _memory[vendor] = charts;
      await _writeDisk(vendor, body, now);
      return charts;
    } on ChartException {
      if (cached != null) return _memory[vendor] = cached.asOffline();
      rethrow;
    }
  }

  /// The UTF-8 body of a 200 response.
  Future<String> _get(Uri url) async {
    try {
      final resp = await _client.get(url, headers: {'User-Agent': 'KaraokeBattle'}).timeout(timeout);
      if (resp.statusCode != 200) throw ChartException(ChartErrorKind.http, '${resp.statusCode}');
      return utf8.decode(resp.bodyBytes, allowMalformed: true);
    } on TimeoutException {
      throw const ChartException(ChartErrorKind.timeout);
    } on ChartException {
      rethrow;
    } catch (e) {
      throw ChartException(ChartErrorKind.network, '$e');
    }
  }

  // The site's file as downloaded, plus a sidecar with the download time.
  File? _cacheFile(KtvVendor v) => cacheDir == null ? null : File(p.join(cacheDir!, 'ktv_charts', 'site-${v.name}.json'));
  File? _stampFile(KtvVendor v) => cacheDir == null ? null : File(p.join(cacheDir!, 'ktv_charts', 'site-${v.name}.time'));

  Future<VendorCharts?> _readDisk(KtvVendor vendor) async {
    final f = _cacheFile(vendor), s = _stampFile(vendor);
    if (f == null || s == null) return null;
    try {
      if (!await f.exists()) return null;
      final at = await s.exists() ? DateTime.tryParse((await s.readAsString()).trim())?.toLocal() : null;
      return parseVendorCharts(vendor, await f.readAsString(), downloadedAt: at ?? await f.lastModified());
    } catch (_) {
      return null;
    }
  }

  bool _cleaned = false;

  Future<void> _writeDisk(KtvVendor vendor, String body, DateTime at) async {
    final f = _cacheFile(vendor), s = _stampFile(vendor);
    if (f == null || s == null) return;
    try {
      await f.parent.create(recursive: true);
      if (!_cleaned) {
        _cleaned = true;
        // Per-board files from the versions that scraped the operators.
        await for (final e in f.parent.list()) {
          if (e is File && !p.basename(e.path).startsWith('site-')) await e.delete();
        }
      }
      await f.writeAsString(body);
      await s.writeAsString(at.toUtc().toIso8601String());
    } catch (_) {
      // The memory cache still works.
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
