import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/downloader.dart';
import 'package:karaoke_battle/services/model_registry.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/state/setup_controller.dart';
import 'package:path/path.dart' as p;

/// A stand-in yt-dlp: `-U` prints [update]; a download fails with a 403
/// until an update has happened, then writes `source.mp4` and prints its path.
Future<void> _fakeYtDlp(AppPaths paths, {required String update}) =>
    _writeFakeYtDlp(p.join(paths.sidecars, 'yt-dlp'), p.join(paths.sidecars, 'updated'), update: update);

/// [marker] is created by an `Updated…` `-U` and unlocks downloads.
Future<void> _writeFakeYtDlp(String path, String marker, {required String update}) async {
  await Directory(p.dirname(path)).create(recursive: true);
  final exe = File(path);
  await exe.writeAsString('''#!/bin/sh
if [ "\$1" = "-U" ]; then
  case "$update" in Updated*) touch "$marker";; esac
  echo "$update"; exit 0
fi
if [ ! -f "$marker" ]; then
  echo "ERROR: unable to download video data: HTTP Error 403: Forbidden" >&2; exit 1
fi
prev=""; for a; do [ "\$prev" = "-o" ] && tmpl="\$a"; prev="\$a"; done
f="\$(dirname "\$tmpl")/source.mp4"; touch "\$f"; echo "\$f"
''');
  await Process.run('chmod', ['+x', exe.path]);
}

/// "Downloads" yt-dlp from the catalog by writing a fake one.
class _FakeDownloader extends Downloader {
  _FakeDownloader(this.marker, this.update, {this.gate});
  final String marker;
  final String update;
  /// When set, downloads wait for it (to overlap calls).
  final Future<void>? gate;
  final urls = <Uri>[];

  @override
  Future<void> download(Uri url, String destPath,
      {String? sha256, void Function(DownloadProgress)? onProgress, Future<void>? cancel, Map<String, String>? headers}) async {
    urls.add(url);
    await gate;
    await _writeFakeYtDlp(destPath, marker, update: update);
  }
}

/// Resolves yt-dlp like the real thing, but with [pathYtDlp] standing in for
/// one found on PATH (winget, scoop, pip, Homebrew).
class _PathSidecars extends Sidecars {
  _PathSidecars(super.paths, super.catalog, this.pathYtDlp, {super.downloader});
  final String? pathYtDlp;

  @override
  Future<String?> resolve(SidecarKind k) async {
    if (k != SidecarKind.ytDlp) return null;
    final managed = managedPath(k);
    return await File(managed).exists() ? managed : pathYtDlp;
  }
}

final _catalog = SidecarCatalog({
  SidecarKind.ytDlp: {
    for (final k in SidecarCatalog.platformKeys) k: const SidecarSource(url: 'https://example.invalid/yt-dlp'),
  },
});

