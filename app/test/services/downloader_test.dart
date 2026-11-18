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

  group('certificate errors (issue #6)', () {
    final body = List<int>.generate(4096, (i) => i % 251);
    final sum = c.sha256.convert(body).toString();
    final url = Uri.parse('https://example.invalid/pack.zip');
    late int checkedCalls, uncheckedCalls;
    late Downloader dl;

    setUp(() {
      Downloader.resetCertificateDecision();
      Downloader.certificatePrompt = null;
      checkedCalls = uncheckedCalls = 0;
      dl = Downloader(
        client: MockClient((_) async {
          checkedCalls++;
          throw HandshakeException('Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate)');
        }),
        uncheckedClient: MockClient((_) async {
          uncheckedCalls++;
          return http.Response.bytes(body, 200);
        }),
      );
    });
    tearDown(() {
      Downloader.certificatePrompt = null;
      Downloader.resetCertificateDecision();
    });

    test('nobody to ask: fails with a certificate error', () async {
      await expectLater(dl.download(url, p.join(tmp.path, 'a'), sha256: sum), throwsA(isA<CertificateException>()));
      expect(checkedCalls, 1);
      expect(uncheckedCalls, 0);
    });

    test('accepted once: retried without the check, later downloads do not ask again', () async {
      var asked = 0;
      Downloader.certificatePrompt = (u, e) async {
        asked++;
        expect(u, url);
        expect(e, contains('CERTIFICATE_VERIFY_FAILED'));
        return true;
      };
      await dl.download(url, p.join(tmp.path, 'a'), sha256: sum);
      await dl.download(url, p.join(tmp.path, 'b'), sha256: sum);
      expect(asked, 1);
      expect(uncheckedCalls, 2);
      expect(await Downloader.sha256OfFile(p.join(tmp.path, 'b')), sum);
    });

    test('declined: fails, nothing written', () async {
      Downloader.certificatePrompt = (_, _) async => false;
      await expectLater(dl.download(url, p.join(tmp.path, 'a'), sha256: sum), throwsA(isA<CertificateException>()));
      expect(uncheckedCalls, 0);
      expect(await File(p.join(tmp.path, 'a')).exists(), isFalse);
    });

    test('a file without a pinned hash is never retried unchecked', () async {
      var asked = 0;
      Downloader.certificatePrompt = (_, _) async {
        asked++;
        return true;
      };
      await expectLater(dl.download(url, p.join(tmp.path, 'a')), throwsA(isA<CertificateException>()));
      expect(asked, 0);
      expect(uncheckedCalls, 0);
    });

    test('the hash still decides: a different file is rejected', () async {
      Downloader.certificatePrompt = (_, _) async => true;
      await expectLater(dl.download(url, p.join(tmp.path, 'a'), sha256: 'f' * 64),
          throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('sha256 mismatch'))));
      expect(await File(p.join(tmp.path, 'a')).exists(), isFalse);
    });

    test('downloads failing together share one dialog', () async {
      var asked = 0;
      final answer = Completer<bool>();
      Downloader.certificatePrompt = (_, _) {
        asked++;
        return answer.future;
      };
      final a = dl.download(url, p.join(tmp.path, 'a'), sha256: sum);
      final b = dl.download(url, p.join(tmp.path, 'b'), sha256: sum);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      answer.complete(true);
      await Future.wait([a, b]);
      expect(asked, 1);
    });
  });
}
