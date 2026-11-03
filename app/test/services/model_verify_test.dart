import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/model_registry.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  final data = utf8.encode('model bytes');
  final good = ModelFile('m.onnx', data.length, sha256.convert(data).toString());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ke_verify');
    await File(p.join(dir.path, 'm.onnx')).writeAsBytes(data);
  });
  tearDown(() => dir.delete(recursive: true));

  test('a good file passes, is remembered and not hashed again', () async {
    final hashed = <String>[];
    expect(await ModelStore.verifyDir(dir.path, [good], onFile: hashed.add), isTrue);
    expect(hashed, ['m.onnx']);
    expect(File(p.join(dir.path, '.verified.json')).existsSync(), isTrue);
    hashed.clear();
    expect(await ModelStore.verifyDir(dir.path, [good], onFile: hashed.add), isTrue);
    expect(hashed, isEmpty, reason: 'unchanged since it passed');
  });

  test('a missing file fails', () async {
    await File(p.join(dir.path, 'm.onnx')).delete();
    expect(await ModelStore.verifyDir(dir.path, [good]), isFalse);
  });

  test('a damaged file of the right size fails and is deleted', () async {
    expect(await ModelStore.verifyDir(dir.path, [good]), isTrue);
    final f = File(p.join(dir.path, 'm.onnx'));
    await f.writeAsBytes(utf8.encode('MODEL BYTES'));
    // A different modification time makes it be hashed again.
    await f.setLastModified(DateTime.now().add(const Duration(seconds: 5)));
    expect(await ModelStore.verifyDir(dir.path, [good]), isFalse);
    expect(f.existsSync(), isFalse, reason: 'deleted so it is downloaded again');
  });
}
