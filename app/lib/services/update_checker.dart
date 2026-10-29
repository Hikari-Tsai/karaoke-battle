// Update check against the GitHub Releases of this project.
import 'dart:convert';

import 'package:http/http.dart' as http;

class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.version, required this.url, this.name = ''});
  final String tag; // e.g. v0.1.1
  final String version; // e.g. 0.1.1
  final String url; // release page
  final String name;
}

class UpdateChecker {
  UpdateChecker._();

  static const repo = 'Hikari-Tsai/karaoke-battle';
  static const repoUrl = 'https://github.com/$repo';
  static const releasesUrl = 'https://github.com/$repo/releases';
  static const latestApi = 'https://api.github.com/repos/$repo/releases/latest';

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
