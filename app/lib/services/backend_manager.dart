// Execution backend detection, CUDA pack management and runtime creation.
//
// Decision tree (docs/BACKENDS.md):
//   macOS                         -> CPU (CoreML tried per model), no dialog
//   Windows, no NVIDIA GPU        -> DirectML (or CPU when no GPU)
//   Windows, NVIDIA, driver old   -> dialog: update driver (>= 580.88 for the CUDA 13 pack), use DirectML meanwhile
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
  CudaPackFile({required this.url, required this.sha256, required this.bytes, required this.members, this.mirror});
  final String url;
  final String sha256;
  final int bytes;
  /// archive member path -> file name to place in cuda_pack/
  final Map<String, String> members;

  /// The same DLLs on the app's own Hugging Face mirror, tried when [url]
  /// fails (a vanished release, as microsoft/onnxruntime in issue #7).
  final CudaPackFile? mirror;
}

class CudaPackManifest {
  CudaPackManifest({
    required this.minDriverVersion,
    required this.ortVersion,
    required this.files,
    this.cudaMajor = 12,
    this.minCudaDriverApi = 12000,
    this.minComputeCapability = 6.0,
  });
  final int minDriverVersion; // e.g. 58088 for 580.88 (shown to the user)
  final String ortVersion;
  final List<CudaPackFile> files;

  /// CUDA major version of the libraries in this pack.
  final int cudaMajor;

  /// Lowest cuDriverGetVersion (e.g. 13000 = CUDA 13.0) that runs this pack.
  final int minCudaDriverApi;

  /// Lowest GPU compute capability the pack has kernels for.
  final double minComputeCapability;

  int get totalBytes => files.fold(0, (a, f) => a + f.bytes);

  /// File names the pack places in cuda_pack/.
  Set<String> get installedNames => {for (final f in files) ...f.members.values};

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
        mirror: m['mirror'] is Map<String, dynamic> ? parse(m['mirror'] as Map<String, dynamic>) : null,
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
    final req = j['requirements'] is Map<String, dynamic> ? j['requirements'] as Map<String, dynamic> : const <String, dynamic>{};
    var minDrv = (j['min_driver_version'] as num?)?.toInt() ?? 52741;
    if (req['driver_min_windows'] is String) {
      final parts = (req['driver_min_windows'] as String).split('.');
      if (parts.length == 2) minDrv = int.parse(parts[0]) * 100 + int.parse(parts[1]);
    }
    final major = (j['cuda_major'] as num?)?.toInt() ?? 12;
    return CudaPackManifest(
      minDriverVersion: minDrv,
      ortVersion: (j['onnxruntime'] is Map<String, dynamic> ? j['onnxruntime']['version'] : j['ort_version']) as String? ?? '',
      files: files,
      cudaMajor: major,
      minCudaDriverApi: (req['min_cuda_driver_api'] as num?)?.toInt() ?? major * 1000,
      minComputeCapability: double.tryParse('${req['min_compute_capability'] ?? ''}') ?? (major >= 13 ? 7.5 : 6.0),
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

  /// CUDA major version of the installed pack: 12 for the packs before
  /// 2026-11 (ORT's GitHub cuda12 zip), 13 for the NuGet based one, null
  /// when it cannot tell. An installed CUDA 12 pack keeps working and keeps
  /// its own (lower) driver requirement; it is only replaced on request.
  Future<int?> installedPackCudaMajor() async {
    for (final (name, major) in [('cublas64_13.dll', 13), ('cublas64_12.dll', 12)]) {
      if (await File(p.join(paths.cudaPack, name)).exists()) return major;
    }
    return null;
  }

  Future<void> installCudaPack({void Function(String stage, double fraction)? onProgress, Future<void>? cancel}) async {
    final m = await cudaPackManifest();
    if (m == null) throw StateError('CUDA pack manifest missing');
    final total = m.totalBytes;
    var done = 0;
    var cancelled = false;
    cancel?.then((_) => cancelled = true);
    for (final f in m.files) {
      Future<void> fetch(CudaPackFile src) async {
        final name = p.basename(Uri.parse(src.url).path);
        final tmp = p.join(paths.cache, name);
        await _dl.download(Uri.parse(src.url), tmp, sha256: src.sha256, cancel: cancel, onProgress: (dp) {
          onProgress?.call('download $name', ((done + dp.received) / total).clamp(0.0, 1.0));
        });
        onProgress?.call('extract $name', ((done + f.bytes) / total).clamp(0.0, 1.0));
        await _extractMembers(tmp, src.members, paths.cudaPack);
        await File(tmp).delete();
      }

      try {
        await fetch(f);
      } catch (e) {
        final mirror = f.mirror;
        // A declined certificate prompt would only come back for the mirror.
        if (mirror == null || cancelled || e is CertificateException) rethrow;
        try {
          await fetch(mirror);
        } catch (e2) {
          if (cancelled) rethrow;
          throw DownloadException('$e\n$e2');
        }
      }
      done += f.bytes;
    }
    // Drop what an older pack left behind (an install over the CUDA 12 pack
    // would otherwise keep about 2.5 GB of unused DLLs). A file still loaded
    // by this process cannot be deleted on Windows; it goes next time.
    final keep = m.installedNames.map((n) => n.toLowerCase()).toSet();
    await for (final e in Directory(paths.cudaPack).list()) {
      final name = p.basename(e.path).toLowerCase();
      if (e is File && name.endsWith('.dll') && !keep.contains(name)) {
        try {
          await e.delete();
        } catch (_) {}
      }
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
        // The requirements of the pack that would run: the installed one
        // (an old CUDA 12 pack keeps its lower ones) or the one we download.
        final installed = await cudaPackInstalled();
        final m = await cudaPackManifest();
        final oldPack = installed && await installedPackCudaMajor() == 12;
        final minApi = oldPack ? 12000 : (m?.minCudaDriverApi ?? 13000);
        final minCc = oldPack ? 6.0 : (m?.minComputeCapability ?? 7.5);
        if (drv == null || drv < minApi || cc < minCc || g.vramMb < 4096) {
          d = BackendDecision(
            recommended: Backend.directml,
            dialog: drv == null ? BackendDialog.driverTooOld : (cc < minCc || g.vramMb < 4096 ? BackendDialog.usingDirectml : BackendDialog.driverTooOld),
            gpus: gpus,
            detail: 'driver=${drv ?? 'none'} cc=${g.computeCapability ?? '?'} vram=${g.vramMb}MB',
          );
        } else if (!installed) {
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

  /// Runtimes replaced by [resetRuntime]; kept alive until the app exits.
  final List<EngineRuntime> _retired = [];

  /// Drops the current runtime (after the user changes the backend setting)
  /// so the next job creates one for the new backend. The old one is not
  /// disposed: a prep job, the beat detection or a live capture may still be
  /// running on it, and freeing it under them crashed the app.
  void resetRuntime() {
    final rt = _runtime;
    if (rt != null) _retired.add(rt);
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
