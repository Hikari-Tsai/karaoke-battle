// Streaming HTTP downloader with progress, resume-free but atomic, sha256 verification.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
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

class Downloader {
  Downloader({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// Downloads [url] to [destPath] (atomically via a .part file). Verifies
  /// [sha256] when given. [cancel] completes to abort.
  Future<void> download(
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
    final resp = await _client.send(req);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw DownloadException('HTTP ${resp.statusCode} for $url');
    }
    final total = resp.contentLength ?? -1;
    var received = 0;
    final sink = part.openWrite();
    final digest = AccumulatorSink<Digest>();
    final hasher = cryptoSha256.startChunkedConversion(digest);
    var cancelled = false;
    cancel?.then((_) => cancelled = true);
    try {
      await for (final chunk in resp.stream) {
        if (cancelled) throw DownloadException('cancelled');
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }
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
