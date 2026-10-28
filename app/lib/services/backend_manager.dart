// Execution backend detection, CUDA pack management and runtime creation.
//
// Decision tree (docs/BACKENDS.md):
//   macOS                         -> CPU (CoreML tried per model), no dialog
//   Windows, no NVIDIA GPU        -> DirectML (or CPU when no GPU)
//   Windows, NVIDIA, driver old   -> dialog: update driver (>= 527.41), use DirectML meanwhile
//   Windows, NVIDIA, no CUDA pack -> dialog: download pack (size), or DirectML
//   Windows, CUDA pack present    -> self-test; on failure fall back to DirectML + offer re-download
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import '../engine/engine_bindings.dart';
import 'app_paths.dart';
import 'downloader.dart';
import 'settings.dart';

enum Backend { cuda, directml, coreml, cpu }

enum BackendDialog { none, noGpuCpuOnly, driverTooOld, cudaPackMissing, cudaSelftestFailed, usingDirectml }

class GpuInfo {
  GpuInfo(this.raw);
  final Map<String, dynamic> raw;
  String get name => raw['name'] as String? ?? 'GPU';
  String get vendor => raw['vendor'] as String? ?? 'other';
  int get vramMb => (raw['vram_mb'] as num?)?.toInt() ?? 0;
  int? get cudaDriverVersion => (raw['cuda_driver_version'] as num?)?.toInt();
  String? get computeCapability => raw['compute_capability'] as String?;
  bool get isSoftware => raw['software'] == true;
  bool get isNvidia => vendor == 'nvidia';
}

class BackendDecision {
  BackendDecision({required this.recommended, required this.dialog, required this.gpus, this.detail = ''});
  final Backend recommended;
  final BackendDialog dialog;
  final List<GpuInfo> gpus;
  final String detail;
}

class CudaPackFile {
  CudaPackFile({required this.url, required this.sha256, required this.bytes, required this.members});
  final String url;
  final String sha256;
  final int bytes;
  /// archive member path -> file name to place in cuda_pack/
  final Map<String, String> members;
}

class CudaPackManifest {
  CudaPackManifest({required this.minDriverVersion, required this.ortVersion, required this.files});
  final int minDriverVersion; // e.g. 52741 for 527.41
  final String ortVersion;
  final List<CudaPackFile> files;
  int get totalBytes => files.fold(0, (a, f) => a + f.bytes);

  /// Parses scripts/cuda_pack.json: "onnxruntime" {url, sha256, size, extract:[{path, required}]}
  /// plus "nvidia_wheels": [same shape]. Every extracted member is flattened into cuda_pack/.
  static CudaPackManifest fromJson(Map<String, dynamic> j) {
    CudaPackFile parse(Map<String, dynamic> m) {
      final members = <String, String>{};
      final extract = m['extract'];
      if (extract is List) {
        for (final e in extract) {
          final mm = e as Map<String, dynamic>;
          if (mm['required'] == false) continue;
          final path = mm['path'] as String;
          members[path] = p.basename(path);
        }
      } else if (extract is Map<String, dynamic>) {
        extract.forEach((k, v) => members[k] = '$v');
      }
      return CudaPackFile(
        url: m['url'] as String,
        sha256: m['sha256'] as String,
        bytes: ((m['size'] ?? m['bytes']) as num?)?.toInt() ?? 0,
        members: members,
      );
    }

    final files = <CudaPackFile>[];
    if (j['onnxruntime'] is Map<String, dynamic>) files.add(parse(j['onnxruntime'] as Map<String, dynamic>));
    for (final w in (j['nvidia_wheels'] as List? ?? const [])) {
      files.add(parse(w as Map<String, dynamic>));
    }
    for (final f in (j['files'] as List? ?? const [])) {
      files.add(parse(f as Map<String, dynamic>));
    }
    final req = j['requirements'];
    var minDrv = (j['min_driver_version'] as num?)?.toInt() ?? 52741;
    if (req is Map<String, dynamic> && req['driver_min_windows'] is String) {
      final parts = (req['driver_min_windows'] as String).split('.');
      if (parts.length == 2) minDrv = int.parse(parts[0]) * 100 + int.parse(parts[1]);
    }
    return CudaPackManifest(
      minDriverVersion: minDrv,
      ortVersion: (j['onnxruntime'] is Map<String, dynamic> ? j['onnxruntime']['version'] : j['ort_version']) as String? ?? '',
      files: files,
    );
  }
}

