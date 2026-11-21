// Who the player is, across computers: a UUID made on first start, kept in
// identity.json in the data folder (so it moves with the data), and under it
// every device it has been used on. A device is told by a hash of the
// operating system's machine ID (macOS IOPlatformUUID, Windows MachineGuid,
// Linux /etc/machine-id) with the app's own prefix, never the raw ID; its OS
// version is read again at every start. Nothing here leaves the computer.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class IdentityDevice {
  IdentityDevice({required this.id, required this.os, required this.firstSeen, required this.lastSeen});

  /// The machine ID's hash (hex).
  final String id;

  /// The OS and its version at the last start, e.g. "macOS 27.2.1".
  String os;
  final DateTime firstSeen;
  DateTime lastSeen;

  Map<String, dynamic> toJson() => {'id': id, 'os': os, 'first_seen': firstSeen.toIso8601String(), 'last_seen': lastSeen.toIso8601String()};

  static IdentityDevice fromJson(Map<String, dynamic> j) {
    final first = DateTime.tryParse('${j['first_seen']}') ?? DateTime.now();
    return IdentityDevice(id: '${j['id']}', os: '${j['os'] ?? ''}', firstSeen: first, lastSeen: DateTime.tryParse('${j['last_seen']}') ?? first);
  }
}

class Identity {
  Identity({required this.userId, required this.createdAt, List<IdentityDevice>? devices}) : devices = devices ?? [];
  final String userId;
  final DateTime createdAt;
  final List<IdentityDevice> devices;

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'created_at': createdAt.toIso8601String(),
        'devices': [for (final d in devices) d.toJson()],
      };

  static Identity fromJson(Map<String, dynamic> j) => Identity(
        userId: '${j['user_id']}',
        createdAt: DateTime.tryParse('${j['created_at']}') ?? DateTime.now(),
        devices: [for (final d in (j['devices'] as List? ?? const [])) if (d is Map) IdentityDevice.fromJson(d.cast<String, dynamic>())],
      );

  static Identity create(DateTime now) => Identity(userId: const Uuid().v4(), createdAt: now);

  /// This start on [deviceId] with [os]: the same hash is the same device
  /// (its OS version and last start updated), a new hash adds one.
  IdentityDevice seen(String deviceId, String os, DateTime now) {
    for (final d in devices) {
      if (d.id == deviceId) {
        d
          ..os = os
          ..lastSeen = now;
        return d;
      }
    }
    final d = IdentityDevice(id: deviceId, os: os, firstSeen: now, lastSeen: now);
    devices.add(d);
    return d;
  }
}

/// The hash a device is known by: SHA-256 of the machine ID with the app's
/// prefix, so the raw ID is never stored and is not the same value other
/// programs would use.
String deviceHash(String machineId) => sha256.convert(utf8.encode('karaoke-battle/device/${machineId.trim().toLowerCase()}')).toString();

/// The machine ID in `ioreg -rd1 -c IOPlatformExpertDevice` output (macOS).
String? parseIoregUuid(String out) => RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"').firstMatch(out)?.group(1);

/// The machine ID in `reg query HKLM\SOFTWARE\Microsoft\Cryptography /v
/// MachineGuid` output (Windows).
String? parseRegMachineGuid(String out) => RegExp(r'MachineGuid\s+REG_SZ\s+(\S+)', caseSensitive: false).firstMatch(out)?.group(1);

/// The OS and its version as shown, from Platform.operatingSystem and
/// Platform.operatingSystemVersion: "macOS 27.2.1", "Windows 11 (build
/// 22631)", "Linux 6.8.0".
String osLabel(String os, String version) {
  switch (os) {
    case 'macos':
      final v = RegExp(r'Version\s+([\d.]+)').firstMatch(version)?.group(1);
      return 'macOS ${v ?? version}';
    case 'windows':
      final build = int.tryParse(RegExp(r'Build\s+(\d+)').firstMatch(version)?.group(1) ?? '');
      if (build == null) return 'Windows $version';
      return '${build >= 22000 ? 'Windows 11' : 'Windows 10'} (build $build)';
    case 'linux':
      return 'Linux ${version.split(' ').first}';
    default:
      return '$os $version';
  }
}

/// Reads the operating system's machine ID; null when it cannot.
Future<String?> readMachineId() async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('/usr/sbin/ioreg', ['-rd1', '-c', 'IOPlatformExpertDevice']);
      return parseIoregUuid('${r.stdout}');
    }
    if (Platform.isWindows) {
      final r = await Process.run('reg', ['query', r'HKLM\SOFTWARE\Microsoft\Cryptography', '/v', 'MachineGuid']);
      return parseRegMachineGuid('${r.stdout}');
    }
    if (Platform.isLinux) {
      for (final f in ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
        final file = File(f);
        if (await file.exists()) return (await file.readAsString()).trim();
      }
    }
  } catch (_) {}
  return null;
}

/// Loads or makes identity.json and records this start on this device.
class IdentityService extends ChangeNotifier {
  IdentityService({required this.dataRoot});
  final String dataRoot;

  File get _file => File(p.join(dataRoot, 'identity.json'));

  Identity? identity;

  /// This computer's device (null until started, or when its machine ID
  /// could not be read).
  IdentityDevice? current;

  Future<void> start({Future<String?> Function() machineId = readMachineId, String? os, DateTime? now}) async {
    final t = now ?? DateTime.now();
    Identity id;
    try {
      id = await _file.exists() ? Identity.fromJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>) : Identity.create(t);
    } catch (_) {
      // An unreadable file is kept aside, not overwritten blindly.
      try {
        await _file.rename('${_file.path}.broken');
      } catch (_) {}
      id = Identity.create(t);
    }
    final mid = await machineId();
    if (mid != null && mid.isNotEmpty) {
      current = id.seen(deviceHash(mid), os ?? osLabel(Platform.operatingSystem, Platform.operatingSystemVersion), t);
    }
    identity = id;
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(id.toJson()));
    } catch (_) {}
    notifyListeners();
  }
}
