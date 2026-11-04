// Tracks model and sidecar install state + download progress for the
// first-run dialog and the settings screen.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/model_registry.dart';
import '../services/sidecars.dart';
import 'i18n.dart';

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

  /// File being checked by [verifyRequired] (null when not checking).
  String? verifying;

  /// Every launch: checks the required models in full (sha256, cached per
  /// file) and the required tools. [ready] tells whether the app may open.
  Future<void> verifyRequired() async {
    // yt-dlp's own check (it runs the binary) overlaps the model hashing.
    final yt = checkYtDlp();
    for (final m in ModelRegistry.required) {
      stateOf(m).installed = await models.verifyCached(m, onFile: (f) {
        verifying = '${m.title} · $f';
        notifyListeners();
      });
    }
    verifying = null;
    await yt;
    await refresh();
  }

  /// Result of the last yt-dlp launch check (null before it ran).
  YtDlpHealth? ytDlpHealth;

  /// The PATH yt-dlp for [YtDlpHealth.pathOnly], the error for [YtDlpHealth.broken].
  String ytDlpDetail = '';

  Future<void> checkYtDlp() async {
    try {
      final r = await sidecars.checkYtDlp();
      ytDlpHealth = r.health;
      ytDlpDetail = r.detail;
    } catch (e) {
      ytDlpHealth = YtDlpHealth.broken;
      ytDlpDetail = '$e';
    }
    notifyListeners();
  }

  /// Tools without which songs cannot be prepared.
  static const requiredSidecars = [SidecarKind.ytDlp, SidecarKind.ffmpeg];

  /// Everything the app needs to be used is present.
  bool get ready => requiredInstalled && requiredSidecars.every((k) => sidecarStates[k]!.available);

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

  final Map<SidecarKind, Future<void>> _sidecarJobs = {};

  /// Installs the app's copy of [k]. A second call while it runs waits for
  /// the first instead of returning early, so callers can trust [SidecarState.error].
  Future<void> installSidecar(SidecarKind k) {
    final running = _sidecarJobs[k];
    if (running != null) return running;
    final job = _installSidecar(k);
    _sidecarJobs[k] = job;
    return job.whenComplete(() => _sidecarJobs.remove(k));
  }

  Future<void> _installSidecar(SidecarKind k) async {
    final s = sidecarStates[k]!;
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

  Future<({bool ok, String message})>? _ytJob;

  /// An update or repair of yt-dlp is running.
  bool get ytDlpBusy => _ytJob != null || sidecarStates[SidecarKind.ytDlp]!.installing;

  /// The settings screen's 「更新 yt-dlp」 and the yt-dlp dialog. When the app
  /// has no copy of its own (only one on PATH, or none) it installs one
  /// first, with the usual progress on the yt-dlp row, then updates that
  /// copy. [reinstall] throws the current copy away first (repair). A call
  /// while one runs gets that one's result.
  Future<({bool ok, String message})> updateYtDlp({bool reinstall = false}) {
    final running = _ytJob;
    if (running != null) return running;
    final job = _updateYtDlp(reinstall);
    _ytJob = job;
    notifyListeners();
    return job.whenComplete(() {
      _ytJob = null;
      notifyListeners();
    });
  }

  Future<({bool ok, String message})> _updateYtDlp(bool reinstall) async {
    const k = SidecarKind.ytDlp;
    final managed = File(sidecars.managedPath(k));
    try {
      if (reinstall) {
        await _sidecarJobs[k];
        if (await managed.exists()) await managed.delete();
      }
      final missing = !await managed.exists();
      if (missing) {
        await installSidecar(k);
        final err = sidecarStates[k]!.error;
        if (err != null) return (ok: false, message: tr('settings.ytDlpInstallFailed', {'error': err}));
      }
      final r = await sidecars.updateYtDlp();
      if (!r.ok) return (ok: false, message: tr('settings.ytDlpUpdateFailed', {'error': r.output}));
      ytDlpHealth = YtDlpHealth.ok;
      return (ok: true, message: missing ? '${tr('settings.ytDlpInstalled')}\n${r.output}' : r.output);
    } catch (e) {
      return (ok: false, message: tr('settings.ytDlpUpdateFailed', {'error': e}));
    } finally {
      await refresh();
    }
  }
}
