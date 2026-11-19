import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_mix.dart';
import 'package:karaoke_battle/services/sidecars.dart';

import '../ui/video_export_test.dart' show writeSine;

void main() {
  test('the replay balance keeps both at 0, fades one side out at the ends', () {
    expect(replayStemGains(0), (1.0, 1.0));
    final (m1, v1) = replayStemGains(1);
    expect(m1, closeTo(0, 1e-9));
    expect(v1, 1.0);
    final (m2, v2) = replayStemGains(-1);
    expect((m2, v2.abs() < 1e-9), (1.0, true));
    // Half way is -3 dB (equal power).
    final (half, _) = replayStemGains(0.5);
    expect(half, closeTo(math.sqrt1_2, 1e-9));
    expect(replayStemGains(5), replayStemGains(1), reason: 'clamped');
  });

  group('replay cache', () {
    late Directory tmp;
    late Sidecars sidecars;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('replay_mix');
      sidecars = Sidecars(AppPaths.forTest(tmp.path), SidecarCatalog({}));
    });
    tearDown(() => tmp.delete(recursive: true));

    test('is mixed again when the backing track changes', () async {
      if (await sidecars.resolve(SidecarKind.ffmpeg) == null) return markTestSkipped('ffmpeg not installed');
      final take = '${tmp.path}/take.wav', sep = '${tmp.path}/inst.wav', own = '${tmp.path}/inst.user.wav';
      writeSine(take, 330, 1);
      writeSine(sep, 220, 1);
      writeSine(own, 440, 1.2);
      Future<ReplayStems> stems(String backing) =>
          ensureReplayStems(sidecars, takeDir: tmp.path, voiceWav: take, backingWav: backing, offsetSeconds: 0);
      int len(String f) => File(f).lengthSync();

      final a = await stems(sep);
      final sepLen = len(a.backing);
      expect(await replayStemsCached(tmp.path, hasVoice: true, backingWav: sep), isTrue);
      // An imported backing track: the cache made from the separated one is stale.
      expect(await replayStemsCached(tmp.path, hasVoice: true, backingWav: own), isFalse);
      final b = await stems(own);
      expect(len(b.backing), greaterThan(sepLen), reason: 'rendered from the longer imported track');
      expect(await replayStemsCached(tmp.path, hasVoice: true, backingWav: own), isTrue);
      // Back to the separated accompaniment.
      await stems(sep);
      expect(len(a.backing), sepLen);
      // The same file written again (an imported track applied with a new offset).
      writeSine(own, 440, 1.5);
      File(own).setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
      expect(await replayStemsCached(tmp.path, hasVoice: true, backingWav: own), isFalse);
    });

    test('an old cache without its backing source is not reused', () async {
      final sep = '${tmp.path}/inst.wav';
      writeSine(sep, 220, 1);
      writeSine('${tmp.path}/replay_backing.wav', 220, 1);
      File('${tmp.path}/replay_stems.json').writeAsStringSync('{"v":1,"voice":false}');
      expect(await replayStemsCached(tmp.path, hasVoice: false, backingWav: sep), isFalse);
    });
  });
}
