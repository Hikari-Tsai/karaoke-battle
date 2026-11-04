// KTV song request charts from the operators' own websites: Holiday and
// Cashbox (Taiwan, internal AJAX endpoints), JOYSOUND (JSON-LD in the ranking
// page) and DAM (static ranking HTML). None of these are public APIs, so the
// parsers are kept pure and tested against saved responses.
//
// Charts change once a week (DAM daily/weekly), so results are cached in
// memory and on disk for [KtvChartService.ttl]; a refresh bypasses the cache.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

enum KtvVendor { holiday, cashbox, joysound, dam }

/// One chart a vendor publishes. [id] is the vendor's own code: the Holiday
/// `ltype`, `t<type>-<lang>` for Cashbox, the JOYSOUND genre, or the DAM
/// genre (`all` for the overall chart).
class ChartBoard {
  const ChartBoard(this.vendor, this.id, this.labelKey);
  final KtvVendor vendor;
  final String id;

  /// i18n key of the tab label.
  final String labelKey;

  String get key => '${vendor.name}-$id';

  /// The chart on the vendor's website.
  String get officialUrl => switch (vendor) {
    KtvVendor.holiday => 'https://www.holiday.com.tw/SongInfo/SongList.aspx?st=top&lt=$id',
    KtvVendor.cashbox => 'https://www.cashboxparty.com/Music/KTVMusic.aspx',
    KtvVendor.joysound => 'https://www.joysound.com/web/karaoke/ranking/$id/weekly',
    KtvVendor.dam => 'https://www.clubdam.com${_damPath(id)}#ranking-weekly',
  };

  @override
  bool operator ==(Object other) => other is ChartBoard && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

String _damPath(String genre) => genre == 'all' ? '/ranking/' : '/genre/$genre/';

class KtvCharts {
  KtvCharts._();

  /// Every board, grouped by vendor in display order; the first is the default.
  static const boards = <KtvVendor, List<ChartBoard>>{
    KtvVendor.holiday: [
      ChartBoard(KtvVendor.holiday, 'tc', 'charts.lang.mandarin'),
      ChartBoard(KtvVendor.holiday, 'tt', 'charts.lang.taiwanese'),
      ChartBoard(KtvVendor.holiday, 'ct', 'charts.lang.cantonese'),
      ChartBoard(KtvVendor.holiday, 'et', 'charts.lang.english'),
      ChartBoard(KtvVendor.holiday, 'jt', 'charts.lang.japanese'),
      ChartBoard(KtvVendor.holiday, 'kt', 'charts.lang.korean'),
      ChartBoard(KtvVendor.holiday, 'vt', 'charts.lang.vietnamese'),
      ChartBoard(KtvVendor.holiday, 'nc', 'charts.new.mandarin'),
      ChartBoard(KtvVendor.holiday, 'nt', 'charts.new.taiwanese'),
    ],
    KtvVendor.cashbox: [
      ChartBoard(KtvVendor.cashbox, 't2-01', 'charts.lang.mandarin'),
      ChartBoard(KtvVendor.cashbox, 't2-02', 'charts.lang.taiwanese'),
      ChartBoard(KtvVendor.cashbox, 't2-03', 'charts.lang.cantonese'),
      ChartBoard(KtvVendor.cashbox, 't2-04', 'charts.lang.japanese'),
      ChartBoard(KtvVendor.cashbox, 't2-05', 'charts.lang.english'),
      ChartBoard(KtvVendor.cashbox, 't1-01', 'charts.new.mandarin'),
      ChartBoard(KtvVendor.cashbox, 't1-02', 'charts.new.taiwanese'),
    ],
    KtvVendor.joysound: [
      ChartBoard(KtvVendor.joysound, 'all', 'charts.genre.overall'),
      ChartBoard(KtvVendor.joysound, 'anime', 'charts.genre.anime'),
      ChartBoard(KtvVendor.joysound, 'vocaloid', 'charts.genre.vocaloid'),
      ChartBoard(KtvVendor.joysound, 'enka', 'charts.genre.enka'),
      ChartBoard(KtvVendor.joysound, 'foreign', 'charts.genre.foreign'),
    ],
    KtvVendor.dam: [
      ChartBoard(KtvVendor.dam, 'all', 'charts.genre.overall'),
      ChartBoard(KtvVendor.dam, 'anison', 'charts.genre.anime'),
      ChartBoard(KtvVendor.dam, 'vocaloid', 'charts.genre.vocaloid'),
      ChartBoard(KtvVendor.dam, 'vtuber', 'charts.genre.vtuber'),
      ChartBoard(KtvVendor.dam, 'enka', 'charts.genre.enka'),
      ChartBoard(KtvVendor.dam, 'foreign', 'charts.genre.foreign'),
    ],
  };

