// Bootstrap of every long-lived service and a holder passed down via provider.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../engine/engine.dart';
import '../services/app_paths.dart';
import '../services/backend_manager.dart';
import '../services/model_registry.dart';
import '../services/prep_pipeline.dart';
import '../services/settings.dart';
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
  });

  final AppPaths paths;
  final AppSettings settings;
  final Engine engine;
  final ModelStore models;
  final Sidecars sidecars;
  final BackendManager backend;
  final SongLibrary library;
  final PrepPipeline pipeline;

  /// Path of the SwiftF0 model file (may not exist yet).
  String get swiftF0ModelPath => models.pathOf(ModelRegistry.swiftF0, 'model.onnx');

  void dispose() {
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

Future<AppServices> bootstrapServices() async {
  final paths = await AppPaths.init();
  final settings = await AppSettings.load();
  I18n.notifier.value = settings.uiLanguage ?? I18n.fromLocale(Platform.localeName);
  I18n.onChanged = (lang) => settings.setUiLanguage(lang);

  final Engine engine;
  try {
    engine = Engine.instance;
  } catch (e) {
    throw EngineLoadError(EngineLocator.engineLibraryPath(), e);
  }

  final models = ModelStore(paths);

  SidecarCatalog catalog;
  try {
    final s = await rootBundle.loadString('assets/sidecars.json');
    catalog = SidecarCatalog.fromJson(jsonDecode(s) as Map<String, dynamic>);
  } catch (_) {
    catalog = SidecarCatalog.defaults();
  }
  final sidecars = Sidecars(paths, catalog);

  final backend = BackendManager(engine, paths, settings);
  final library = SongLibrary(paths);
  await library.reload();
  final pipeline = PrepPipeline(library: library, sidecars: sidecars, models: models, backend: backend, settings: settings);

  return AppServices(
    paths: paths,
    settings: settings,
    engine: engine,
    models: models,
    sidecars: sidecars,
    backend: backend,
    library: library,
    pipeline: pipeline,
  );
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
