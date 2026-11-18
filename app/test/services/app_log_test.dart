import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_log.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    await AppLog.reset();
    dir = await Directory.systemTemp.createTemp('applog');
  });

  tearDown(() async {
    await AppLog.reset();
    await dir.delete(recursive: true);
  });

  test('close releases app.log (to move the data folder) and init opens it again', () async {
    await AppLog.init(dir.path);
    AppLog.info('one');
    await AppLog.close();
    AppLog.info('while closed');
    expect(AppLog.recent.last, endsWith('while closed'));
    // Nothing holds the file: it can be moved away and recreated.
    await File(p.join(dir.path, 'app.log')).rename(p.join(dir.path, 'moved.log'));
    expect(await File(p.join(dir.path, 'moved.log')).readAsString(), contains('one'));
    await AppLog.init(dir.path);
    AppLog.info('two');
    await AppLog.close();
    final text = await File(p.join(dir.path, 'app.log')).readAsString();
    expect(text, contains('while closed'));
    expect(text, contains('two'));
    expect(text, isNot(contains(' I one')), reason: 'lines already written are not written again');
  });

  test('writes earlier and later lines to app.log', () async {
    AppLog.info('before init');
    await AppLog.init(dir.path, header: 'Karaoke Battle test');
    AppLog.error(StateError('boom'), StackTrace.current, 'score take');
    AppLog.engine('[W] slow device');
    final snap = await AppLog.writeSnapshot();
    final log = await File(p.join(dir.path, 'app.log')).readAsString();
    expect(log, contains('===== '));
    expect(log, contains('Karaoke Battle test'));
    expect(log, contains('I before init'));
    expect(log, contains('E [score take] Bad state: boom'));
    expect(log, contains('W engine: slow device'));
    expect(snap, isNotNull);
    expect(p.basename(snap!), startsWith('report-'));
    expect(await File(snap).readAsString(), contains('E [score take] Bad state: boom'));
  });

  test('keeps the previous big log as app.1.log', () async {
    await File(p.join(dir.path, 'app.log')).writeAsString('x' * (AppLog.rotateBytes + 1));
    await AppLog.init(dir.path);
    AppLog.info('fresh');
    await AppLog.writeSnapshot();
    expect(await File(p.join(dir.path, 'app.1.log')).exists(), isTrue);
    expect(await File(p.join(dir.path, 'app.log')).length(), lessThan(1000));
  });

  test('keeps only the recent lines in memory', () {
    for (var i = 0; i < AppLog.keepLines + 50; i++) {
      AppLog.info('line $i');
    }
    expect(AppLog.recent.length, AppLog.keepLines);
    expect(AppLog.recent.last, endsWith('line ${AppLog.keepLines + 49}'));
  });

  test('writes home folders as ~', () {
    expect(AppLog.redact('/Users/alice/x and /home/bob/y'), '~/x and ~/y');
    expect(AppLog.redact(r'C:\Users\Carol\AppData\x'), r'~\AppData\x');
  });
}
