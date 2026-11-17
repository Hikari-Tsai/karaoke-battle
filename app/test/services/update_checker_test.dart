import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/services/update_checker.dart';

void main() {
  test('parses tags and build/pre-release suffixes', () {
    expect(UpdateChecker.parseVersion('v0.1.1'), [0, 1, 1]);
    expect(UpdateChecker.parseVersion('1.2.3+45'), [1, 2, 3]);
    expect(UpdateChecker.parseVersion('1.2.3-beta.1'), [1, 2, 3]);
    expect(UpdateChecker.parseVersion('2'), [2, 0, 0]);
  });

  test('compares versions numerically', () {
    expect(UpdateChecker.isNewer('v0.1.1', '0.1.0'), isTrue);
    expect(UpdateChecker.isNewer('v0.1.0', '0.1.0'), isFalse);
    expect(UpdateChecker.isNewer('v0.10.0', '0.9.9'), isTrue);
    expect(UpdateChecker.isNewer('v0.1.0', '1.0.0'), isFalse);
    expect(UpdateChecker.compareVersions('1.0.0+7', '1.0.0+3'), 0);
  });

  test('parses the GitHub latest-release payload', () {
    final r = UpdateChecker.parseLatest('{"tag_name":"v0.2.0","name":"v0.2.0","html_url":"https://github.com/Hikari-Tsai/karaoke-battle/releases/tag/v0.2.0"}');
    expect(r.tag, 'v0.2.0');
    expect(r.version, '0.2.0');
    expect(r.url, endsWith('/tag/v0.2.0'));
  });

  group('changelog', () {
    const sample = '''
# 更新紀錄

<!--
## 9.9.9 — a heading inside a comment is not a version
-->

## [Unreleased]
- not yet

## 1.2.0 — 2026-12-01

### 新增
- 新功能 `code`

## v1.1.0 - 2026-11-20
### 修正
- 修正一

## 1.0.0 — 2026-11-15
第一版。
''';

    test('splits version sections and skips other headings and comments', () {
      final all = UpdateChecker.parseChangelog(sample);
      expect(all.map((n) => n.version), ['1.2.0', '1.1.0', '1.0.0']);
      expect(all.first.date, '2026-12-01');
      expect(all.first.lines, ['### 新增', '- 新功能 `code`']);
      expect(all[1].date, '2026-11-20');
      expect(all.last.lines, ['第一版。']);
    });

    test('keeps the versions after the current one up to the latest', () {
      final all = UpdateChecker.parseChangelog(sample);
      expect(UpdateChecker.notesBetween(all, '1.0.0', '1.2.0').map((n) => n.version), ['1.2.0', '1.1.0']);
      expect(UpdateChecker.notesBetween(all, '1.1.0', '1.1.0'), isEmpty);
      expect(UpdateChecker.notesBetween(all, '1.0.0', '1.1.0').map((n) => n.version), ['1.1.0']);
    });

    test('the repository changelogs parse in all three languages', () {
      final versions = <List<String>>[];
      for (final f in ['CHANGELOG.md', 'CHANGELOG.en.md', 'CHANGELOG.ja.md']) {
        final all = UpdateChecker.parseChangelog(File('../$f').readAsStringSync());
        expect(all, isNotEmpty, reason: f);
        for (final n in all) {
          expect(n.lines, isNotEmpty, reason: '$f ${n.version}');
          expect(n.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')), reason: '$f ${n.version}');
        }
        versions.add(all.map((n) => n.version).toList());
      }
      expect(versions[1], versions[0], reason: 'CHANGELOG.en.md has the same versions');
      expect(versions[2], versions[0], reason: 'CHANGELOG.ja.md has the same versions');
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final appVersion = RegExp(r'^version:\s*([\d.]+)', multiLine: true).firstMatch(pubspec)!.group(1)!;
      expect(UpdateChecker.compareVersions(versions[0].first, appVersion), greaterThanOrEqualTo(0),
          reason: 'CHANGELOG.md needs a section for $appVersion');
    });

    test('fetches the UI-language file at the tag, falling back to zh', () async {
      final asked = <String>[];
      final client = MockClient((req) async {
        asked.add(req.url.path);
        if (req.url.path.endsWith('CHANGELOG.ja.md')) return http.Response('', 404);
        return http.Response.bytes(utf8.encode(sample), 200);
      });
      UpdateChecker.currentVersion = '1.0.0';
      const rel = ReleaseInfo(tag: 'v1.2.0', version: '1.2.0', url: '');
      final notes = await UpdateChecker.fetchNotes(rel, 'ja', client: client);
      expect(notes.map((n) => n.version), ['1.2.0', '1.1.0']);
      expect(asked, ['/Hikari-Tsai/karaoke-battle/v1.2.0/CHANGELOG.ja.md', '/Hikari-Tsai/karaoke-battle/v1.2.0/CHANGELOG.md']);
    });
  });
}
