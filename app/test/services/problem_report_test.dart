import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/backend_manager.dart';
import 'package:karaoke_battle/services/problem_report.dart';

void main() {
  test('pre-fills the bug report form', () {
    final u = problemReportUri(version: '0.6.0', os: 'Windows 11 (Build 22631)', backend: 'CUDA');
    expect(u.toString(), startsWith('https://github.com/Hikari-Tsai/karaoke-battle/issues/new?'));
    expect(u.queryParameters, {'template': 'bug_report.yml', 'version': '0.6.0', 'os': 'Windows 11 (Build 22631)', 'backend': 'CUDA'});
  });

  test('fills in the graphics card', () {
    final u = problemReportUri(version: '0.7.10', gpu: 'NVIDIA GeForce RTX 3060 (12 GB, CUDA 12.8)');
    expect(u.queryParameters['gpu'], 'NVIDIA GeForce RTX 3060 (12 GB, CUDA 12.8)');
  });

  test('summarises the graphics cards, leaving software adapters out', () {
    expect(
      gpuSummary([
        GpuInfo({'name': 'NVIDIA GeForce RTX 3060', 'vendor': 'nvidia', 'vram_mb': 12288, 'cuda_driver_version': 12080}),
        GpuInfo({'name': 'Intel(R) UHD Graphics 770', 'vendor': 'intel', 'vram_mb': 128}),
        GpuInfo({'name': 'Microsoft Basic Render Driver', 'vendor': 'other', 'software': true}),
      ]),
      'NVIDIA GeForce RTX 3060 (12 GB, CUDA 12.8) / Intel(R) UHD Graphics 770 (128 MB)',
    );
    expect(gpuSummary([GpuInfo({'name': 'Apple M1 Pro', 'vendor': 'apple', 'vram_mb': 16384})]), 'Apple M1 Pro (16 GB)');
    expect(gpuSummary([GpuInfo({'name': 'Microsoft Basic Render Driver', 'software': true})]), isNull);
    expect(gpuSummary([]), isNull);
  });

  test('leaves unknown fields out', () {
    expect(problemReportUri(version: '', backend: null).queryParameters, {'template': 'bug_report.yml'});
  });
}
