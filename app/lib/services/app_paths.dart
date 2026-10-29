// Application support directory layout.
//
//   <support>/models/<model-id>/...      downloaded ONNX models
//   <support>/sidecars/{yt-dlp,ffmpeg,deno}
//   <support>/cuda_pack/                  Windows only
//   <support>/songs/<song-id>/...         see docs/ARCHITECTURE.md
//   <support>/cache/                      temporary downloads
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the data folder location came from (highest priority first).
enum DataRootSource { setting, environment, platformDefault }

/// Priority: App setting > KE_APP_SUPPORT > platform default.
({String root, DataRootSource source}) resolveDataRoot({String? setting, String? env, required String platformDefault}) {
  if (setting != null && setting.isNotEmpty) return (root: setting, source: DataRootSource.setting);
  if (env != null && env.isNotEmpty) return (root: env, source: DataRootSource.environment);
  return (root: platformDefault, source: DataRootSource.platformDefault);
}

class AppPaths {
  AppPaths._(this.root, {this.defaultRoot = '', this.envRoot, this.source = DataRootSource.platformDefault});
  final String root;

  /// The platform default location; it also holds location.json (the
  /// App setting), so the setting can be found before anything else.
  final String defaultRoot;

  /// KE_APP_SUPPORT, when set.
  final String? envRoot;

  final DataRootSource source;

  /// The location used when the App setting is cleared: KE_APP_SUPPORT if
  /// set, else the platform default.
  String get fallbackRoot => envRoot ?? defaultRoot;

  bool get isDefault => source != DataRootSource.setting;

  static AppPaths? _instance;

  static Future<String> platformDefaultRoot() async => p.join((await getApplicationSupportDirectory()).path, 'KaraokeBattle');

  static Future<AppPaths> init() async {
    if (_instance != null) return _instance!;
    final defaultRoot = await platformDefaultRoot();
    final env = Platform.environment['KE_APP_SUPPORT'];
    final envRoot = env != null && env.isNotEmpty ? env : null;
    final resolved = resolveDataRoot(setting: await DataLocation.read(defaultRoot), env: envRoot, platformDefault: defaultRoot);
    final source = resolved.source;
    final dir = Directory(resolved.root);
    await dir.create(recursive: true);
    final paths = AppPaths._(dir.path, defaultRoot: defaultRoot, envRoot: envRoot, source: source);
    for (final d in [paths.models, paths.sidecars, paths.songs, paths.cache, paths.cudaPack, paths.logs]) {
      await Directory(d).create(recursive: true);
    }
    _instance = paths;
    return paths;
  }

  static AppPaths get instance {
    final i = _instance;
    if (i == null) throw StateError('AppPaths.init() not called');
    return i;
  }

  String get models => p.join(root, 'models');
  String get sidecars => p.join(root, 'sidecars');
  String get songs => p.join(root, 'songs');
  String get cache => p.join(root, 'cache');
  String get cudaPack => p.join(root, 'cuda_pack');
  String get logs => p.join(root, 'logs');

  String modelDir(String modelId) => p.join(models, modelId);
  String songDir(String songId) => p.join(songs, songId);
}

/// The user's choice of data folder, stored as <default>/location.json so it
/// can be read before anything else is loaded.
class DataLocation {
  DataLocation._();

  static String _file(String defaultRoot) => p.join(defaultRoot, 'location.json');

  static Future<String?> read(String defaultRoot) async {
    try {
      final f = File(_file(defaultRoot));
      if (!await f.exists()) return null;
      final root = (jsonDecode(await f.readAsString()) as Map<String, dynamic>)['root'] as String?;
      return root == null || root.isEmpty ? null : root;
    } catch (_) {
      return null;
    }
  }

  /// Points the app at [root] from the next start (the App setting, which
  /// takes priority over KE_APP_SUPPORT).
  static Future<void> write(String defaultRoot, String root) async {
    await Directory(defaultRoot).create(recursive: true);
    await File(_file(defaultRoot)).writeAsString(jsonEncode({'root': root}));
  }

  /// Clears the App setting: the next start uses KE_APP_SUPPORT or the
  /// platform default again.
  static Future<void> clear(String defaultRoot) async {
    final f = File(_file(defaultRoot));
    if (await f.exists()) await f.delete();
  }

  /// Where data goes for a folder the user picked: the folder itself when it
  /// is empty or already a Karaoke Battle data folder, else a KaraokeBattle
  /// subfolder inside it.
  static Future<String> resolveTarget(String picked) async {
    final d = Directory(picked);
    if (p.basename(picked) == 'KaraokeBattle') return picked;
    if (!await d.exists()) return picked;
    final entries = await d.list().map((e) => p.basename(e.path)).where((n) => !n.startsWith('.')).toList();
    if (entries.isEmpty || entries.contains('songs') || entries.contains('models')) return picked;
    return p.join(picked, 'KaraokeBattle');
  }

  /// Why [target] cannot be used for data now at [current], or null.
  static String? problem(String current, String target) {
    if (p.equals(current, target)) return 'same';
    if (p.isWithin(current, target)) return 'inside';
    if (p.isWithin(target, current)) return 'contains';
    return null;
  }

  /// Moves the whole data folder [from] -> [to] ([to] must not exist or be
  /// empty). Renames when possible (same volume, instant); otherwise copies
  /// every file, then deletes the source. [onProgress] gets 0..1 for copies.
  static Future<void> move(String from, String to, {void Function(double)? onProgress}) async {
    final target = Directory(to);
    if (await target.exists()) {
      final hasEntries = await target.list().where((e) => !p.basename(e.path).startsWith('.')).isEmpty == false;
      if (hasEntries) throw StateError('target folder is not empty');
      await target.delete(recursive: true);
    }
    await target.parent.create(recursive: true);
    try {
      await Directory(from).rename(to);
      onProgress?.call(1);
      return;
    } on FileSystemException {
      // Different volume: copy, then remove the source.
    }
    final files = await Directory(from).list(recursive: true, followLinks: false).where((e) => e is File).cast<File>().toList();
    var total = 0;
    for (final f in files) {
      total += await f.length();
    }
    var done = 0;
    for (final f in files) {
      final rel = p.relative(f.path, from: from);
      final dest = File(p.join(to, rel));
      await dest.parent.create(recursive: true);
      await f.copy(dest.path);
      done += await f.length();
      onProgress?.call(total == 0 ? 1 : done / total);
    }
    await Directory(from).delete(recursive: true);
  }
}