class BackendManager extends ChangeNotifier {
  BackendManager(this.engine, this.paths, this.settings, {Downloader? downloader}) : _dl = downloader ?? Downloader();
  final Engine engine;
  final AppPaths paths;
  final AppSettings settings;
  final Downloader _dl;

  BackendDecision? decision;
  Backend? active;
  EngineRuntime? _runtime;
  String? lastSelftestError;
  double? lastSelftestMs;
  CudaPackManifest? _manifest;

  static const minCudaDriver = 52741; // Windows driver 527.41 for CUDA 12.x

  // ---- CUDA pack ------------------------------------------------------------

  Future<CudaPackManifest?> cudaPackManifest() async {
    if (_manifest != null) return _manifest;
    try {
      final s = await rootBundle.loadString('assets/cuda_pack.json');
      _manifest = CudaPackManifest.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      _manifest = null;
    }
    return _manifest;
  }

  String get cudaPackOrtPath => p.join(paths.cudaPack, 'onnxruntime.dll');

  Future<bool> cudaPackInstalled() async {
    if (!Platform.isWindows) return false;
    for (final f in ['onnxruntime.dll', 'onnxruntime_providers_cuda.dll', 'onnxruntime_providers_shared.dll']) {
      if (!await File(p.join(paths.cudaPack, f)).exists()) return false;
    }
    return true;
  }

  Future<void> installCudaPack({void Function(String stage, double fraction)? onProgress, Future<void>? cancel}) async {
    final m = await cudaPackManifest();
    if (m == null) throw StateError('CUDA pack manifest missing');
    final total = m.totalBytes;
    var done = 0;
    for (final f in m.files) {
      final name = p.basename(Uri.parse(f.url).path);
      final tmp = p.join(paths.cache, name);
      await _dl.download(Uri.parse(f.url), tmp, sha256: f.sha256, cancel: cancel, onProgress: (dp) {
        onProgress?.call('download $name', (done + dp.received) / total);
      });
      onProgress?.call('extract $name', (done + f.bytes) / total);
      await _extractMembers(tmp, f.members, paths.cudaPack);
      await File(tmp).delete();
      done += f.bytes;
    }
    notifyListeners();
  }

  Future<void> _extractMembers(String archivePath, Map<String, String> members, String destDir) async {
    final bytes = await File(archivePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final wanted = <String, String>{};
    members.forEach((member, dest) => wanted[member.replaceAll('\\', '/')] = dest);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      // Match by full member path or by basename.
      String? dest = wanted[name];
      dest ??= wanted.entries.where((e) => p.basename(e.key) == p.basename(name) && !e.key.contains('/')).map((e) => e.value).firstOrNull;
      if (dest == null) continue;
      final out = File(p.join(destDir, dest));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(file.content as List<int>, flush: true);
    }
  }

  Future<void> removeCudaPack() async {
    final d = Directory(paths.cudaPack);
    if (await d.exists()) {
      await d.delete(recursive: true);
      await d.create();
    }
    notifyListeners();
  }

  // ---- detection ------------------------------------------------------------

  Future<BackendDecision> detect() async {
    final gpus = engine.gpuInfo().map(GpuInfo.new).toList();
    BackendDecision d;
    if (Platform.isMacOS) {
      d = BackendDecision(recommended: Backend.cpu, dialog: BackendDialog.none, gpus: gpus);
    } else if (Platform.isWindows) {
      final real = gpus.where((g) => !g.isSoftware).toList();
      final nvidia = real.where((g) => g.isNvidia).toList();
      if (real.isEmpty) {
        d = BackendDecision(recommended: Backend.cpu, dialog: BackendDialog.noGpuCpuOnly, gpus: gpus);
      } else if (nvidia.isEmpty) {
        d = BackendDecision(recommended: Backend.directml, dialog: BackendDialog.usingDirectml, gpus: gpus);
      } else {
        final g = nvidia.first;
        final drv = g.cudaDriverVersion;
        final cc = double.tryParse(g.computeCapability ?? '') ?? 0;
        if (drv == null || drv < 12000 || cc < 6.0 || g.vramMb < 4096) {
          d = BackendDecision(
            recommended: Backend.directml,
            dialog: drv == null ? BackendDialog.driverTooOld : (cc < 6.0 || g.vramMb < 4096 ? BackendDialog.usingDirectml : BackendDialog.driverTooOld),
            gpus: gpus,
            detail: 'driver=${drv ?? 'none'} cc=${g.computeCapability ?? '?'} vram=${g.vramMb}MB',
          );
        } else if (!await cudaPackInstalled()) {
          d = BackendDecision(recommended: Backend.cuda, dialog: BackendDialog.cudaPackMissing, gpus: gpus);
        } else {
          d = BackendDecision(recommended: Backend.cuda, dialog: BackendDialog.none, gpus: gpus);
        }
      }
    } else {
      d = BackendDecision(recommended: Backend.cpu, dialog: BackendDialog.none, gpus: gpus);
    }
    decision = d;
    notifyListeners();
    return d;
  }

