// Tracks model and sidecar install state + download progress for the
// first-run dialog and the settings screen.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/model_registry.dart';
import '../services/sidecars.dart';

class ModelState {
  ModelState({this.installed = false, this.downloading = false, this.file = '', this.fraction = 0, this.doneBytes = 0, this.error});
  bool installed;
  bool downloading;
  String file;
  double fraction;
  int doneBytes;
  String? error;
}

class SidecarState {
  SidecarState({this.path, this.installing = false, this.fraction = 0, this.error, this.hasSource = false});
  String? path;
  bool installing;
  double fraction;
  String? error;
  bool hasSource;
  bool get available => path != null;
}

class SetupController extends ChangeNotifier {
  SetupController(this.models, this.sidecars);
  final ModelStore models;
  final Sidecars sidecars;

  final Map<String, ModelState> modelStates = {for (final m in ModelRegistry.all) m.id: ModelState()};
  final Map<SidecarKind, SidecarState> sidecarStates = {for (final k in SidecarKind.values) k: SidecarState()};
  final Map<String, Completer<void>> _cancels = {};
  bool _refreshing = false;

  ModelState stateOf(ModelSpec m) => modelStates[m.id]!;

  bool get requiredInstalled => ModelRegistry.required.every((m) => stateOf(m).installed);
  int get requiredMissingBytes => ModelRegistry.required.where((m) => !stateOf(m).installed).fold(0, (a, m) => a + m.totalBytes);
  bool get anyDownloading => modelStates.values.any((s) => s.downloading);

  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      for (final m in ModelRegistry.all) {
        stateOf(m).installed = await models.isInstalled(m);
      }
      for (final k in SidecarKind.values) {
        final s = sidecarStates[k]!;
        s.path = await sidecars.resolve(k);
        s.hasSource = sidecars.catalog.sourceFor(k) != null;
      }
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> install(ModelSpec m) async {
    final s = stateOf(m);
    if (s.downloading) return;
    s
      ..downloading = true
      ..error = null
      ..fraction = 0
      ..doneBytes = 0;
    notifyListeners();
    final c = Completer<void>();
    _cancels[m.id] = c;
    var lastNotify = DateTime.now();
    try {
      await models.install(m, cancel: c.future, onProgress: (file, dp, done, total) {
        s
          ..file = file
          ..doneBytes = done
          ..fraction = total > 0 ? done / total : 0;
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds > 100) {
          lastNotify = now;
          notifyListeners();
        }
      });
      s.installed = await models.isInstalled(m);
    } catch (e) {
      s.error = '$e';
    } finally {
      s.downloading = false;
      _cancels.remove(m.id);
      notifyListeners();
    }
  }

  Future<void> installAll(Iterable<ModelSpec> specs) async {
    for (final m in specs) {
      if (!stateOf(m).installed) await install(m);
    }
  }

  void cancel(ModelSpec m) => _cancels[m.id]?.complete();

  Future<void> remove(ModelSpec m) async {
    await models.remove(m);
    stateOf(m).installed = false;
    notifyListeners();
  }

  Future<void> installSidecar(SidecarKind k) async {
    final s = sidecarStates[k]!;
    if (s.installing) return;
    s
      ..installing = true
      ..error = null
      ..fraction = 0;
    notifyListeners();
    var lastNotify = DateTime.now();
    try {
      s.path = await sidecars.install(k, onProgress: (dp) {
        s.fraction = dp.fraction;
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds > 100) {
          lastNotify = now;
          notifyListeners();
        }
      });
    } catch (e) {
      s.error = '$e';
    } finally {
      s.installing = false;
      notifyListeners();
    }
  }

  /// Copies a user-chosen executable into the managed sidecar folder.
  Future<void> useExecutable(SidecarKind k, String sourcePath) async {
    final s = sidecarStates[k]!;
    try {
      final dest = sidecars.managedPath(k);
      await File(sourcePath).copy(dest);
      if (!Platform.isWindows) await Process.run('chmod', ['+x', dest]);
      s.path = dest;
      s.error = null;
      // ffprobe usually sits next to ffmpeg.
      if (k == SidecarKind.ffmpeg) {
        final probe = sourcePath.replaceAll(RegExp(r'ffmpeg(\.exe)?$'), Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');
        if (probe != sourcePath && await File(probe).exists()) {
          final pd = sidecars.managedPath(SidecarKind.ffprobe);
          await File(probe).copy(pd);
          if (!Platform.isWindows) await Process.run('chmod', ['+x', pd]);
          sidecarStates[SidecarKind.ffprobe]!.path = pd;
        }
      }
    } catch (e) {
      s.error = '$e';
    }
    notifyListeners();
  }

  Future<String> updateYtDlp() async {
    final r = await sidecars.updateYtDlp();
    await refresh();
    return r;
  }
}
