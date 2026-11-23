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

  test('fills in the audio devices', () {
    final devices = {
      'capture': [
        {'id': 'mic-1', 'name': 'MacBook Pro Microphone', 'default': true},
        {'id': 'usb-2', 'name': 'Scarlett 2i2 USB'},
      ],
      'playback': [
        {'id': 'spk-1', 'name': 'MacBook Pro Speakers'},
        {'id': 'air-2', 'name': 'AirPods', 'default': true},
      ],
    };
    expect(audioDeviceSummary(devices, sampleRate: 48000, latencySeconds: 0.12),
        'In: MacBook Pro Microphone (system default) / Out: AirPods (system default) / 48000 Hz / latency 120 ms');
    expect(audioDeviceSummary(devices, captureId: 'usb-2', playbackId: 'spk-1'), 'In: Scarlett 2i2 USB / Out: MacBook Pro Speakers');
    expect(audioDeviceSummary(devices, captureId: 'gone'), 'In: chosen device not connected / Out: AirPods (system default)', reason: 'an unplugged choice');
    expect(audioDeviceSummary({'capture': [], 'playback': []}), 'In: system default / Out: system default');
    expect(audioDeviceSummary(null), isNull);
    expect(problemReportUri(version: '1.2.0', audio: 'In: A / Out: B').queryParameters['audio'], 'In: A / Out: B');
  });

  test('carries the error and the log', () {
    final u = problemReportUri(version: '1.1.2', error: 'boom', logs: 'a\nb');
    expect(u.queryParameters['error'], 'boom');
    expect(u.queryParameters['logs'], 'a\nb');
  });

  test('keeps the whole log when it fits', () {
    final base = problemReportUri(version: '1.1.2');
    final r = fitReportLogs(base, ['one', 'two', 'three']);
    expect(r.text, 'one\ntwo\nthree');
    expect(r.kept, 3);
  });

  test('keeps the last lines that fit, with the note in front', () {
    final base = problemReportUri(version: '1.1.2', error: 'boom');
    final lines = [for (var i = 0; i < 2000; i++) '12:00:00.000 I line $i with some text in it'];
    final r = fitReportLogs(base, lines, note: (n) => '(last $n lines)');
    expect(r.kept, greaterThan(10));
    expect(r.kept, lessThan(lines.length));
    expect(r.text, startsWith('(last ${r.kept} lines)\n'));
    expect(r.text, endsWith('line 1999 with some text in it'));
    final url = base.replace(queryParameters: {...base.queryParameters, 'logs': r.text}).toString();
    expect(url.length, lessThanOrEqualTo(maxReportUrlLength));
    // One more line would not have fitted.
    final more = '(last ${r.kept + 1} lines)\n${lines.sublist(lines.length - r.kept - 1).join('\n')}';
    expect(base.replace(queryParameters: {...base.queryParameters, 'logs': more}).toString().length, greaterThan(maxReportUrlLength));
  });

  test('shortens long errors and hides the home folder', () {
    expect(reportErrorText(StateError('cannot open /Users/alice/Music/a.wav')), 'Bad state: cannot open ~/Music/a.wav');
    final long = reportErrorText('x' * 5000);
    expect(long.length, maxReportErrorChars + 1);
    expect(long, endsWith('…'));
  });

  test('shortens a long error so the log still has room', () {
    Uri withError(String e) => problemReportUri(version: '1.1.3', os: 'macOS 26', error: e);
    final cjk = '找不到檔案：${'冬天我們不說再見' * 100}';
    final short = shortenToFit(cjk, withError);
    expect(short, endsWith('…'));
    expect(withError(short).toString().length, lessThanOrEqualTo(maxReportErrorUrlLength));
    expect(withError('${cjk.substring(0, short.length)}…').toString().length, greaterThan(maxReportErrorUrlLength));
    expect(shortenToFit('boom', withError), 'boom');
  });

  test('stays under the length GitHub accepts signed out, even for Chinese logs', () {
    Uri withError(String e) => problemReportUri(version: '1.1.3', os: 'macOS 26', error: e);
    final base = withError(shortenToFit('錯誤' * 2000, withError));
    final lines = [for (var i = 0; i < 500; i++) '12:00:00.000 E 無法開啟「冬天．我們不說再見」第 $i 行'];
    final r = fitReportLogs(base, lines, note: (n) => '（只附最後 $n 行）');
    expect(r.kept, greaterThan(0));
    final url = base.replace(queryParameters: {...base.queryParameters, 'logs': r.text}).toString();
    expect(url.length, lessThanOrEqualTo(maxReportUrlLength));
  });

  test('leaves unknown fields out', () {
    expect(problemReportUri(version: '', backend: null).queryParameters, {'template': 'bug_report.yml'});
  });
}
