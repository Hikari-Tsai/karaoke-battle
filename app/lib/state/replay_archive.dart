// Unpacks replay files that arrive compressed: a .zip (e.g. made by
// "Compress" in Finder / Explorer or by a chat app) holding one or more
// replay .json files, or a gzip'd .json. Everything is decoded in memory
// with size caps (the input is untrusted); no entry is written to disk, so
// paths inside an archive are never used.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'replay_file.dart';

const maxArchiveEntries = 100;
const maxArchiveTotalBytes = 4 * ReplayFile.maxTextBytes;

/// The replay texts inside [bytes]: the file itself when it is plain JSON,
/// the decompressed text of a gzip file, or every `.json` entry of a zip.
/// Throws [ReplayFormatException] (`notJson`, `tooLarge`, `emptyArchive`).
List<String> replayTextsFromBytes(Uint8List bytes) {
  if (_isZip(bytes)) return _fromZip(bytes);
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) return [_text(_gunzip(bytes))];
  return [_text(bytes)];
}

bool _isZip(Uint8List b) =>
    b.length >= 4 && b[0] == 0x50 && b[1] == 0x4b && ((b[2] == 3 && b[3] == 4) || (b[2] == 5 && b[3] == 6));

String _text(List<int> bytes) {
  if (bytes.length > ReplayFile.maxTextBytes) throw ReplayFormatException('tooLarge');
  try {
    // Tolerate a UTF-8 byte order mark from editors.
    final start = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
    return utf8.decode(bytes.sublist(start));
  } on FormatException {
    throw ReplayFormatException('notJson');
  }
}

List<int> _gunzip(Uint8List bytes) {
  final out = _CappedSink(ReplayFile.maxTextBytes);
  final conv = gzip.decoder.startChunkedConversion(out);
  try {
    const chunk = 64 * 1024;
    for (var i = 0; i < bytes.length; i += chunk) {
      conv.add(bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk));
    }
    conv.close();
  } on ReplayFormatException {
    rethrow;
  } catch (_) {
    throw ReplayFormatException('notJson', 'gzip');
  }
  return out.bytes;
}

List<String> _fromZip(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw ReplayFormatException('notJson', 'zip');
  }
  final texts = <String>[];
  var total = 0, seen = 0;
  for (final f in archive.files) {
    if (!f.isFile || f.isSymbolicLink) continue;
    final name = f.name.replaceAll('\\', '/');
    final base = name.split('/').last;
    if (name.startsWith('__MACOSX/') || base.startsWith('.') || !base.toLowerCase().endsWith('.json')) continue;
    if (++seen > maxArchiveEntries) throw ReplayFormatException('tooLarge', 'entries');
    if (f.size > ReplayFile.maxTextBytes) throw ReplayFormatException('tooLarge', base);
    // The declared size can lie. archive stops inflating at the declared
    // size, and the capped output guards against anything it lets through.
    final out = _CappedOutput(ReplayFile.maxTextBytes);
    try {
      f.decompress(out);
    } on ReplayFormatException {
      rethrow;
    } catch (_) {
      throw ReplayFormatException('invalid', 'zip entry');
    }
    total += out.length;
    if (total > maxArchiveTotalBytes) throw ReplayFormatException('tooLarge', 'zip');
    texts.add(_text(out.getBytes()));
  }
  if (texts.isEmpty) throw ReplayFormatException('emptyArchive');
  return texts;
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.cap);
  final int cap;
  final _b = BytesBuilder(copy: false);
  List<int> get bytes => _b.takeBytes();

  @override
  void add(List<int> data) {
    if (_b.length + data.length > cap) throw ReplayFormatException('tooLarge', 'gzip');
    _b.add(data);
  }

  @override
  void close() {}
}

/// An in-memory output that refuses to grow past [cap] bytes.
class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.cap);
  final int cap;

  void _room(int n) {
    if (length + n > cap) throw ReplayFormatException('tooLarge', 'zip entry');
  }

  @override
  void writeByte(int value) {
    _room(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _room(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _room(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _room(count);
    super.writeBackReference(distance, count);
  }
}
