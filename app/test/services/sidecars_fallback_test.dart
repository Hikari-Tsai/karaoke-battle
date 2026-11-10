// Fallback download links and the online sidecar manifest.
//
// The live check (KE_LIVE_SIDECARS=1 flutter test test/services/sidecars_fallback_test.dart)
// resolves every fallback in assets/sidecars.json and finds its checksum at
// the publisher, without downloading the files.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/downloader.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:path/path.dart' as p;

const _hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Serves [texts] and [redirects]; downloads fail for URLs in [dead] and
/// otherwise write a file, recording the URL and the hash they were given.
class _FakeDownloader extends Downloader {
  _FakeDownloader({this.texts = const {}, this.redirects = const {}, this.dead = const {}});
  final Map<String, String> texts;
  final Map<String, String> redirects;
  final Set<String> dead;
  final downloads = <(String, String?)>[];
  final fetched = <String>[];

  @override
  Future<void> download(Uri url, String destPath,
      {String? sha256, void Function(DownloadProgress)? onProgress, Future<void>? cancel, Map<String, String>? headers}) async {
    downloads.add(('$url', sha256));
    if (dead.contains('$url')) throw DownloadException('HTTP 404 for $url');
    await File(destPath).parent.create(recursive: true);
    await File(destPath).writeAsString('#!/bin/sh\n');
  }

  @override
  Future<Uri> resolve(Uri url, {int maxHops = 5, Duration timeout = const Duration(seconds: 20)}) async => Uri.parse(redirects['$url'] ?? '$url');

  @override
  Future<String> fetchText(Uri url, {int maxBytes = 1 << 20, Duration timeout = const Duration(seconds: 20)}) async {
    fetched.add('$url');
    final t = texts['$url'];
    if (t == null) throw DownloadException('HTTP 404 for $url');
    return t;
  }
}

Map<String, dynamic> _manifest(Map<String, dynamic> ytAsset) => {
      'yt-dlp': {
        'assets': {for (final k in SidecarCatalog.platformKeys) k: ytAsset},
      },
    };

