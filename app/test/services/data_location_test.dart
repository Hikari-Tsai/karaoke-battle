import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('data_location'));
  tearDown(() async => tmp.delete(recursive: true));

  test('pointer file round trip; pointing back at the default removes it', () async {
    final def = p.join(tmp.path, 'default');
    expect(await DataLocation.read(def), isNull);
    await DataLocation.write(def, p.join(tmp.path, 'elsewhere'));
    expect(await DataLocation.read(def), p.join(tmp.path, 'elsewhere'));
    await DataLocation.write(def, def);
    expect(await DataLocation.read(def), isNull);
  });

  test('target: empty or existing data folder is used as is, else a subfolder', () async {
    final empty = await Directory(p.join(tmp.path, 'empty')).create();
    expect(await DataLocation.resolveTarget(empty.path), empty.path);
    final data = await Directory(p.join(tmp.path, 'data')).create();
    await Directory(p.join(data.path, 'songs')).create();
    expect(await DataLocation.resolveTarget(data.path), data.path);
    final busy = await Directory(p.join(tmp.path, 'Documents')).create();
    await File(p.join(busy.path, 'notes.txt')).writeAsString('x');
    expect(await DataLocation.resolveTarget(busy.path), p.join(busy.path, 'KaraokeBattle'));
  });

  test('refuses the current folder, folders inside it and folders containing it', () {
    final cur = p.join(tmp.path, 'a', 'KaraokeBattle');
    expect(DataLocation.problem(cur, cur), 'same');
    expect(DataLocation.problem(cur, p.join(cur, 'x')), 'inside');
    expect(DataLocation.problem(cur, p.join(tmp.path, 'a')), 'contains');
    expect(DataLocation.problem(cur, p.join(tmp.path, 'b')), isNull);
  });

  test('move keeps every file and removes the source', () async {
    final from = p.join(tmp.path, 'from');
    await File(p.join(from, 'songs', 's1', 'meta.json')).create(recursive: true);
    final model = await File(p.join(from, 'models', 'm', 'model.onnx')).create(recursive: true);
    await model.writeAsBytes(List.filled(1000, 7), flush: true);
    final to = p.join(tmp.path, 'drive', 'KaraokeBattle');
    await Directory(to).create(recursive: true); // empty target is fine
    double? last;
    await DataLocation.move(from, to, onProgress: (v) => last = v);
    expect(await File(p.join(to, 'songs', 's1', 'meta.json')).exists(), isTrue);
    expect(await File(p.join(to, 'models', 'm', 'model.onnx')).length(), 1000);
    expect(await Directory(from).exists(), isFalse);
    expect(last, 1);
  });

  test('move refuses a non-empty target', () async {
    final from = await Directory(p.join(tmp.path, 'from')).create();
    final to = p.join(tmp.path, 'to');
    await File(p.join(to, 'keep.txt')).create(recursive: true);
    expect(() => DataLocation.move(from.path, to), throwsStateError);
    expect(await Directory(from.path).exists(), isTrue);
  });
}
