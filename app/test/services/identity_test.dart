import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/identity.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('identity'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<IdentityService> start(String machine, String os, String day) async {
    final s = IdentityService(dataRoot: tmp.path);
    await s.start(machineId: () async => machine, os: os, now: DateTime.parse(day));
    return s;
  }

  test('the same machine is the same device; its OS version is updated', () async {
    final a = await start('MACHINE-1', 'macOS 27.1', '2026-11-01T10:00:00');
    final b = await start('MACHINE-1', 'macOS 27.2.1', '2026-11-21T10:00:00');
    expect(b.identity!.userId, a.identity!.userId);
    expect(b.identity!.devices, hasLength(1));
    expect(b.current!.os, 'macOS 27.2.1');
    expect(b.current!.firstSeen, DateTime.parse('2026-11-01T10:00:00'));
    expect(b.current!.lastSeen, DateTime.parse('2026-11-21T10:00:00'));
  });

  test('another machine with the same data folder adds a device under the same ID', () async {
    final a = await start('MACHINE-1', 'macOS 27.2.1', '2026-11-01T10:00:00');
    final b = await start('WIN-GUID-2', 'Windows 11 (build 22631)', '2026-11-21T10:00:00');
    expect(b.identity!.userId, a.identity!.userId, reason: 'the ID moves with the data');
    expect(b.identity!.devices.map((d) => d.os), ['macOS 27.2.1', 'Windows 11 (build 22631)']);
    final saved = jsonDecode(File(p.join(tmp.path, 'identity.json')).readAsStringSync()) as Map;
    expect(saved['devices'], hasLength(2));
  });

  test('only the hash is kept, never the machine ID; spacing and case do not matter', () async {
    await start('ABCD-1234', 'macOS 27.2.1', '2026-11-21T10:00:00');
    final text = File(p.join(tmp.path, 'identity.json')).readAsStringSync();
    expect(text, isNot(contains('ABCD-1234')));
    expect(text.toLowerCase(), isNot(contains('abcd-1234')));
    expect(deviceHash('ABCD-1234'), deviceHash(' abcd-1234\n'));
    expect(deviceHash('ABCD-1234'), hasLength(64));
    expect(deviceHash('ABCD-1234'), isNot(deviceHash('ABCD-1235')));
  });

  test('no machine ID: the identity is still there, without a device', () async {
    final s = await start('', 'macOS 27.2.1', '2026-11-21T10:00:00');
    expect(s.identity!.userId, isNotEmpty);
    expect(s.current, isNull);
    expect(s.identity!.devices, isEmpty);
  });

  test('an unreadable identity.json is kept aside, not overwritten', () async {
    File(p.join(tmp.path, 'identity.json')).writeAsStringSync('{broken');
    final s = await start('MACHINE-1', 'macOS 27.2.1', '2026-11-21T10:00:00');
    expect(s.identity!.devices, hasLength(1));
    expect(File(p.join(tmp.path, 'identity.json.broken')).readAsStringSync(), '{broken');
  });

  test('machine IDs from ioreg and reg, and the OS shown', () {
    expect(parseIoregUuid('    "IOPlatformUUID" = "12345678-ABCD-EF01-2345-6789ABCDEF01"\n'), '12345678-ABCD-EF01-2345-6789ABCDEF01');
    expect(parseRegMachineGuid('\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    9f1c2d3e-aaaa-bbbb-cccc-0123456789ab\r\n'), '9f1c2d3e-aaaa-bbbb-cccc-0123456789ab');
    expect(osLabel('macos', 'Version 27.2.1 (Build 26B131)'), 'macOS 27.2.1');
    expect(osLabel('windows', '"Windows 10 Pro" 10.0 (Build 22631)'), 'Windows 11 (build 22631)');
    expect(osLabel('windows', '"Windows 10 Pro" 10.0 (Build 19045)'), 'Windows 10 (build 19045)');
    expect(osLabel('linux', '6.8.0-45-generic #45-Ubuntu SMP'), 'Linux 6.8.0-45-generic');
  });
}