  /// Whether the vendor publishes last week's rank.
  static bool hasMovement(KtvVendor v) => v == KtvVendor.holiday || v == KtvVendor.cashbox;
}

class ChartEntry {
  const ChartEntry({required this.rank, required this.title, required this.artist, required this.songNo, this.lastRank, this.isNew = false});

  final int rank;
  final String title;
  final String artist;

  /// The number entered on the vendor's machines (JOYSOUND: its song id).
  final String songNo;

  /// Last week's rank, when known and the song was on the chart.
  final int? lastRank;
  final bool isNew;

  /// Places moved up (negative: down), or null when unknown or new.
  int? get movement => isNew || lastRank == null ? null : lastRank! - rank;

  /// A YouTube search for this song: a plain results page, no API key.
  Uri get youtubeSearchUrl => Uri.https('www.youtube.com', '/results', {'search_query': '$title $artist'.trim()});

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'title': title,
    'artist': artist,
    'songNo': songNo,
    if (lastRank != null) 'lastRank': lastRank,
    if (isNew) 'isNew': true,
  };

  factory ChartEntry.fromJson(Map<String, dynamic> j) => ChartEntry(
    rank: j['rank'] as int,
    title: j['title'] as String,
    artist: j['artist'] as String,
    songNo: j['songNo'] as String,
    lastRank: j['lastRank'] as int?,
    isNew: j['isNew'] as bool? ?? false,
  );
}

class KtvChart {
  const KtvChart({required this.board, required this.entries, required this.fetchedAt, this.period, this.updated});

  final ChartBoard board;
  final List<ChartEntry> entries;
  final DateTime fetchedAt;

  /// Counting period as `yyyy/MM/dd – yyyy/MM/dd`, when known.
  final String? period;

  /// The vendor's own "updated" date, when it gives one.
  final String? updated;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'board': board.key,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
    'period': period,
    'updated': updated,
    'entries': [for (final e in entries) e.toJson()],
  };

  factory KtvChart.fromJson(ChartBoard board, Map<String, dynamic> j) {
    if (j['version'] != 1 || j['board'] != board.key) throw const FormatException('cache mismatch');
    return KtvChart(
      board: board,
      fetchedAt: DateTime.parse(j['fetchedAt'] as String).toLocal(),
      period: j['period'] as String?,
      updated: j['updated'] as String?,
      entries: [for (final e in j['entries'] as List) ChartEntry.fromJson(e as Map<String, dynamic>)],
    );
  }
}

enum ChartErrorKind { timeout, network, http, format, rejected }

class ChartException implements Exception {
  const ChartException(this.kind, [this.detail = '']);
  final ChartErrorKind kind;
  final String detail;
  @override
  String toString() => 'ChartException(${kind.name}${detail.isEmpty ? '' : ': $detail'})';
}

String _period(String? start, String? end) {
  final s = start?.trim() ?? '';
  final e = end?.trim() ?? '';
  if (s.isEmpty && e.isEmpty) return '';
  if (s.isEmpty || e.isEmpty || s == e) return s.isEmpty ? e : s;
  return '$s – $e';
}

// --- parsers ---------------------------------------------------------------

