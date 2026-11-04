import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/services/downloader.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('downloader_test'));
  tearDown(() => tmp.delete(recursive: true));

  // Two downloads of the same file at once share `<dest>.part`. The one that
  // finishes second used to delete the file the first had just renamed into
  // place, then fail to rename the .part that was already gone, leaving
  // nothing behind (the macOS "Cannot rename file to …/sidecars/yt-dlp").
  test('two overlapping downloads of the same file both end with the file', () async {
    final body = List<int>.generate(256 * 1024, (i) => i % 251);
    final sum = c.sha256.convert(body).toString();
    final second = Completer<void>();
    var requests = 0;
    final client = MockClient.streaming((req, _) async {
      final n = ++requests;
      final out = StreamController<List<int>>();
      () async {
        for (var i = 0; i < body.length; i += 16 * 1024) {
          // The first download finishes while the second is still writing.
          if (n == 2 && i == 128 * 1024) await second.future;
          out.add(body.sublist(i, i + 16 * 1024));
          await Future<void>.delayed(Duration.zero);
        }
        await out.close();
      }();
      return http.StreamedResponse(out.stream, 200, contentLength: body.length);
    });
    final dl = Downloader(client: client);
    final dest = p.join(tmp.path, 'tool');
    final a = dl.download(Uri.parse('https://example.invalid/tool'), dest, sha256: sum);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final b = dl.download(Uri.parse('https://example.invalid/tool'), dest, sha256: sum);
    await a;
    second.complete();
    await b;
    expect(await File(dest).exists(), isTrue);
    expect(await Downloader.sha256OfFile(dest), sum);
    expect(await File('$dest.part').exists(), isFalse);
  });
}