void main() {
  late Directory tmp;
  late AppPaths paths;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ke_sidecar_fb');
    paths = AppPaths.forTest(tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  group('checksumFor', () {
    test('picks the line for the file from a sha256sum list', () {
      expect(checksumFor('$_hashA  yt-dlp.exe\n$_hashB  yt-dlp_macos\n', 'yt-dlp_macos'), _hashB);
      expect(checksumFor('$_hashA *yt-dlp.exe\n', 'yt-dlp.exe'), _hashA);
      expect(checksumFor('$_hashA  yt-dlp.exe\n', 'other.zip'), isNull);
    });

    test('reads a single bare hash, but not a hash named for another file', () {
      expect(checksumFor('${_hashA.toUpperCase()}\n', 'x.zip'), _hashA);
      expect(checksumFor('$_hashA  ffmpeg.zip', 'ffprobe.zip'), isNull);
    });

    test('reads PowerShell Get-FileHash output (deno on Windows)', () {
      final text = '\r\nAlgorithm : SHA256\r\nHash      : ${_hashA.toUpperCase()}\r\nPath      : C:\\a\\deno\\target\\release\\deno-x86_64-pc-windows-msvc.zip\r\n\r\n';
      expect(checksumFor(text, 'deno-x86_64-pc-windows-msvc.zip'), _hashA);
      expect(checksumFor(text, 'other.zip'), isNull);
    });
  });

  test('the manifest parses fallbacks; unverifiable or non-https ones are dropped', () {
    final c = SidecarCatalog.fromJson(_manifest({
      'url': 'https://example.com/pinned',
      'sha256': _hashA,
      'fallbacks': [
        {'url': 'https://example.com/latest', 'sha256_url': 'https://example.com/SUMS'},
        {'url': 'https://example.com/redirect', 'sha256_suffix': '.sha256'},
        {'url': 'https://example.com/no-checksum'},
        {'url': 'http://example.com/plain', 'sha256': _hashB},
        {'url': 'https://example.com/plain-sums', 'sha256_url': 'http://example.com/SUMS'},
      ],
    }));
    final s = c.sourceFor(SidecarKind.ytDlp)!;
    expect(s.fallbacks.map((f) => f.url), ['https://example.com/latest', 'https://example.com/redirect']);
    expect(c.sourceFor(SidecarKind.deno), isNotNull, reason: 'kinds missing from the file come from the defaults');
    final online = SidecarCatalog.fromJson(_manifest({'url': 'https://example.com/pinned'}), withDefaults: false);
    expect(online.sourceFor(SidecarKind.deno), isNull, reason: 'the online copy only overrides what it lists');
  });

  test('the bundled manifest gives every sidecar a verifiable fallback', () {
    final c = SidecarCatalog.fromJson(jsonDecode(File('assets/sidecars.json').readAsStringSync()) as Map<String, dynamic>);
    for (final k in SidecarKind.values) {
      final s = c.sourceFor(k);
      expect(s, isNotNull, reason: k.name);
      expect(s!.sha256, isNotNull, reason: '${k.name} is pinned');
      expect(s.fallbacks, isNotEmpty, reason: '${k.name} has a fallback');
    }
  });

  test('a dead pinned link falls back to "latest", checked with the publisher checksum list', () async {
    final dl = _FakeDownloader(
      dead: {'https://example.com/v1/yt-dlp'},
      texts: {'https://example.com/latest/SUMS': '$_hashA  other\n$_hashB  yt-dlp\n'},
    );
    final s = Sidecars(paths, SidecarCatalog.fromJson(_manifest({
      'url': 'https://example.com/v1/yt-dlp',
      'sha256': _hashA,
      'fallbacks': [
        {'url': 'https://example.com/latest/yt-dlp', 'sha256_url': 'https://example.com/latest/SUMS'},
      ],
    })), downloader: dl);
    expect(await File(await s.install(SidecarKind.ytDlp)).exists(), isTrue);
    expect(dl.downloads, [('https://example.com/v1/yt-dlp', _hashA), ('https://example.com/latest/yt-dlp', _hashB)]);
  });

  test('a redirecting link downloads the file it resolved to and uses the checksum next to it', () async {
    final dl = _FakeDownloader(
      dead: {'https://example.com/v1/ffmpeg.zip'},
      redirects: {'https://example.com/redirect/latest/ffmpeg.zip': 'https://example.com/download/123_9.1/ffmpeg.zip'},
      texts: {'https://example.com/download/123_9.1/ffmpeg.zip.sha256': '$_hashB  ffmpeg.zip\n'},
    );
    final s = Sidecars(paths, SidecarCatalog.fromJson(_manifest({
      'url': 'https://example.com/v1/ffmpeg.zip',
      'sha256': _hashA,
      'fallbacks': [
        {'url': 'https://example.com/redirect/latest/ffmpeg.zip', 'sha256_suffix': '.sha256'},
      ],
    })), downloader: dl);
    await s.install(SidecarKind.ytDlp);
    expect(dl.downloads.last, ('https://example.com/download/123_9.1/ffmpeg.zip', _hashB));
  });

  test('when every source fails, the error names the pinned failure and each fallback', () async {
    final dl = _FakeDownloader(dead: {'https://example.com/v1/yt-dlp'});
    final s = Sidecars(paths, SidecarCatalog.fromJson(_manifest({
      'url': 'https://example.com/v1/yt-dlp',
      'sha256': _hashA,
      'fallbacks': [
        {'url': 'https://example.com/latest/yt-dlp', 'sha256_url': 'https://example.com/latest/SUMS'},
      ],
    })), downloader: dl);
    await expectLater(
      s.install(SidecarKind.ytDlp),
      throwsA(isA<DownloadException>().having((e) => e.message, 'message', allOf(contains('v1/yt-dlp'), contains('latest/SUMS')))),
    );
    expect(dl.downloads.length, 1, reason: 'no download without a checksum');
    expect(File(p.join(paths.sidecars, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp')).existsSync(), isFalse);
  });

  test('the online manifest overrides the bundled one; unreadable, the bundled one is used', () async {
    final bundled = SidecarCatalog.fromJson(_manifest({'url': 'https://example.com/bundled/yt-dlp', 'sha256': _hashA}));
    const online = 'https://example.com/sidecars.json';
    final fixed = _FakeDownloader(texts: {online: jsonEncode(_manifest({'url': 'https://example.com/fixed/yt-dlp', 'sha256': _hashB}))});
    await Sidecars(paths, bundled, downloader: fixed, onlineManifest: Uri.parse(online)).install(SidecarKind.ytDlp);
    expect(fixed.downloads.single, ('https://example.com/fixed/yt-dlp', _hashB));

    await File(p.join(paths.sidecars, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp')).delete();
    final offline = _FakeDownloader();
    final s = Sidecars(paths, bundled, downloader: offline, onlineManifest: Uri.parse(online));
    await s.install(SidecarKind.ytDlp);
    expect(offline.downloads.single, ('https://example.com/bundled/yt-dlp', _hashA));
    expect(await s.sourceFor(SidecarKind.ytDlp), isNotNull);
    expect(offline.fetched.where((u) => u == online).length, 2, reason: 'a failed read is retried next time');
  });

  test('live: every fallback in assets/sidecars.json resolves and has a publisher checksum', () async {
    final j = jsonDecode(File('assets/sidecars.json').readAsStringSync()) as Map<String, dynamic>;
    final fallbacks = <(String, Map<String, dynamic>)>[];
    void walk(Object? o, String at) {
      if (o is Map<String, dynamic>) {
        for (final e in o.entries) {
          if (e.key == 'fallbacks' && e.value is List) {
            for (final f in e.value as List) {
              fallbacks.add((at, f as Map<String, dynamic>));
            }
          } else {
            walk(e.value, '$at/${e.key}');
          }
        }
      }
    }

    walk(j, '');
    final dl = Downloader();
    final failures = <String>[];
    for (final (at, f) in fallbacks) {
      final url = Uri.parse(f['url'] as String);
      try {
        final name = p.basename(url.path);
        final Uri sums;
        if (f['sha256_suffix'] != null) {
          sums = Uri.parse('${await dl.resolve(url)}${f['sha256_suffix']}');
        } else {
          await dl.resolve(url);
          sums = Uri.parse(f['sha256_url'] as String);
        }
        final hash = checksumFor(await dl.fetchText(sums), name);
        if (hash == null) failures.add('$at $url: no checksum for $name in $sums');
        // ignore: avoid_print
        print('ok $at $url ${hash?.substring(0, 12)}');
      } catch (e) {
        failures.add('$at $url: $e');
      }
    }
    dl.close();
    expect(failures, isEmpty);
  }, skip: Platform.environment['KE_LIVE_SIDECARS'] == '1' ? false : 'set KE_LIVE_SIDECARS=1', timeout: const Timeout(Duration(minutes: 3)));

  test('live: with the pinned link dead, ffmpeg installs from its fallback and runs', () async {
    final j = jsonDecode(File('assets/sidecars.json').readAsStringSync()) as Map<String, dynamic>;
    final real = SidecarCatalog.fromJson(j).sourceFor(SidecarKind.ffmpeg)!;
    final broken = SidecarSource(
      url: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-10-27-18-38/gone.zip',
      sha256: real.sha256,
      archiveMember: real.archiveMember,
      fallbacks: real.fallbacks,
    );
    final s = Sidecars(paths, SidecarCatalog({SidecarKind.ffmpeg: {for (final k in SidecarCatalog.platformKeys) k: broken}}));
    final exe = await s.install(SidecarKind.ffmpeg);
    final r = await Process.run(exe, ['-hide_banner', '-version']);
    expect(r.exitCode, 0);
    expect('${r.stdout}', startsWith('ffmpeg version'));
  }, skip: Platform.environment['KE_LIVE_SIDECARS'] == '1' ? false : 'set KE_LIVE_SIDECARS=1', timeout: const Timeout(Duration(minutes: 5)));
}
