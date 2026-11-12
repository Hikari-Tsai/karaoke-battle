// Whisper stops soon after a cancel, also in the middle of decoding a window
// (it used to finish the whole 30 s window first). Needs a Whisper model and
// a vocals WAV: KE_WHISPER_MODEL_DIR=... KE_WHISPER_WAV=... flutter test ...
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/engine/engine.dart';
import 'package:karaoke_battle/engine/engine_bindings.dart';

void main() {
  final modelDir = Platform.environment['KE_WHISPER_MODEL_DIR'];
  final wav = Platform.environment['KE_WHISPER_WAV'];
  final skip = modelDir == null || wav == null ? 'set KE_WHISPER_MODEL_DIR and KE_WHISPER_WAV' : null;

  test('a cancel during recognition stops Whisper within a few seconds', () async {
    final rt = Engine.instance.createRuntime(ortLibraryPath: EngineLocator.ortLibraryPath(), ep: KeEp.cpu);
    final out = '${Directory.systemTemp.createTempSync('ke-whisper-').path}/whisper.json';
    final job = rt.whisper(modelDir: modelDir!, inputWav: wav!, options: const {'task_token': 50360, 'language_token': 50260}, out: out);
    // Cancel once recognition is under way (after the model has loaded).
    final started = Stopwatch()..start();
    await job.progress.firstWhere((p) => p.stage == 'recognize');
    await Future<void>.delayed(const Duration(seconds: 2));
    final sw = Stopwatch()..start();
    job.cancel();
    await expectLater(job.done, throwsA(anything));
    // ignore: avoid_print
    print('recognising for ${started.elapsedMilliseconds} ms, stopped ${sw.elapsedMilliseconds} ms after the cancel');
    expect(sw.elapsedMilliseconds, lessThan(5000));
    expect(File(out).existsSync(), isFalse, reason: 'nothing written after a cancel');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}
