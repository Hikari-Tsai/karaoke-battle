import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('data_location'));
  tearDown(() async => tmp.delete(recursive: true));

  test('setting file round trip; clear removes it', () async {
    final def = p.join(tmp.path, 'default');
    expect(await DataLocation.read(def), isNull);
    await DataLocation.write(def, p.join(tmp.path, 'elsewhere'));
    expect(await DataLocation.read(def), p.join(tmp.path, 'elsewhere'));
    // Choosing the platform default explicitly is still a setting (it must
    // win over KE_APP_SUPPORT).
    await DataLocation.write(def, def);
    expect(await DataLocation.read(def), def);
    await DataLocation.clear(def);
    expect(await DataLocation.read(def), isNull);
  });

  test('priority: App setting > KE_APP_SUPPORT > platform default', () {
    expect(resolveDataRoot(setting: '/s', env: '/e', platformDefault: '/d'), (root: '/s', source: DataRootSource.setting));
    expect(resolveDataRoot(env: '/e', platformDefault: '/d'), (root: '/e', source: DataRootSource.environment));
    expect(resolveDataRoot(env: '', platformDefault: '/d'), (root: '/d', source: DataRootSource.platformDefault));
    expect(resolveDataRoot(platformDefault: '/d'), (root: '/d', source: DataRootSource.platformDefault));
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

  group('files in use (Windows locks open files and loaded DLLs)', () {
    // A read-only folder stands in for a lock: nothing in it can be deleted,
    // and its parent being read-only also makes the rename fail.
    final skip = Platform.isWindows ? 'chmod stands in for a Windows file lock' : null;
    Future<void> chmod(String mode, String path) => Process.run('chmod', [mode, path]);

    test('the data ends up complete in the new folder, pointed at before deleting, rest cleaned at the next start', skip: skip, () async {
      final def = p.join(tmp.path, 'default');
      final parent = p.join(tmp.path, 'old');
      final from = p.join(parent, 'KaraokeBattle');
      await File(p.join(from, 'songs', 's1', 'meta.json')).create(recursive: true);
      await (await File(p.join(from, 'logs', 'app.log')).create(recursive: true)).writeAsString('log', flush: true);
      await File(p.join(from, 'cuda_pack', 'onnxruntime.dll')).create(recursive: true);
      await chmod('555', p.join(from, 'cuda_pack')); // "loaded DLL"
      await chmod('555', parent); // rename fails, the folder itself stays
      addTearDown(() async {
        await chmod('755', parent);
        if (await Directory(p.join(from, 'cuda_pack')).exists()) await chmod('755', p.join(from, 'cuda_pack'));
      });
      final to = p.join(tmp.path, 'drive', 'KaraokeBattle');
      var sourceStillThere = false;
      final clean = await DataLocation.move(from, to, defaultRoot: def, onCopied: () async {
        sourceStillThere = await File(p.join(from, 'songs', 's1', 'meta.json')).exists();
        await DataLocation.write(def, to);
      });
      expect(clean, isFalse);
      expect(sourceStillThere, isTrue, reason: 'the pointer is written before anything is deleted');
      expect(await DataLocation.read(def), to);
      for (final rel in ['songs/s1/meta.json', 'logs/app.log', 'cuda_pack/onnxruntime.dll']) {
        expect(await File(p.join(to, rel)).exists(), isTrue, reason: rel);
      }
      // Everything that could go is gone; the locked rest is remembered.
      expect(await Directory(p.join(from, 'songs')).exists(), isFalse);
      expect(await File(p.join(from, 'cuda_pack', 'onnxruntime.dll')).exists(), isTrue);
      expect(await DataLocation.pendingCleanup(def), [from]);

      // Next start: the locks are gone.
      await chmod('755', p.join(from, 'cuda_pack'));
      await chmod('755', parent);
      await DataLocation.runPendingCleanup(def, to);
      expect(await Directory(from).exists(), isFalse);
      expect(await DataLocation.pendingCleanup(def), isEmpty);
      expect(await DataLocation.read(def), to);
    });

    test('a leftover that is still locked stays on the list', skip: skip, () async {
      final def = p.join(tmp.path, 'default');
      final old = p.join(tmp.path, 'old');
      await File(p.join(old, 'cuda_pack', 'x.dll')).create(recursive: true);
      await chmod('555', p.join(old, 'cuda_pack'));
      addTearDown(() => chmod('755', p.join(old, 'cuda_pack')));
      await DataLocation.write(def, p.join(tmp.path, 'new'));
      await DataLocation.addCleanup(def, old);
      await DataLocation.runPendingCleanup(def, p.join(tmp.path, 'new'));
      expect(await DataLocation.pendingCleanup(def), [old]);
    });
  });

  test('cleanup never removes the current folder (or one around it) and keeps location.json', () async {
    final def = p.join(tmp.path, 'default');
    final cur = p.join(tmp.path, 'cur');
    await File(p.join(cur, 'songs', 'a')).create(recursive: true);
    await File(p.join(def, 'models', 'm.onnx')).create(recursive: true);
    await DataLocation.write(def, cur);
    await DataLocation.addCleanup(def, cur); // e.g. moved back here later
    await DataLocation.addCleanup(def, tmp.path); // contains it
    await DataLocation.addCleanup(def, def); // the old default folder
    await DataLocation.runPendingCleanup(def, cur);
    expect(await File(p.join(cur, 'songs', 'a')).exists(), isTrue);
    expect(await Directory(p.join(def, 'models')).exists(), isFalse);
    expect(await DataLocation.read(def), cur, reason: 'location.json survives cleaning the default folder');
    expect(await DataLocation.pendingCleanup(def), isEmpty);
  });

  test('choosing a folder again drops it from the cleanup list', () async {
    final def = p.join(tmp.path, 'default');
    final old = p.join(tmp.path, 'old');
    await DataLocation.addCleanup(def, old);
    await DataLocation.write(def, old);
    expect(await DataLocation.pendingCleanup(def), isEmpty);
    await DataLocation.addCleanup(def, p.join(tmp.path, 'x'));
    await DataLocation.clear(def);
    expect(await DataLocation.read(def), isNull);
    expect(await DataLocation.pendingCleanup(def), [p.join(tmp.path, 'x')]);
  });

  test('moving back into the default folder copies around its location.json', () async {
    final def = p.join(tmp.path, 'default');
    final custom = p.join(tmp.path, 'custom');
    await File(p.join(custom, 'songs', 's1', 'meta.json')).create(recursive: true);
    await DataLocation.write(def, custom); // def now holds just location.json
    final clean = await DataLocation.move(custom, def, defaultRoot: def, onCopied: () => DataLocation.clear(def));
    expect(clean, isTrue);
    expect(await File(p.join(def, 'songs', 's1', 'meta.json')).exists(), isTrue);
    expect(await DataLocation.read(def), isNull);
    expect(await Directory(custom).exists(), isFalse);
  });

  test('the Windows data folder stays where 0.7.x stored it, whatever the exe is named', () {
    expect(AppPaths.windowsDefaultRoot(r'C:\Users\me\AppData\Roaming'), r'C:\Users\me\AppData\Roaming\com.karaokebattle\karaoke_battle\KaraokeBattle');
  });
}