/// Decodes a Holiday value (`encodeURIComponent` on the server side).
String _holidayDecode(Object? v) {
  final s = v?.toString() ?? '';
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

/// One page of `SongInfo.ashx` `m=top`.
({List<ChartEntry> entries, int maxPage, String period}) parseHolidayPage(String body) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException catch (e) {
    throw ChartException(ChartErrorKind.format, e.message);
  }
  if (root is! List || root.isEmpty || root.first is! Map) throw const ChartException(ChartErrorKind.format, 'not a JSON array');
  final d = root.first as Map<String, dynamic>;
  if (d['Ok'] != '1') {
    final msg = _holidayDecode(d['Msg']);
    throw ChartException(ChartErrorKind.rejected, 'Ok=${d['Ok']}${msg.isEmpty ? '' : ' $msg'}');
  }
  final page = d['Page'];
  final maxPage = page is List && page.isNotEmpty && page.first is Map ? ((page.first as Map)['MaxPage'] as num?)?.toInt() ?? 1 : 1;
  final entries = <ChartEntry>[];
  for (final r in (d['DataList'] as List? ?? const [])) {
    if (r is! Map) continue;
    final rank = int.tryParse(_holidayDecode(r['thisweek']));
    if (rank == null) continue;
    final weeks = _holidayDecode(r['weeks']);
    final last = int.tryParse(_holidayDecode(r['lastweek']));
    entries.add(ChartEntry(
      rank: rank,
      title: _holidayDecode(r['songname']),
      artist: _holidayDecode(r['singer']),
      songNo: _holidayDecode(r['id']),
      lastRank: last,
      isNew: weeks.contains('新') || (last == null && weeks.isNotEmpty && !'↑↓→'.contains(weeks)),
    ));
  }
  return (entries: entries, maxPage: maxPage, period: _period(_holidayDecode(d['sdate']), _holidayDecode(d['edate'])));
}

/// `ah_Song.ashx` `m=bl`: one row per song, all languages in the request.
/// Only rows of [lang] are kept when it is given.
({List<ChartEntry> entries, String period}) parseCashboxChart(String body, {String? lang}) {
  final Object? root;
  try {
    root = jsonDecode(body.trim().isEmpty ? 'null' : body);
  } on FormatException catch (e) {
    throw ChartException(ChartErrorKind.format, e.message);
  }
  if (root is! List || root.isEmpty) throw const ChartException(ChartErrorKind.format, 'empty response');
  final first = root.first;
  if (first is! Map || first['Result'] != '0') {
    final r = first is Map ? first : const {};
    throw ChartException(ChartErrorKind.rejected, 'Result=${r['Result']} ${r['Msg'] ?? ''}'.trim());
  }
  final entries = <ChartEntry>[];
  String period = '';
  for (final r in root) {
    if (r is! Map) continue;
    final no = (r['SongNo'] as String? ?? '').trim();
    if (no.isEmpty) continue;
    if (lang != null && r['LangCode'] != lang) continue;
    final rank = int.tryParse('${r['ThisWeekend']}');
    if (rank == null) continue;
    final last = int.tryParse('${r['LastWeekend']}');
    if (period.isEmpty) period = _period(r['StartDate'] as String?, r['EndDate'] as String?);
    entries.add(ChartEntry(
      rank: rank,
      title: (r['SongName'] as String? ?? '').trim(),
      artist: (r['Singer'] as String? ?? '').trim(),
      songNo: no,
      lastRank: last == null || last == 0 ? null : last,
      isNew: last == 0,
    ));
  }
  entries.sort((a, b) => a.rank.compareTo(b.rank));
  return (entries: entries, period: period);
}

final _ldJson = RegExp(r'<script type="application/ld\+json"[^>]*>(.*?)</script>', dotAll: true);
final _joyPeriod = RegExp(r'集計期間[:：]\s*(?:<[^>]+>\s*)*([0-9/]+(?:\s*-\s*[0-9/]+)?)');

/// A JOYSOUND ranking page: the schema.org `ItemList` in its JSON-LD.
({List<ChartEntry> entries, String period}) parseJoysoundPage(String html) {
  final entries = <ChartEntry>[];
  for (final m in _ldJson.allMatches(html)) {
    Object? data;
    try {
      data = jsonDecode(m.group(1)!);
    } on FormatException {
      continue;
    }
    final graph = data is Map ? (data['@graph'] is List ? data['@graph'] as List : [data]) : const [];
    for (final g in graph) {
      final list = g is Map ? g['mainEntity'] : null;
      if (list is! Map || list['@type'] != 'ItemList') continue;
      for (final it in (list['itemListElement'] as List? ?? const [])) {
        if (it is! Map || it['item'] is! Map) continue;
        final song = it['item'] as Map;
        final rank = (it['position'] as num?)?.toInt();
        if (rank == null) continue;
        final artist = song['byArtist'];
        entries.add(ChartEntry(
          rank: rank,
          title: '${song['name'] ?? ''}'.trim(),
          artist: artist is Map ? '${artist['name'] ?? ''}'.trim() : '',
          songNo: '${song['url'] ?? ''}'.split('/').last,
        ));
      }
    }
  }
  if (entries.isEmpty) throw const ChartException(ChartErrorKind.format, 'no ItemList in JSON-LD');
  final period = _joyPeriod.firstMatch(html)?.group(1)?.trim() ?? '';
  return (entries: entries, period: period.replaceAll(RegExp(r'\s*-\s*'), ' – '));
}

