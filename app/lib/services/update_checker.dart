// Update check against the GitHub Releases of this project.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.version, required this.url, this.name = ''});
  final String tag; // e.g. v0.1.1
  final String version; // e.g. 0.1.1
  final String url; // release page
  final String name;
}

/// One version's section of CHANGELOG.md: the text under `## X.Y.Z — date`.
class ReleaseNotes {
  const ReleaseNotes({required this.version, required this.date, required this.lines});
  final String version; // e.g. 1.2.3
  final String date; // e.g. 2026-11-16, or '' when the heading has none
  /// Non-blank lines of the section as written (`### Added`, `- item`, text).
  final List<String> lines;
}

class UpdateChecker {
  UpdateChecker._();

  static const repo = 'Hikari-Tsai/karaoke-battle';
  static const repoUrl = 'https://github.com/$repo';
  static const releasesUrl = 'https://github.com/$repo/releases';
  static const latestApi = 'https://api.github.com/repos/$repo/releases/latest';

  /// A release newer than this app, from the last check (null when none).
  /// The About screen checks at launch, since the shell builds every tab;
  /// the rail and the settings screen show the result.
  static final available = ValueNotifier<ReleaseInfo?>(null);

  /// This app's version, set by the About screen once known ('' until then).
  static String currentVersion = '';

  /// The changelog file for a UI language (zh is the main one).
  static String changelogFile(String lang) => switch (lang) {
        'en' => 'CHANGELOG.en.md',
        'ja' => 'CHANGELOG.ja.md',
        _ => 'CHANGELOG.md',
      };

  static String changelogUrl(String ref, String lang) => 'https://raw.githubusercontent.com/$repo/$ref/${changelogFile(lang)}';

  /// Splits a CHANGELOG into its version sections, newest first as written.
  /// Headings other than `## X.Y.Z…` (title, "unreleased") are skipped.
  static List<ReleaseNotes> parseChangelog(String text) {
    final heading = RegExp(r'^##\s+\[?v?(\d+\.\d+\.\d+)\]?\s*(?:[—–-]+\s*(\S+))?');
    final out = <ReleaseNotes>[];
    String? version;
    var date = '';
    var lines = <String>[];
    var inComment = false;
    void flush() {
      if (version != null) out.add(ReleaseNotes(version: version, date: date, lines: lines));
    }

    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trimRight();
      if (inComment) {
        if (line.contains('-->')) inComment = false;
        continue;
      }
      if (line.trimLeft().startsWith('<!--')) {
        inComment = !line.contains('-->');
        continue;
      }
      if (line.startsWith('## ')) {
        flush();
        final m = heading.firstMatch(line);
        version = m?.group(1);
        date = m?.group(2) ?? '';
        lines = <String>[];
        continue;
      }
      if (line.startsWith('# ')) continue;
      if (version != null && line.trim().isNotEmpty) lines.add(line);
    }
    flush();
    return out;
  }

  /// The sections newer than [current] up to and including [latest], newest first.
  static List<ReleaseNotes> notesBetween(List<ReleaseNotes> all, String current, String latest) => [
        for (final n in all)
          if (compareVersions(n.version, current) > 0 && compareVersions(n.version, latest) <= 0) n,
      ]..sort((a, b) => compareVersions(b.version, a.version));

  static final _notesCache = <String, Future<List<ReleaseNotes>>>{};

  /// The changelog sections between this app and [release], in the UI
  /// language (falling back to the zh file). Empty when the tag has no
  /// changelog; a failed fetch is not cached, so the next call retries.
  static Future<List<ReleaseNotes>> fetchNotes(ReleaseInfo release, String lang, {http.Client? client}) {
    final key = '${release.tag}/$lang/$currentVersion';
    return _notesCache[key] ??= () async {
      final c = client ?? http.Client();
      try {
        Future<String?> get(String ref, String l) async {
          final resp = await c.get(Uri.parse(changelogUrl(ref, l)), headers: const {'User-Agent': 'karaoke-battle'}).timeout(const Duration(seconds: 15));
          if (resp.statusCode == 404) return null;
          if (resp.statusCode != 200) throw Exception('changelog ${resp.statusCode}');
          return utf8.decode(resp.bodyBytes);
        }

        Future<String?> at(String ref) async => await get(ref, lang) ?? (lang == 'zh' ? null : await get(ref, 'zh'));
        // Tags before the changelog existed (up to v1.1.5) have none: use
        // main's, whose sections up to the release are the same.
        final text = await at(release.tag) ?? await at('main');
        if (text == null) return const <ReleaseNotes>[];
        return notesBetween(parseChangelog(text), currentVersion, release.version);
      } catch (e) {
        _notesCache.remove(key);
        rethrow;
      } finally {
        if (client == null) c.close();
      }
    }();
  }

  /// Parses `v1.2.3`, `1.2.3+45` or `1.2.3-beta.1` into numeric components
  /// (`+build` and `-pre` suffixes are ignored; missing parts are 0).
  static List<int> parseVersion(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first.split('-').first;
    final parts = s.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  /// Negative when [a] < [b], zero when equal, positive when [a] > [b].
  static int compareVersions(String a, String b) {
    final pa = parseVersion(a);
    final pb = parseVersion(b);
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static bool isNewer(String candidate, String current) => compareVersions(candidate, current) > 0;

  /// Fetches the latest release. Throws on network or API errors.
  static Future<ReleaseInfo> fetchLatest({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final resp = await c
          .get(Uri.parse(latestApi), headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'karaoke-battle'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw Exception('GitHub API ${resp.statusCode}');
      }
      return parseLatest(resp.body);
    } finally {
      if (client == null) c.close();
    }
  }

  static ReleaseInfo parseLatest(String body) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final tag = j['tag_name'] as String? ?? '';
    return ReleaseInfo(
      tag: tag,
      version: parseVersion(tag).join('.'),
      url: j['html_url'] as String? ?? releasesUrl,
      name: j['name'] as String? ?? '',
    );
  }
}
