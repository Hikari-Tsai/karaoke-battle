import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/replay_archive.dart';
import 'package:karaoke_battle/state/replay_file.dart';

Uint8List _zip(Map<String, List<int>> files) {
  final a = Archive();
  files.forEach((name, data) => a.addFile(ArchiveFile.bytes(name, data)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Matcher _code(String c) => throwsA(isA<ReplayFormatException>().having((e) => e.code, 'code', c));

void main() {
  final json = utf8.encode('{"format":"karaoke-battle-replay"}');

  test('plain JSON passes through, with or without a BOM', () {
    expect(replayTextsFromBytes(Uint8List.fromList(json)), ['{"format":"karaoke-battle-replay"}']);
    expect(replayTextsFromBytes(Uint8List.fromList([0xef, 0xbb, 0xbf, ...json])).single, startsWith('{'));
  });

  test('gzip is inflated', () {
    expect(replayTextsFromBytes(Uint8List.fromList(gzip.encode(json))).single, '{"format":"karaoke-battle-replay"}');
  });

  test('zip yields every .json entry and skips Finder metadata', () {
    final z = _zip({
      'a.json': json,
      'folder/b.JSON': json,
      '__MACOSX/._a.json': [0, 1, 2],
      '.hidden.json': json,
      'notes.txt': utf8.encode('hi'),
    });
    expect(replayTextsFromBytes(z).length, 2);
  });

  test('a zip without replays is reported', () {
    expect(() => replayTextsFromBytes(_zip({'readme.txt': utf8.encode('x')})), _code('emptyArchive'));
  });

  test('binary that is not UTF-8 is not JSON', () {
    expect(() => replayTextsFromBytes(Uint8List.fromList([0xff, 0xfe, 0x00, 0x80])), _code('notJson'));
  });

  test('gzip bombs stop at the size cap', () {
    final bomb = gzip.encode(Uint8List(ReplayFile.maxTextBytes + 1024));
    expect(() => replayTextsFromBytes(Uint8List.fromList(bomb)), _code('tooLarge'));
  });

  test('a zip entry that lies about its size is rejected', () {
    final z = _zip({'big.json': Uint8List(ReplayFile.maxTextBytes + 1024)});
    // Patch the declared uncompressed size (local header and central directory) to 100 bytes.
    final b = ByteData.sublistView(z);
    for (var i = 0; i + 4 <= z.length; i++) {
      final sig = b.getUint32(i, Endian.little);
      if (sig == 0x04034b50) b.setUint32(i + 22, 100, Endian.little);
      if (sig == 0x02014b50) b.setUint32(i + 24, 100, Endian.little);
    }
    // archive stops inflating at the declared size; either way it is refused.
    expect(() => replayTextsFromBytes(z), throwsA(isA<ReplayFormatException>()));
  });

  test('audio files come along and are matched in the same folder', () {
    final z = _zip({
      'r1/a.json': json,
      'r1/a vocal.m4a': [1, 2, 3],
      'r2/b.json': json,
      'r2/a vocal.m4a': [4, 5],
      'evil.exe': [9],
    });
    final b = unpackReplays(z);
    expect(b.replays.map((e) => e.folder), ['r1/', 'r2/']);
    expect(b.voiceFor(b.replays[0], 'a vocal.m4a'), [1, 2, 3]);
    expect(b.voiceFor(b.replays[1], 'a vocal.m4a'), [4, 5]);
    expect(b.audio.keys, isNot(contains('evil.exe')));
  });
}