final _damSection = RegExp(r'<div class="c-section" id="([^"]*)">');
final _damRow = RegExp(
  r'requestNo=([\d-]+)"[^>]*>\s*<div class="p-ranking__num[^"]*">(\d+)</div>'
  r'.*?p-song__title">(.*?)</h4>\s*<div class="p-song__artist">(.*?)</div>',
  dotAll: true,
);
final _damDate = RegExp(r'p-section-header__date">\s*(\d{4}/\d{2}/\d{2})');

/// Section [sectionId] (e.g. `ranking-weekly`) of a DAM ranking page. The
/// period is derived for weekly charts, which run Sunday to Saturday and are
/// published the next Sunday.
({List<ChartEntry> entries, String period, String updated}) parseDamPage(String html, {String sectionId = 'ranking-weekly'}) {
  final starts = _damSection.allMatches(html).toList();
  final i = starts.indexWhere((m) => m.group(1) == sectionId);
  if (i < 0) throw ChartException(ChartErrorKind.format, 'no section $sectionId');
  final body = html.substring(starts[i].end, i + 1 < starts.length ? starts[i + 1].start : html.length);
  final seen = <String>{};
  final entries = <ChartEntry>[];
  for (final m in _damRow.allMatches(body)) {
    final no = m.group(1)!;
    // PC and mobile layouts may both be in the page.
    if (!seen.add(no)) continue;
    entries.add(ChartEntry(rank: int.parse(m.group(2)!), title: htmlUnescape(m.group(3)!.trim()), artist: htmlUnescape(m.group(4)!.trim()), songNo: no));
  }
  if (entries.isEmpty) throw ChartException(ChartErrorKind.format, 'no songs in $sectionId');
  final updated = _damDate.firstMatch(body)?.group(1) ?? '';
  var period = '';
  final u = _parseSlashDate(updated);
  if (sectionId == 'ranking-weekly' && u != null && u.weekday == DateTime.sunday) {
    period = _period(_slashDate(u.subtract(const Duration(days: 7))), _slashDate(u.subtract(const Duration(days: 1))));
  }
  return (entries: entries, period: period, updated: updated);
}

DateTime? _parseSlashDate(String s) {
  final m = RegExp(r'^(\d{4})/(\d{2})/(\d{2})$').firstMatch(s);
  return m == null ? null : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String _slashDate(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

const _entities = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' '};

/// Unescapes named (the common ones) and numeric HTML character references.
String htmlUnescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final ref = m.group(1)!;
    if (ref.startsWith('#')) {
      final hex = ref.length > 1 && (ref[1] == 'x' || ref[1] == 'X');
      final code = int.tryParse(hex ? ref.substring(2) : ref.substring(1), radix: hex ? 16 : 10);
      return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
    }
    return _entities[ref] ?? m.group(0)!;
  });
}

// --- service ---------------------------------------------------------------

class KtvChartService {
  KtvChartService({http.Client? client, this.cacheDir, this.ttl = const Duration(hours: 6), this.timeout = const Duration(seconds: 20), DateTime Function()? now})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _now = now ?? DateTime.now;

  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  /// Where charts are kept between launches; memory only when null.
  final String? cacheDir;
  final Duration ttl;
  final Duration timeout;

  final _memory = <String, KtvChart>{};
  final _pending = <String, Future<KtvChart>>{};

