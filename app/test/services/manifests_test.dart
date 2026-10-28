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
    expect(m.minDriverVersion, 52741);
    expect(m.ortVersion, '1.31.1');
    expect(m.files.length, 5);
    final all = m.files.expand((f) => f.members.values).toSet();
    expect(all, containsAll(['onnxruntime.dll', 'onnxruntime_providers_cuda.dll', 'cudart64_12.dll', 'cublas64_12.dll', 'cudnn64_9.dll']));
    expect(m.totalBytes, greaterThan(1000000000));
  });
}