  /// Backends that can be attempted on this machine, best first.
  List<Backend> candidates() {
    if (Platform.isMacOS) return [Backend.cpu, Backend.coreml];
    if (Platform.isWindows) return [Backend.cuda, Backend.directml, Backend.cpu];
    return [Backend.cpu];
  }

  String ortPathFor(Backend b) {
    if (Platform.isWindows && b == Backend.cuda) return cudaPackOrtPath;
    return EngineLocator.ortLibraryPath();
  }

  int epFor(Backend b) => switch (b) {
        Backend.cuda => KeEp.cuda,
        Backend.directml => KeEp.directml,
        Backend.coreml => KeEp.coreml,
        Backend.cpu => KeEp.cpu,
      };

  /// Creates (or returns) the runtime for the chosen backend, falling back down
  /// the candidate list when creation or self-test fails.
  Future<EngineRuntime> runtime({String? selftestModel}) async {
    if (_runtime != null) return _runtime!;
    final choice = settings.backend;
    final order = <Backend>[];
    if (choice == BackendChoice.auto) {
      final d = decision ?? await detect();
      order.add(d.recommended);
      for (final c in candidates()) {
        if (!order.contains(c)) order.add(c);
      }
    } else {
      final b = Backend.values.byName(choice.name);
      order.add(b);
      for (final c in candidates()) {
        if (!order.contains(c)) order.add(c);
      }
    }
    Object? lastErr;
    for (final b in order) {
      if (b == Backend.cuda && !await cudaPackInstalled()) continue;
      try {
        final rt = engine.createRuntime(ortLibraryPath: ortPathFor(b), ep: epFor(b));
        if (b != Backend.cpu && rt.activeEp != epFor(b)) {
          lastSelftestError = (rt.info()['error'] ?? '') as String;
          rt.dispose();
          continue;
        }
        if (b == Backend.cuda || b == Backend.directml) {
          try {
            lastSelftestMs = rt.selftest(selftestModel);
          } catch (e) {
            lastSelftestError = '$e';
            rt.dispose();
            continue;
          }
        }
        _runtime = rt;
        active = b;
        notifyListeners();
        return rt;
      } catch (e) {
        lastErr = e;
        lastSelftestError = '$e';
      }
    }
    throw StateError('no usable backend: $lastErr');
  }

  /// Drops the current runtime (after the user changes the backend setting).
  void resetRuntime() {
    _runtime?.dispose();
    _runtime = null;
    active = null;
    notifyListeners();
  }

  /// Benchmarks every candidate backend with [modelPath] and returns ms per backend.
  Future<Map<Backend, double?>> benchmark(String modelPath) async {
    final out = <Backend, double?>{};
    for (final b in candidates()) {
      if (b == Backend.cuda && !await cudaPackInstalled()) {
        out[b] = null;
        continue;
      }
      try {
        final rt = engine.createRuntime(ortLibraryPath: ortPathFor(b), ep: epFor(b));
        try {
          out[b] = (b != Backend.cpu && rt.activeEp != epFor(b)) ? null : rt.selftest(modelPath);
        } finally {
          rt.dispose();
        }
      } catch (_) {
        out[b] = null;
      }
    }
    return out;
  }

  @override
  void dispose() {
    _runtime?.dispose();
    super.dispose();
  }
}
