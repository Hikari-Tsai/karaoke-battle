// Cancelling never leaves a progress bar stuck: downloads stop at once (also
// on a stalled connection), killed tools return even when a child keeps
// their pipes open, and a song cancelled while queued leaves the queue.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/engine/engine.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/backend_manager.dart';
import 'package:karaoke_battle/services/downloader.dart';
import 'package:karaoke_battle/services/model_registry.dart';
import 'package:karaoke_battle/services/prep_pipeline.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sends the headers and a few bytes, then nothing.
Future<HttpServer> stallingServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    req.response
      ..contentLength = 1 << 20
      ..add(List.filled(1024, 7));
    req.response.flush();
  });
  return server;
}

/// Blocks every download until it is cancelled.
class _BlockingDownloader extends Downloader {
  @override
  Future<void> download(Uri url, String destPath,
      {String? sha256, void Function(DownloadProgress)? onProgress, Future<void>? cancel, Map<String, String>? headers}) async {
    await (cancel ?? Completer<void>().future);
    throw DownloadException('cancelled');
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ke-cancel-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a download stops at once when cancelled, even with no data coming', () async {
    final server = await stallingServer();
    final cancel = Completer<void>();
    final sw = Stopwatch()..start();
    final f = Downloader().download(Uri.parse('http://127.0.0.1:${server.port}/x'), '${tmp.path}/x.bin', cancel: cancel.future);
    Timer(const Duration(milliseconds: 300), cancel.complete);
    await expectLater(f, throwsA(isA<DownloadException>().having((e) => e.message, 'message', 'cancelled')));
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(File('${tmp.path}/x.bin.part').existsSync(), isFalse);
    await server.close(force: true);
  });

  test('a stalled download fails after the idle timeout instead of hanging', () async {
    final server = await stallingServer();
    final dl = Downloader(idleTimeout: const Duration(milliseconds: 400));
    await expectLater(
      dl.download(Uri.parse('http://127.0.0.1:${server.port}/x'), '${tmp.path}/x.bin'),
      throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('no data'))),
    );
    await server.close(force: true);
  });

  test('a cancelled tool returns although a child it started keeps the pipes open', () async {
    if (Platform.isWindows) return; // sh; Windows uses taskkill /T, exercised in the app
    final s = Sidecars(AppPaths.forTest(tmp.path), SidecarCatalog({}));
    final cancel = Completer<void>();
    final lines = <String>[];
    final sw = Stopwatch()..start();
    final run = s.run('/bin/sh', ['-c', 'sleep 30 & echo started; sleep 30'], cancel: cancel.future, onLine: lines.add);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    cancel.complete();
    final code = await run;
    expect(code, isNot(0));
    expect(lines, contains('started'));
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('cancelling a queued song takes it out of the queue; the running one stops', () async {
    SharedPreferences.setMockInitialValues({});
    final paths = AppPaths.forTest(tmp.path);
    final settings = await AppSettings.load();
    final library = SongLibrary(paths);
    final pipeline = PrepPipeline(
      library: library,
      sidecars: Sidecars(paths, SidecarCatalog({})),
      models: ModelStore(paths, downloader: _BlockingDownloader()),
      backend: BackendManager(Engine.instance, paths, settings),
      settings: settings,
    );
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    final b = await library.create(title: 'B', sourceType: SourceType.file);
    pipeline.enqueue(a);
    pipeline.enqueue(b);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(pipeline.isQueued(b.id), isTrue);

    await pipeline.cancel(b.id);
    expect(pipeline.isQueued(b.id), isFalse, reason: 'its progress bar is gone');
    expect(b.stage, PrepStage.failed, reason: 'so it can be retried');

    await pipeline.cancel(a.id).timeout(const Duration(seconds: 3));
    expect(a.stage, PrepStage.failed);
    pipeline.enqueue(b);
    expect(pipeline.isQueued(b.id), isTrue, reason: 'a cancelled song can be queued again');
    await pipeline.cancel(b.id).timeout(const Duration(seconds: 3));
  });
}
