// Unpacks replay files: a .zip (the app's export, or several replays zipped
// together) holding replay .json files and their vocal .mp3 files, or a
// plain .json. Everything is decoded in memory with size caps (the input is
// untrusted); no entry is written to disk, so paths inside an archive are
// only used as lookup keys.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'replay_file.dart';

const maxArchiveEntries = 100;
const maxArchiveTotalBytes = 4 * ReplayFile.maxTextBytes;

/// One replay JSON found in a file, with the folder it sat in inside the
/// archive ('' at the top level or for a plain file).
class ReplayEntry {
  const ReplayEntry(this.text, [this.folder = '']);
  final String text;
  final String folder;
}

/// Replays plus the audio files that came with them (zip path -> bytes).
class ReplayBundle {
  const ReplayBundle(this.replays, [this.audio = const {}]);
  final List<ReplayEntry> replays;
  final Map<String, Uint8List> audio;

  /// The audio file [name] next to [entry] in the archive, if present.
  Uint8List? voiceFor(ReplayEntry entry, String name) => audio['${entry.folder}$name'];
}

/// The replays inside [bytes]: the file itself when it is plain JSON, or
/// every `.json` entry of a zip (with the zip's .mp3 files). Throws
/// [ReplayFormatException] (`notJson`, `tooLarge`, `emptyArchive`).
ReplayBundle unpackReplays(Uint8List bytes) {
  if (_isZip(bytes)) return _fromZip(bytes);
  return ReplayBundle([ReplayEntry(_text(bytes))]);
}

/// Just the replay texts (see [unpackReplays]).
List<String> replayTextsFromBytes(Uint8List bytes) => [for (final e in unpackReplays(bytes).replays) e.text];

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

ReplayBundle _fromZip(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw ReplayFormatException('notJson', 'zip');
  }
  final replays = <ReplayEntry>[];
  final audio = <String, Uint8List>{};
  var total = 0, seen = 0;
  for (final f in archive.files) {
    if (!f.isFile || f.isSymbolicLink) continue;
    final name = f.name.replaceAll('\\', '/');
    final base = name.split('/').last;
    if (name.startsWith('__MACOSX/') || base.startsWith('.')) continue;
    final isJson = base.toLowerCase().endsWith('.json');
    final isAudio = !isJson && ReplayFile.isVoiceFileName(base);
    if (!isJson && !isAudio) continue;
    if (++seen > maxArchiveEntries) throw ReplayFormatException('tooLarge', 'entries');
    final cap = isJson ? ReplayFile.maxTextBytes : ReplayFile.maxVoiceBytes;
    if (f.size > cap) throw ReplayFormatException('tooLarge', base);
    // The declared size can lie. archive stops inflating at the declared
    // size, and the capped output guards against anything it lets through.
    final out = _CappedOutput(cap);
    try {
      f.decompress(out);
    } on ReplayFormatException {
      rethrow;
    } catch (_) {
      throw ReplayFormatException('invalid', 'zip entry');
    }
    total += out.length;
    if (total > maxArchiveTotalBytes) throw ReplayFormatException('tooLarge', 'zip');
    final folder = name.substring(0, name.length - base.length);
    if (isJson) {
      replays.add(ReplayEntry(_text(out.getBytes()), folder));
    } else {
      audio[name] = out.getBytes();
    }
  }
  if (replays.isEmpty) throw ReplayFormatException('emptyArchive');
  return ReplayBundle(replays, audio);
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
