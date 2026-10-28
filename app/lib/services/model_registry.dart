// Registry of the ML models the app needs, all mirrored under
// https://huggingface.co/aaatmy/*. Files are verified with the sha256 values
// recorded in each repo's manifest.json (pinned here so a download is only
// accepted when it matches a known-good file).
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'downloader.dart';

class ModelFile {
  const ModelFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.repo,
    required this.title,
    required this.license,
    required this.files,
    this.params = const {},
  });
  final String id; // local directory name
  final String repo; // HF repo id
  final String title;
  final String license;
  final List<ModelFile> files;
  final Map<String, dynamic> params; // model specific (MDX STFT params etc.)

  int get totalBytes => files.fold(0, (a, f) => a + f.bytes);
  Uri fileUrl(String name) => Uri.parse('https://huggingface.co/$repo/resolve/main/$name');
}

class ModelRegistry {
  ModelRegistry._();

  static const swiftF0 = ModelSpec(
    id: 'swift-f0',
    repo: 'aaatmy/swift-f0-onnx',
    title: 'SwiftF0 0.3.0 (pitch)',
    license: 'MIT',
    files: [ModelFile('model.onnx', 135090, '6385e8c2ebc3872e82c9ff5946228de44cd3be77a750ea53698b7dbfe94b0a22')],
  );

  static const mdxVocals = ModelSpec(
    id: 'mdx-kim-vocal-2',
    repo: 'aaatmy/uvr-mdx-net-onnx',
    title: 'UVR MDX-Net Kim_Vocal_2 (vocals)',
    license: 'MIT (UVR)',
    files: [ModelFile('Kim_Vocal_2.onnx', 66759214, 'ce74ef3b6a6024ce44211a07be9cf8bc6d87728cc852a68ab34eb8e58cde9c8b')],
    params: {
      'n_fft': 7680,
      'hop_length': 1024,
      'dim_f': 3072,
      'dim_t_log2': 8,
      'compensate': 1.009,
      'primary_stem': 'Vocals',
    },
  );

  static const mdxInstrumental = ModelSpec(
    id: 'mdx-inst-hq-4',
    repo: 'aaatmy/uvr-mdx-net-onnx',
    title: 'UVR MDX-Net Inst_HQ_4 (instrumental)',
    license: 'MIT (UVR)',
    files: [
      ModelFile('UVR-MDX-NET-Inst_HQ_4.onnx', 59074342, '3c4b5b9b05090fdf238f38ba5046813982d50e2a652e9cb3324ea79720c3c9c8')
    ],
    params: {
      'n_fft': 5120,
      'hop_length': 1024,
      'dim_f': 2560,
      'dim_t_log2': 8,
      'compensate': 1.019,
      'primary_stem': 'Instrumental',
    },
  );

  static const gameLarge = ModelSpec(
    id: 'game-large',
    repo: 'aaatmy/game-large-onnx',
    title: 'GAME Large v1.0.3 (transcription)',
    license: 'CC BY-NC-SA 4.0',
    files: [
      ModelFile('encoder.onnx', 80398908, 'fbda7df8791d5cafd02ed33c65f9926c5514c750278c27fb8a59259b4c1d7464'),
      ModelFile('segmenter.onnx', 159935922, 'bf05ba683f47f605bc154519032bee0141d3630febccb40e9545ab4a92b28e66'),
      ModelFile('estimator.onnx', 153459702, '0d4a6e13bf475f79967e252b401bb5f317aa6b96bbe6665d5f8b14b42b179926'),
      ModelFile('dur2bd.onnx', 2632, '49d10d1ea186e43c51fd2c51cedb01a3852d363f1c7056ae77df50f7e8dd0996'),
      ModelFile('bd2dur.onnx', 4569, '6672d56b00f27a20e9bfaa92801c15e394bb520e49031d3ed2515b0a6cf27402'),
      ModelFile('config.json', 198, '4d62b6d058a820e981184ea6f04605d37659c4331ee01979eb14a14be08af890'),
    ],
  );

  static const gameSmall = ModelSpec(
    id: 'game-small',
    repo: 'aaatmy/game-small-onnx',
    title: 'GAME Small v1.0.3 (transcription, light)',
    license: 'CC BY-NC-SA 4.0',
    files: [
      ModelFile('encoder.onnx', 10805372, 'a6868a702d9c88ccc06b19e54f49d88b7f8cba4a68517f20806bd81ef6f94e06'),
      ModelFile('segmenter.onnx', 20906659, '7724db4ba59a388fff5aba2f08f0ac025d4ca59caef80e7f474053a1455c88e5'),
      ModelFile('estimator.onnx', 19335163, 'a84738b2504472a1f22773cc6b0eccad1353a8f36229ad490b8fea85388bb5e1'),
      ModelFile('dur2bd.onnx', 2632, '49d10d1ea186e43c51fd2c51cedb01a3852d363f1c7056ae77df50f7e8dd0996'),
      ModelFile('bd2dur.onnx', 4569, '6672d56b00f27a20e9bfaa92801c15e394bb520e49031d3ed2515b0a6cf27402'),
      ModelFile('config.json', 198, '60dfe7e7b57db29475604eeea9b2abf5f8cd2a49326f1f4bc0e1c14ed151a55e'),
    ],
  );

  static const all = [swiftF0, mdxVocals, mdxInstrumental, gameLarge, gameSmall];

  /// Models required for the default pipeline.
  static const required = [swiftF0, mdxVocals, mdxInstrumental, gameLarge];

  static ModelSpec byId(String id) => all.firstWhere((m) => m.id == id);
}

class ModelStore {
  ModelStore(this.paths, {Downloader? downloader}) : _dl = downloader ?? Downloader();
  final AppPaths paths;
  final Downloader _dl;

  String dirOf(ModelSpec m) => paths.modelDir(m.id);
  String pathOf(ModelSpec m, String file) => p.join(dirOf(m), file);

  /// Fast check: every file present with the expected size.
  Future<bool> isInstalled(ModelSpec m) async {
    for (final f in m.files) {
      final file = File(pathOf(m, f.name));
      if (!await file.exists()) return false;
      if (await file.length() != f.bytes) return false;
    }
    return true;
  }

  /// Full check with sha256 (slow for GAME large: ~400 MB).
  Future<bool> verify(ModelSpec m) async {
    for (final f in m.files) {
      final path = pathOf(m, f.name);
      if (!await File(path).exists()) return false;
      if (await Downloader.sha256OfFile(path) != f.sha256) return false;
    }
    return true;
  }

  /// Downloads missing/invalid files. Progress is cumulative bytes over the model.
  Future<void> install(
    ModelSpec m, {
    void Function(String file, DownloadProgress p, int doneBytes, int totalBytes)? onProgress,
    Future<void>? cancel,
  }) async {
    final total = m.totalBytes;
    var done = 0;
    for (final f in m.files) {
      final path = pathOf(m, f.name);
      if (await File(path).exists() && await File(path).length() == f.bytes) {
        done += f.bytes;
        continue;
      }
      await _dl.download(
        m.fileUrl(f.name),
        path,
        sha256: f.sha256,
        cancel: cancel,
        onProgress: (dp) => onProgress?.call(f.name, dp, done + dp.received, total),
      );
      done += f.bytes;
    }
  }

  Future<void> remove(ModelSpec m) async {
    final d = Directory(dirOf(m));
    if (await d.exists()) await d.delete(recursive: true);
  }
}
