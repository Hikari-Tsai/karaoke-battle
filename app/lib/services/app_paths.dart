// Application support directory layout.
//
//   <support>/models/<model-id>/...      downloaded ONNX models
//   <support>/sidecars/{yt-dlp,ffmpeg,deno}
//   <support>/cuda_pack/                  Windows only
//   <support>/songs/<song-id>/...         see docs/ARCHITECTURE.md
//   <support>/cache/                      temporary downloads
//   <support>/logs/app.log                app log (app.1.log: the previous one)
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

  /// Paths rooted at [root], for tests.
  factory AppPaths.forTest(String root) => AppPaths._(root, defaultRoot: root);
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

  static Future<String> platformDefaultRoot() async {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return windowsDefaultRoot(appData);
    }
    return p.join((await getApplicationSupportDirectory()).path, 'KaraokeBattle');
  }

  /// The Windows data folder, fixed. path_provider builds it from the exe's
  /// CompanyName and ProductName, which were "com.karaokebattle" and
  /// "karaoke_battle" when users' data was first stored there; those fields
  /// now carry display names, so the folder must not follow them.
  static String windowsDefaultRoot(String appData) => p.windows.join(appData, 'com.karaokebattle', 'karaoke_battle', 'KaraokeBattle');

  static Future<AppPaths> init() async {
    if (_instance != null) return _instance!;
    final defaultRoot = await platformDefaultRoot();
    final env = Platform.environment['KE_APP_SUPPORT'];
    final envRoot = env != null && env.isNotEmpty ? env : null;
    final resolved = resolveDataRoot(setting: await DataLocation.read(defaultRoot), env: envRoot, platformDefault: defaultRoot);
    final source = resolved.source;
    // Old data folders a move could not finish removing (before the log or
    // any model opens a file).
    try {
      await DataLocation.runPendingCleanup(defaultRoot, resolved.root);
    } catch (_) {}
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
/// can be read before anything else is loaded. The same file lists old data
/// folders whose files were still in use when the data was moved away; they
/// are removed at the next start ([runPendingCleanup]).
class DataLocation {
  DataLocation._();

  static const fileName = 'location.json';
  static String _file(String defaultRoot) => p.join(defaultRoot, fileName);

  static Future<Map<String, dynamic>> _load(String defaultRoot) async {
    try {
      final f = File(_file(defaultRoot));
      if (!await f.exists()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _save(String defaultRoot, Map<String, dynamic> j) async {
    final f = File(_file(defaultRoot));
    final cleanup = (j['cleanup'] as List?) ?? const [];
    if ((j['root'] as String?) == null && cleanup.isEmpty) {
      if (await f.exists()) await f.delete();
      return;
    }
    await Directory(defaultRoot).create(recursive: true);
    await f.writeAsString(jsonEncode(j));
  }

  static Future<String?> read(String defaultRoot) async {
    final root = (await _load(defaultRoot))['root'] as String?;
    return root == null || root.isEmpty ? null : root;
  }

  /// Old data folders still to be removed.
  static Future<List<String>> pendingCleanup(String defaultRoot) async =>
      [for (final e in ((await _load(defaultRoot))['cleanup'] as List? ?? const [])) '$e'];

  /// Points the app at [root] from the next start (the App setting, which
  /// takes priority over KE_APP_SUPPORT).
  static Future<void> write(String defaultRoot, String root) async {
    final j = await _load(defaultRoot);
    j['root'] = root;
    j['cleanup'] = _without(await pendingCleanup(defaultRoot), root);
    await _save(defaultRoot, j);
  }

  /// Clears the App setting: the next start uses KE_APP_SUPPORT or the
  /// platform default again.
  static Future<void> clear(String defaultRoot) async {
    final j = await _load(defaultRoot);
    j.remove('root');
    j['cleanup'] = _without(await pendingCleanup(defaultRoot), defaultRoot);
    await _save(defaultRoot, j);
  }

  /// Remembers [dir] for removal at the next start.
  static Future<void> addCleanup(String defaultRoot, String dir) async {
    final j = await _load(defaultRoot);
    final list = await pendingCleanup(defaultRoot);
    if (!list.any((e) => p.equals(e, dir))) list.add(dir);
    j['cleanup'] = list;
    await _save(defaultRoot, j);
  }

  /// [list] without folders that are, contain or sit inside [root].
  static List<String> _without(List<String> list, String root) =>
      [for (final e in list) if (!p.equals(e, root) && !p.isWithin(e, root) && !p.isWithin(root, e)) e];

  /// Removes the old data folders left by a move (files that were in use,
  /// such as the log or loaded CUDA DLLs on Windows). Run at start, before
  /// anything opens files; never touches [currentRoot] or location.json.
  static Future<void> runPendingCleanup(String defaultRoot, String currentRoot) async {
    final list = await pendingCleanup(defaultRoot);
    if (list.isEmpty) return;
    final remaining = <String>[];
    for (final dir in _without(list, currentRoot)) {
      try {
        if (!await Directory(dir).exists()) continue;
        if (await deleteBestEffort(dir, keepTopLevel: {fileName}) > 0) remaining.add(dir);
      } catch (_) {
        remaining.add(dir);
      }
    }
    final j = await _load(defaultRoot);
    j['cleanup'] = remaining;
    await _save(defaultRoot, j);
  }

  /// Deletes [dir] and everything in it as far as possible, skipping files
  /// that cannot be removed (in use on Windows) instead of stopping at the
  /// first one. Entries named in [keepTopLevel] directly inside [dir] are
  /// kept (and so is [dir]). Returns how many entries are left.
  static Future<int> deleteBestEffort(String dir, {Set<String> keepTopLevel = const {}}) async {
    var left = 0;
    Future<void> walk(Directory d, bool top) async {
      List<FileSystemEntity> entries;
      try {
        entries = await d.list(followLinks: false).toList();
      } catch (_) {
        left++;
        return;
      }
      for (final e in entries) {
        if (top && keepTopLevel.contains(p.basename(e.path))) {
          left++;
          continue;
        }
        if (e is Directory) {
          await walk(e, false);
          continue;
        }
        try {
          await e.delete();
        } catch (_) {
          left++;
        }
      }
      try {
        if (await d.list().isEmpty) await d.delete();
      } catch (_) {
        left++;
      }
    }

    if (await Directory(dir).exists()) await walk(Directory(dir), true);
    // The kept location.json is not a leftover.
    return left - [for (final k in keepTopLevel) if (File(p.join(dir, k)).existsSync()) k].length;
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
  /// empty). Renames when possible (same volume, nothing in use, instant);
  /// otherwise copies every file, calls [onCopied] (which points the app at
  /// [to], so the data is never only in a half-deleted folder), then removes
  /// the source as far as it can. Files still in use (Windows locks open
  /// files and loaded DLLs) are left and, with [defaultRoot], removed at the
  /// next start. Returns false when something was left. [onProgress] gets
  /// 0..1 for copies.
  static Future<bool> move(
    String from,
    String to, {
    void Function(double)? onProgress,
    Future<void> Function()? onCopied,
    String? defaultRoot,
  }) async {
    final target = Directory(to);
    if (await target.exists()) {
      // location.json is the pointer file of the default folder, not data.
      final hasEntries = await target.list().where((e) {
        final n = p.basename(e.path);
        return !n.startsWith('.') && n != fileName;
      }).isEmpty == false;
      if (hasEntries) throw StateError('target folder is not empty');
      // An empty folder makes way for a rename; the default folder keeps
      // its location.json, so the data is copied into it.
      if (!await File(p.join(to, fileName)).exists()) await target.delete(recursive: true);
    }
    await target.parent.create(recursive: true);
    if (!await target.exists()) {
      try {
        await Directory(from).rename(to);
        onProgress?.call(1);
        await onCopied?.call();
        return true;
      } on FileSystemException {
        // Different volume, or files in use: copy, then remove the source.
      }
    }
    final createdTarget = !await target.exists();
    final files = await Directory(from)
        .list(recursive: true, followLinks: false)
        .where((e) => e is File && !(p.equals(p.dirname(e.path), from) && p.basename(e.path) == fileName))
        .cast<File>()
        .toList();
    var total = 0;
    for (final f in files) {
      total += await f.length();
    }
    var done = 0;
    try {
      for (final f in files) {
        final rel = p.relative(f.path, from: from);
        final dest = File(p.join(to, rel));
        await dest.parent.create(recursive: true);
        await f.copy(dest.path);
        done += await f.length();
        onProgress?.call(total == 0 ? 1 : done / total);
      }
    } catch (_) {
      // Leave the target as it was, so the move can simply be tried again.
      try {
        if (createdTarget) {
          await target.delete(recursive: true);
        } else {
          await deleteBestEffort(to, keepTopLevel: {fileName});
        }
      } catch (_) {}
      rethrow;
    }
    await onCopied?.call();
    final left = await deleteBestEffort(from, keepTopLevel: {fileName});
    if (left > 0 && defaultRoot != null) await addCleanup(defaultRoot, from);
    return left == 0;
  }
}
