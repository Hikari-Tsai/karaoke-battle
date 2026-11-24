// Bootstrap of every long-lived service and a holder passed down via provider.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../engine/engine.dart';
import '../services/achievements.dart';
import '../services/items.dart';
import '../services/backing_import.dart';
import '../services/identity.dart';
import '../services/ai_keys.dart';
import '../services/app_log.dart';
import '../services/app_paths.dart';
import '../services/backend_manager.dart';
import '../services/model_registry.dart';
import '../services/prep_pipeline.dart';
import '../services/replay_library.dart';
import '../services/settings.dart';
import '../services/sing_history.dart';
import '../services/sidecars.dart';
import '../services/song_library.dart';
import 'i18n.dart';

class AppServices {
  AppServices({
    required this.paths,
    required this.settings,
    required this.engine,
    required this.models,
    required this.sidecars,
    required this.backend,
    required this.library,
    required this.pipeline,
    required this.replays,
    AiKeyStore? aiKeys,
  }) : aiKeys = aiKeys ?? SecureAiKeyStore();

  final AppPaths paths;
  final AppSettings settings;
  final Engine engine;
  final ModelStore models;
  final Sidecars sidecars;
  final BackendManager backend;
  final SongLibrary library;
  final PrepPipeline pipeline;
  final ReplayLibrary replays;

  /// API keys for AI singing advice (system keychain).
  final AiKeyStore aiKeys;

  /// Today's setlist in setlist/ (for OBS), rewritten as takes are scored.
  late final SetlistLog setlistLog = SetlistLog(library, settings, paths.setlists);

  /// Importing and aligning the user's own backing tracks.
  late final BackingImport backingImport = BackingImport(library: library, sidecars: sidecars, engine: engine, paths: paths, pipeline: pipeline);

  /// What the player has achieved (kept in the data folder).
  late final AchievementService achievements = AchievementService(library: library, replays: replays, settings: settings, dataRoot: paths.root, cacheDir: paths.cache);

  /// Items redeemed with achievement points (items.json).
  late final ItemService items = ItemService.of(paths.root, achievements);

  /// The player's UUID and the devices it has been used on (identity.json).
  late final IdentityService identity = IdentityService(dataRoot: paths.root);

  /// Path of the SwiftF0 model file (may not exist yet).
  String get swiftF0ModelPath => models.pathOf(ModelRegistry.swiftF0, 'model.onnx');

  Timer? _artistTimer;

  /// Fills in the artist, year and language of older YouTube songs a little
  /// after start, so it does not compete with opening the app.
  void backfillArtistsLater() {
    _artistTimer = Timer(const Duration(seconds: 20), () => unawaited(pipeline.backfillYoutubeMeta()));
  }

  void dispose() {
    _artistTimer?.cancel();
    setlistLog.stop();
    items.dispose();
    achievements.dispose();
    pipeline.dispose();
    library.dispose();
    backend.dispose();
  }
}

/// Thrown when the native engine cannot be loaded; carries the attempted path.
class EngineLoadError implements Exception {
  EngineLoadError(this.path, this.cause);
  final String path;
  final Object cause;
  @override
  String toString() => 'EngineLoadError($path): $cause';
}

bool _engineLogged = false;

Future<AppServices> bootstrapServices() async {
  final paths = await AppPaths.init();
  await AppLog.init(paths.logs, header: await _logHeader());
  final settings = await AppSettings.load();
  I18n.notifier.value = settings.uiLanguage ?? I18n.fromLocale(Platform.localeName);
  I18n.onChanged = (lang) => settings.setUiLanguage(lang);

  final Engine engine;
  try {
    engine = Engine.instance;
  } catch (e) {
    throw EngineLoadError(EngineLocator.engineLibraryPath(), e);
  }
  // Once: a retried bootstrap gets the same engine.
  if (!_engineLogged) {
    _engineLogged = true;
    engine.logs.listen(AppLog.engine);
    AppLog.info('engine ${engine.version}');
  }

  final models = ModelStore(paths);

  SidecarCatalog catalog;
  try {
    final s = await rootBundle.loadString('assets/sidecars.json');
    catalog = SidecarCatalog.fromJson(jsonDecode(s) as Map<String, dynamic>);
  } catch (_) {
    catalog = SidecarCatalog.defaults();
  }
  final sidecars = Sidecars(paths, catalog, onlineManifest: Sidecars.defaultOnlineManifest);

  final backend = BackendManager(engine, paths, settings);
  final library = SongLibrary(paths);
  await library.reload();
  final pipeline = PrepPipeline(library: library, sidecars: sidecars, models: models, backend: backend, settings: settings);
  final replays = ReplayLibrary(paths, sidecars);
  await replays.reload();

  return AppServices(
    paths: paths,
    settings: settings,
    engine: engine,
    models: models,
    sidecars: sidecars,
    backend: backend,
    library: library,
    pipeline: pipeline,
    replays: replays,
  )
    ..setlistLog.start()
    // In the background: it reads every take once.
    ..achievements.start()
    ..items.start()
    ..identity.start()
    ..backfillArtistsLater();
}

/// First line of a run in the log: app version and OS.
Future<String> _logHeader() async {
  var version = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version}+${info.buildNumber}';
  } catch (_) {}
  return 'Karaoke Battle $version, ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
}

/// Reveals a folder or file in Finder / Explorer; falls back to a file: URL.
Future<void> revealPath(String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
      return;
    }
    if (Platform.isWindows) {
      final isDir = await Directory(path).exists();
      await Process.run('explorer', [isDir ? path : '/select,${p.normalize(path)}']);
      return;
    }
  } catch (_) {}
  await launchUrl(Uri.file(path));
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatDuration(double? seconds) {
  if (seconds == null || seconds.isNaN) return '--:--';
  final s = seconds.round();
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}