  static const _userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) KaraokeBattle';
  static const _formType = 'application/x-www-form-urlencoded; charset=utf-8';

  /// The chart for [board]: from the cache while it is younger than [ttl],
  /// else fetched. [force] skips the cache. Throws [ChartException].
  Future<KtvChart> load(ChartBoard board, {bool force = false}) {
    final pending = _pending[board.key];
    if (pending != null) return pending;
    // A block body: returning the removed future would make it wait on itself.
    final f = _load(board, force).whenComplete(() {
      _pending.remove(board.key);
    });
    _pending[board.key] = f;
    return f;
  }

  Future<KtvChart> _load(ChartBoard board, bool force) async {
    if (!force) {
      final cached = _memory[board.key] ?? await _readDisk(board);
      if (cached != null && _now().difference(cached.fetchedAt) < ttl) {
        _memory[board.key] = cached;
        return cached;
      }
    }
    final chart = await _fetch(board);
    _memory[board.key] = chart;
    await _writeDisk(chart);
    return chart;
  }

  Future<KtvChart> _fetch(ChartBoard board) async {
    final now = _now();
    switch (board.vendor) {
      case KtvVendor.holiday:
        final first = parseHolidayPage(await _holidayPage(board.id, 1));
        final entries = [...first.entries];
        // 30 entries in two pages; the cap guards against a bogus MaxPage.
        for (var page = 2; page <= first.maxPage && page <= 5; page++) {
          entries.addAll(parseHolidayPage(await _holidayPage(board.id, page)).entries);
        }
        entries.sort((a, b) => a.rank.compareTo(b.rank));
        return KtvChart(board: board, entries: entries, period: first.period, fetchedAt: now);
      case KtvVendor.cashbox:
        final [type, lang] = board.id.substring(1).split('-');
        final body = await _send(
          http.Request('POST', Uri.parse('https://www.cashboxparty.com/ashx/ah_Song.ashx'))
            ..headers.addAll({'Content-Type': _formType, 'Referer': 'https://www.cashboxparty.com/Music/KTVMusic.aspx'})
            ..body = jsonEncode([
              {'m': 'bl', 't': type, 'lang': lang},
            ]),
        );
        final r = parseCashboxChart(body, lang: lang);
        return KtvChart(board: board, entries: r.entries, period: r.period, fetchedAt: now);
      case KtvVendor.joysound:
        final r = parseJoysoundPage(await _send(http.Request('GET', Uri.parse('https://www.joysound.com/web/karaoke/ranking/${board.id}/weekly'))));
        return KtvChart(board: board, entries: r.entries, period: r.period, fetchedAt: now);
      case KtvVendor.dam:
        final r = parseDamPage(await _send(http.Request('GET', Uri.parse('https://www.clubdam.com${_damPath(board.id)}'))));
        return KtvChart(board: board, entries: r.entries, period: r.period, updated: r.updated, fetchedAt: now);
    }
  }

  Future<String> _holidayPage(String ltype, int page) => _send(
    http.Request('POST', Uri.parse('https://www.holiday.com.tw/Ashx/SongInfo.ashx'))
      ..headers['Content-Type'] = _formType
      ..body = jsonEncode([
        {'m': 'top', 'ltype': ltype, 'page': page},
      ]),
  );

  /// Sends [req] and returns the UTF-8 body of a 200 response.
  Future<String> _send(http.Request req) async {
    req.headers['User-Agent'] = _userAgent;
    try {
      final resp = await http.Response.fromStream(await _client.send(req).timeout(timeout)).timeout(timeout);
      if (resp.statusCode != 200) throw ChartException(ChartErrorKind.http, '${resp.statusCode}');
      var body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (body.startsWith('﻿')) body = body.substring(1);
      return body;
    } on TimeoutException {
      throw const ChartException(ChartErrorKind.timeout);
    } on ChartException {
      rethrow;
    } catch (e) {
      throw ChartException(ChartErrorKind.network, '$e');
    }
  }

  File? _cacheFile(ChartBoard board) => cacheDir == null ? null : File(p.join(cacheDir!, 'ktv_charts', '${board.key}.json'));

  Future<KtvChart?> _readDisk(ChartBoard board) async {
    final f = _cacheFile(board);
    if (f == null) return null;
    try {
      if (!await f.exists()) return null;
      return KtvChart.fromJson(board, jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(KtvChart chart) async {
    final f = _cacheFile(chart.board);
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(chart.toJson()));
    } catch (_) {
      // The memory cache still works.
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