void main() {
  late Directory tmp;
  late AppPaths paths;
  late Sidecars sidecars;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidecars_test');
    paths = AppPaths.forTest(tmp.path);
    sidecars = Sidecars(paths, SidecarCatalog({}));
  });

  tearDown(() => tmp.delete(recursive: true));

  final skip = Platform.isWindows ? 'the fake yt-dlp is a shell script' : null;

  test('a failed download updates yt-dlp and tries again', skip: skip, () async {
    await _fakeYtDlp(paths, update: 'Updated yt-dlp to stable@2026.10.26');
    final out = await Directory(p.join(tmp.path, 'song')).create();
    final lines = <String>[];
    final file = await sidecars.downloadVideo('https://youtu.be/x', out.path, onProgress: (_, l) => lines.add(l));
    expect(file, p.join(out.path, 'source.mp4'));
    expect(lines, contains('Updated yt-dlp to stable@2026.10.26'));
  });

  test('without a newer yt-dlp the error carries its ERROR line', skip: skip, () async {
    await _fakeYtDlp(paths, update: 'yt-dlp is up to date (stable@2026.10.26)');
    final out = await Directory(p.join(tmp.path, 'song')).create();
    await expectLater(
      sidecars.downloadVideo('https://youtu.be/x', out.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'yt-dlp exited with 1: ERROR: unable to download video data: HTTP Error 403: Forbidden')),
    );
  });

  group('only a yt-dlp on PATH', () {
    late String marker;
    setUp(() => marker = p.join(tmp.path, 'managed-updated'));

    test('updating installs the app\'s own copy, then runs -U on it', skip: skip, () async {
      final dl = _FakeDownloader(marker, 'Updated yt-dlp to stable@2026.10.26');
      final s = _PathSidecars(paths, _catalog, '/usr/bin/false', downloader: dl);
      final r = await s.updateYtDlp();
      expect(r.installed, isTrue);
      expect(r.output, 'Updated yt-dlp to stable@2026.10.26');
      expect(dl.urls, [Uri.parse('https://example.invalid/yt-dlp')]);
      expect(await s.resolve(SidecarKind.ytDlp), s.managedPath(SidecarKind.ytDlp));

      final again = await s.updateYtDlp();
      expect(again.installed, isFalse);
      expect(dl.urls, hasLength(1));
    });

    test('a failed download installs the app\'s copy and tries again', skip: skip, () async {
      // The PATH yt-dlp is stuck on an old version: always 403, never updates.
      final pathExe = p.join(tmp.path, 'bin', 'yt-dlp');
      await _writeFakeYtDlp(pathExe, p.join(tmp.path, 'never'), update: 'nope');
      // The fresh copy is already the newest, so -U changes nothing.
      final s = _PathSidecars(paths, _catalog, pathExe, downloader: _FakeDownloader(marker, 'yt-dlp is up to date (stable@2026.10.26)'));
      await File(marker).create(); // the managed copy downloads fine
      final out = await Directory(p.join(tmp.path, 'song')).create();
      final lines = <String>[];
      final file = await s.downloadVideo('https://youtu.be/x', out.path, onProgress: (_, l) => lines.add(l));
      expect(file, p.join(out.path, 'source.mp4'));
      expect(lines, containsAllInOrder([tr('sidecars.ytDlpInstalling'), tr('sidecars.ytDlpInstalled')]));
    });

    test('when the app\'s copy cannot be installed the download error stands', skip: skip, () async {
      final pathExe = p.join(tmp.path, 'bin', 'yt-dlp');
      await _writeFakeYtDlp(pathExe, p.join(tmp.path, 'never'), update: 'nope');
      final s = _PathSidecars(paths, SidecarCatalog({}), pathExe);
      final out = await Directory(p.join(tmp.path, 'song')).create();
      await expectLater(
        s.downloadVideo('https://youtu.be/x', out.path),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('HTTP Error 403'))),
      );
    });
  });

  group('installs that overlap', () {
    late String marker;
    setUp(() => marker = p.join(tmp.path, 'managed-updated'));

    test('share one download', skip: skip, () async {
      final gate = Completer<void>();
      final dl = _FakeDownloader(marker, 'yt-dlp is up to date', gate: gate.future);
      final s = Sidecars(paths, _catalog, downloader: dl);
      final a = s.install(SidecarKind.ytDlp);
      final b = s.install(SidecarKind.ytDlp);
      gate.complete();
      expect(await Future.wait([a, b]), [s.managedPath(SidecarKind.ytDlp), s.managedPath(SidecarKind.ytDlp)]);
      expect(dl.urls, hasLength(1));
    });

    test('pressing Update yt-dlp while the row installs it downloads once and succeeds', skip: skip, () async {
      final gate = Completer<void>();
      final dl = _FakeDownloader(marker, 'Updated yt-dlp to stable@2026.10.26', gate: gate.future);
      final s = _PathSidecars(paths, _catalog, null, downloader: dl);
      final setup = SetupController(ModelStore(paths), s);
      final row = setup.installSidecar(SidecarKind.ytDlp);
      final update = setup.updateYtDlp();
      expect(setup.ytDlpBusy, isTrue);
      gate.complete();
      await row;
      final r = await update;
      expect(r.ok, isTrue, reason: r.message);
      expect(r.message, contains('Updated yt-dlp to stable@2026.10.26'));
      expect(dl.urls, hasLength(1));
      expect(await File(s.managedPath(SidecarKind.ytDlp)).exists(), isTrue);
      expect(setup.ytDlpBusy, isFalse);
    });

    test('a failed -U is reported as a failure', skip: skip, () async {
      await Directory(paths.sidecars).create(recursive: true);
      final exe = File(p.join(paths.sidecars, 'yt-dlp'));
      await exe.writeAsString('#!/bin/sh\necho "ERROR: Unable to write to yt-dlp" >&2; exit 1\n');
      await Process.run('chmod', ['+x', exe.path]);
      final setup = SetupController(ModelStore(paths), _PathSidecars(paths, _catalog, null));
      final r = await setup.updateYtDlp();
      expect(r.ok, isFalse);
      expect(r.message, contains('Unable to write'));
    });
  });

  group('launch check', () {
    Future<void> script(String body) async {
      await Directory(paths.sidecars).create(recursive: true);
      final exe = File(p.join(paths.sidecars, 'yt-dlp'));
      await exe.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', exe.path]);
    }

    test('the app\'s copy runs', skip: skip, () async {
      await script('echo 2026.10.26');
      final r = await sidecars.checkYtDlp();
      expect(r.health, YtDlpHealth.ok);
      expect(r.detail, '2026.10.26');
    });

    test('the app\'s copy does not run', skip: skip, () async {
      await script('echo "Bad CPU type in executable" >&2; exit 126');
      final r = await sidecars.checkYtDlp();
      expect(r.health, YtDlpHealth.broken);
      expect(r.detail, contains('Bad CPU type'));
    });

    test('only a PATH copy, or none; a stale .part is cleared', skip: skip, () async {
      await Directory(paths.sidecars).create(recursive: true);
      final part = File('${sidecars.managedPath(SidecarKind.ytDlp)}.part');
      await part.writeAsString('half');
      final onPath = await _PathSidecars(paths, _catalog, '/opt/homebrew/bin/yt-dlp').checkYtDlp();
      expect(onPath, (health: YtDlpHealth.pathOnly, detail: '/opt/homebrew/bin/yt-dlp'));
      expect(await part.exists(), isFalse);
      expect((await _PathSidecars(paths, _catalog, null).checkYtDlp()).health, YtDlpHealth.missing);
    });
  });
}
