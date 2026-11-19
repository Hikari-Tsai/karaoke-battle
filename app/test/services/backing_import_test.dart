import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/backing_import.dart';
import 'package:karaoke_battle/services/song_library.dart';

void main() {
  test('reads the engine result', () {
    final a = BackingAlignment.fromJson({
      'verdict': 'aligned',
      'delay': -0.722563,
      'confidence': 0.818,
      'gain': -0.22,
      'key_shift': 2,
      'key_margin': 0.05,
      'band_spread_ms': 7.03,
      'band_warning': true,
    });
    expect(a.aligned, isTrue);
    expect(a.delay, closeTo(-0.722563, 1e-9));
    expect(a.gain, -0.22);
    expect(a.keyChanged, isFalse, reason: 'margin too small to trust the key');
    expect(a.bandWarning, isTrue);
    final m = BackingAlignment.fromJson({'verdict': 'mismatch', 'key_shift': -2, 'key_margin': 0.3});
    expect(m.aligned, isFalse);
    expect(m.keyChanged, isTrue);
    expect(BackingAlignment.fromJson({}).verdict, 'mismatch');
  });

  test('the shift filter pads or cuts whole samples at 44.1 kHz', () {
    expect(BackingImport.shiftFilter(0), 'anull');
    expect(BackingImport.shiftFilter(1), 'adelay=delays=44100S:all=1');
    expect(BackingImport.shiftFilter(-0.722563), 'atrim=start_sample=31865,asetpts=PTS-STARTPTS');
  });

  test('an imported backing stands in for the separated one while it exists', () {
    final dir = Directory.systemTemp.createTempSync('ke-backing-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = SongFiles(dir.path);
    expect(f.hasUserInst, isFalse);
    expect(f.backingWav, f.instWav);
    File(f.userInstWav).writeAsBytesSync([0]);
    expect(f.hasUserInst, isTrue);
    expect(f.backingWav, f.userInstWav);
  });

  test('envelope: silence is 0, full scale near 1, one value per hop', () {
    final x = Float32List(800);
    for (var i = 400; i < 800; i++) {
      x[i] = i.isEven ? 1 : -1;
    }
    final e = BackingImport.rmsEnvelope(x, 80);
    expect(e.length, 10);
    expect(e.first, 0);
    expect(e.last, closeTo(1, 1e-6));
  });
}
