// Streaming HTTP downloader with progress, resume-free but atomic, sha256 verification.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;
  final int total; // -1 if unknown
  double get fraction => total > 0 ? received / total : 0;
}

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => 'DownloadException: $message';
}

/// Asks the user whether to go on although the server's TLS certificate
/// could not be verified. [url] is what was being downloaded, [error] the
/// TLS error. True continues.
typedef CertificatePrompt = Future<bool> Function(Uri url, String error);

/// The TLS certificate could not be verified and the download was not
/// continued (nobody to ask, or the user said no).
class CertificateException extends DownloadException {
  CertificateException(super.message);
}

/// Whether [e] is a TLS certificate verification failure (an antivirus or a
/// company proxy inspecting HTTPS, or missing root certificates).
bool isCertificateError(Object e) {
  final s = '$e';
  return e is HandshakeException || s.contains('CERTIFICATE_VERIFY_FAILED') || s.contains('HandshakeException');
}

class Downloader {
  Downloader({
    http.Client? client,
    http.Client? uncheckedClient,
    this.idleTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _uncheckedOverride = uncheckedClient;
  final http.Client _client;
  final http.Client? _uncheckedOverride;
  http.Client? _unchecked;

  /// Set by the UI: asked once per app session before a download with a
  /// pinned sha256 is retried without verifying the server's certificate
  /// (issue #6). Those files are checked against their hash, so a server
  /// that is not who it claims cannot slip in a different file. Downloads
  /// without a hash, checksum lists and API calls are never retried this way.
  static CertificatePrompt? certificatePrompt;
  static bool _certificateAccepted = false;
  static Future<bool>? _asking;

  /// Forgets the user's answer (tests).
  static void resetCertificateDecision() {
    _certificateAccepted = false;
    _asking = null;
  }

  static Future<bool> _mayIgnoreCertificate(Uri url, Object error) async {
    if (_certificateAccepted) return true;
    final prompt = certificatePrompt;
    if (prompt == null) return false;
    // Several downloads fail at once (the CUDA pack, a model): one dialog.
    final ok = await (_asking ??= prompt(url, '$error').whenComplete(() => _asking = null));
    if (ok) _certificateAccepted = true;
    return ok;
  }

  http.Client get _uncheckedClient =>
      _uncheckedOverride ?? (_unchecked ??= IOClient(HttpClient()..badCertificateCallback = (cert, host, port) => true));

  /// No byte for this long fails the download (a stalled connection would
  /// otherwise leave its progress bar stuck for good).
  final Duration idleTimeout;

  /// Time allowed to connect and get the response headers.
  final Duration connectTimeout;

  /// Downloads [url] to [destPath] (atomically via a .part file). Verifies
  /// [sha256] when given. [cancel] completes to abort, at once, also while
  /// connecting or while no data arrives.
  ///
  /// When the server's certificate cannot be verified and [sha256] is given,
  /// [certificatePrompt] decides whether to retry without verifying it.
  Future<void> download(
    Uri url,
    String destPath, {
    String? sha256,
    void Function(DownloadProgress)? onProgress,
    Future<void>? cancel,
    Map<String, String>? headers,
  }) async {
    if (sha256 != null && _certificateAccepted) {
      return _download(_uncheckedClient, url, destPath, sha256: sha256, onProgress: onProgress, cancel: cancel, headers: headers);
    }
    try {
      return await _download(_client, url, destPath, sha256: sha256, onProgress: onProgress, cancel: cancel, headers: headers);
    } catch (e) {
      if (!isCertificateError(e)) rethrow;
      if (sha256 == null || !await _mayIgnoreCertificate(url, e)) {
        throw CertificateException('cannot verify the TLS certificate of ${url.host}: $e');
      }
      return _download(_uncheckedClient, url, destPath, sha256: sha256, onProgress: onProgress, cancel: cancel, headers: headers);
    }
  }

  Future<void> _download(
    http.Client client,
    Uri url,
    String destPath, {
    String? sha256,
    void Function(DownloadProgress)? onProgress,
    Future<void>? cancel,
    Map<String, String>? headers,
  }) async {
    final dest = File(destPath);
    if (await dest.exists() && sha256 != null) {
      if (await sha256OfFile(destPath) == sha256.toLowerCase()) return;
    }
    await dest.parent.create(recursive: true);
    final part = File('$destPath.part');
    final req = http.Request('GET', url);
    if (headers != null) req.headers.addAll(headers);
    req.headers['User-Agent'] = _userAgent;
    final cancelled = Completer<void>();
    cancel?.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    final resp = await Future.any([
      client.send(req).timeout(connectTimeout, onTimeout: () => throw DownloadException('no response from $url after ${connectTimeout.inSeconds} s')),
      cancelled.future.then<http.StreamedResponse>((_) => throw DownloadException('cancelled')),
    ]);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      unawaited(resp.stream.listen(null, onError: (_) {}).cancel());
      throw DownloadException('HTTP ${resp.statusCode} for $url');
    }
    final total = resp.contentLength ?? -1;
    var received = 0;
    final sink = part.openWrite();
    final digest = AccumulatorSink<Digest>();
    final hasher = cryptoSha256.startChunkedConversion(digest);
    try {
      final finished = Completer<void>();
      final sub = resp.stream
          .timeout(idleTimeout, onTimeout: (s) => s.addError(DownloadException('no data from $url for ${idleTimeout.inSeconds} s')))
          .listen(
        (chunk) {
          sink.add(chunk);
          hasher.add(chunk);
          received += chunk.length;
          onProgress?.call(DownloadProgress(received, total));
        },
        onError: (Object e) {
          if (!finished.isCompleted) finished.completeError(e);
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );
      unawaited(cancelled.future.then((_) {
        if (finished.isCompleted) return;
        unawaited(sub.cancel());
        finished.completeError(DownloadException('cancelled'));
      }));
      await finished.future;
      await sink.flush();
      await sink.close();
      hasher.close();
      final got = digest.events.single.toString();
      if (sha256 != null && got != sha256.toLowerCase()) {
        await part.delete();
        throw DownloadException('sha256 mismatch for ${p.basename(destPath)}: expected $sha256, got $got');
      }
      // rename replaces an existing file on macOS and Windows alike. Deleting
      // it first could remove a copy another download of the same file had
      // just put there, which is how a sidecar install once vanished.
      try {
        await part.rename(destPath);
      } on FileSystemException {
        // Another download of the same file got there first (it renamed the
        // shared .part): accept its result when it is the file we wanted.
        if (sha256 != null && await dest.exists() && await sha256OfFile(destPath) == sha256.toLowerCase()) return;
        rethrow;
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  static const _userAgent = 'KaraokeBattle/0.1 (+https://github.com)';

  /// Follows redirects and returns the final URL (for "latest" links whose
  /// checksum sits next to the file they point to). Uses GET and drops the
  /// body: some servers answer HEAD with a sporadic 404.
  Future<Uri> resolve(Uri url, {int maxHops = 5, Duration timeout = const Duration(seconds: 20)}) async {
    var u = url;
    for (var i = 0; i <= maxHops; i++) {
      final req = http.Request('GET', u)
        ..followRedirects = false
        ..headers['User-Agent'] = _userAgent;
      final resp = await _client.send(req).timeout(timeout);
      // Never read the file itself, only the status line and headers.
      unawaited(resp.stream.listen(null, onError: (_) {}).cancel());
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final loc = resp.headers['location'];
        if (loc == null || loc.isEmpty) throw DownloadException('redirect without a location for $u');
        u = u.resolve(loc);
        continue;
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) throw DownloadException('HTTP ${resp.statusCode} for $u');
      return u;
    }
    throw DownloadException('too many redirects for $url');
  }

  /// Downloads a small text file (a checksum list, a manifest), refusing
  /// anything over [maxBytes].
  Future<String> fetchText(Uri url, {int maxBytes = 1 << 20, Duration timeout = const Duration(seconds: 20)}) async {
    final req = http.Request('GET', url)..headers['User-Agent'] = _userAgent;
    final resp = await _client.send(req).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.stream.drain<void>();
      throw DownloadException('HTTP ${resp.statusCode} for $url');
    }
    final bytes = <int>[];
    await for (final chunk in resp.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) throw DownloadException('$url is larger than $maxBytes bytes');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Future<String> sha256OfFile(String path) async {
    final digest = await cryptoSha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  void close() => _client.close();
}

// Aliases to keep the import surface small.
const cryptoSha256 = sha256;

/// Minimal sink collecting digests (crypto's ChunkedConversion needs a `Sink<Digest>`).
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T data) => events.add(data);
  @override
  void close() {}
}
