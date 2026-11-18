import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/backend_manager.dart';
import 'package:karaoke_battle/services/sidecars.dart';

void main() {
  test('sidecars.json parses into a catalog with ffmpeg/ffprobe/yt-dlp/deno sources', () {
    final j = jsonDecode(File('assets/sidecars.json').readAsStringSync()) as Map<String, dynamic>;
    final c = SidecarCatalog.fromJson(j);
    expect(c.sources[SidecarKind.ytDlp]!.keys, containsAll(['macos-universal2', 'win-x64']));
    expect(c.sources[SidecarKind.deno]!['macos-arm64']!.archiveMember, 'deno');
    expect(c.sources[SidecarKind.ffmpeg]!['macos-arm64']!.archiveMember, 'ffmpeg');
    expect(c.sources[SidecarKind.ffprobe]!['macos-arm64']!.url, contains('ffprobe.zip'));
    expect(c.sources[SidecarKind.ffmpeg]!['win-x64']!.archiveMember, endsWith('bin/ffmpeg.exe'));
    expect(c.sources[SidecarKind.ffprobe]!['win-x64']!.archiveMember, endsWith('bin/ffprobe.exe'));
    expect(c.sourceFor(SidecarKind.ytDlp), isNotNull);
  });

  test('cuda_pack.json parses with all required members', () {
    final j = jsonDecode(File('assets/cuda_pack.json').readAsStringSync()) as Map<String, dynamic>;
    final m = CudaPackManifest.fromJson(j);
    expect(m.minDriverVersion, 58088);
    expect(m.cudaMajor, 13);
    expect(m.minCudaDriverApi, 13000);
    expect(m.minComputeCapability, 7.5);
    expect(m.ortVersion, '1.31.1');
    expect(m.files.length, 5);
    // Nothing may come from the microsoft/onnxruntime GitHub repository any more (issue #7).
    for (final f in m.files) {
      expect(Uri.parse(f.url).host, isNot('github.com'));
      expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    final all = m.installedNames;
    expect(all, containsAll(['onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll', 'cudart64_13.dll', 'cublas64_13.dll', 'cublasLt64_13.dll', 'cufft64_12.dll', 'cudnn64_9.dll']));
    expect(all.length, all.toSet().length);
    expect(m.totalBytes, greaterThan(1000000000));
  });

  test('the app copy of cuda_pack.json matches scripts/', () {
    expect(File('assets/cuda_pack.json').readAsStringSync(), File('../scripts/cuda_pack.json').readAsStringSync());
  });

  test('a pre-CUDA 13 manifest keeps the CUDA 12 requirements', () {
    final m = CudaPackManifest.fromJson({
      'requirements': {'driver_min_windows': '527.41'},
      'onnxruntime': {'version': '1.31.1', 'url': 'https://example.com/a.zip', 'sha256': 'x', 'size': 1, 'extract': []},
    });
    expect(m.cudaMajor, 12);
    expect(m.minCudaDriverApi, 12000);
    expect(m.minComputeCapability, 6.0);
    expect(m.minDriverVersion, 52741);
  });
}
