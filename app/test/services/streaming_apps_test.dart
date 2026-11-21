import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/streaming_apps.dart';

void main() {
  test('OBS, Streamlabs and XSplit count; the OBS camera extension and others do not', () {
    for (final n in ['OBS', 'obs', 'obs64.exe', '"obs64.exe"', 'Streamlabs Desktop', 'Streamlabs OBS.exe', 'XSplit.Core.exe']) {
      expect(isStreamingApp(n), isTrue, reason: n);
    }
    for (final n in ['com.obsproject.obs-studio.mac-camera-extension', 'Finder', 'obsidian', 'jobs', 'karaoke_battle']) {
      expect(isStreamingApp(n), isFalse, reason: n);
    }
  });

  test('process names from ps and from tasklist CSV', () {
    expect(processNames('COMMAND\nFinder\nOBS\n').toList(), ['COMMAND', 'Finder', 'OBS']);
    final csv = '"System Idle Process","0","Services","0","8 K"\r\n"obs64.exe","4242","Console","1","300,000 K"\r\n';
    expect(processNames(csv).any(isStreamingApp), isTrue);
    expect(processNames('"explorer.exe","1","Console","1","1 K"').any(isStreamingApp), isFalse);
  });
}
