// Registry of the ML models the app needs, all mirrored under
// https://huggingface.co/aaatmy/*. Files are verified with the sha256 values
// recorded in each repo's manifest.json (pinned here so a download is only
// accepted when it matches a known-good file).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

  /// Japanese reading pack (kuromoji + IPADIC, run with Deno) for romaji
  /// under Japanese lyrics. Optional: downloaded the first time it is needed.
  static const jaReading = ModelSpec(
    id: 'ja-reading',
    repo: 'aaatmy/kuromoji-ipadic-pack',
    title: 'kuromoji + IPADIC (Japanese readings)',
    license: 'Apache-2.0 / NAIST-IPADIC',
    files: [ModelFile('kuromoji-pack.zip', 17427711, '925ac6d9030adc03b053afada160d25b06cf59f2f152599a70d82f40383ddc26')],
  );

  /// Beat This! (CPJKU) beat / downbeat tracker for BPM, beat grid and metronome.
  static const beatThis = ModelSpec(
    id: 'beat-this',
    repo: 'aaatmy/beat-this-onnx',
    title: 'Beat This! final0 (beats / tempo)',
    license: 'MIT',
    files: [
      ModelFile('beat-this-final0.onnx', 82098846, 'e5e37b7d1802895e42559c5a1ced7619b1601d257a5c8e167c9d45de37c1b078'),
      ModelFile('frontend.json', 298186, '7b2ba71db92b79cb33f45feb21854161de329b86a7e6ea686c3fec51ce85eb9f'),
    ],
  );

  /// Whisper large-v3 (OpenAI) for recognising lyrics and timing pasted
  /// lyrics. Optional, downloaded on first use. Windows gets the float32
  /// build so the whole model runs on CUDA / DirectML (the int8 build's
  /// quantized ops fall back to the CPU there); macOS runs on the CPU, where
  /// the int8 build of the same model is about 4x faster (see [whisperLarge]).
  static const whisperLargeF32 = ModelSpec(
    id: 'whisper-large-v3',
    repo: 'aaatmy/whisper-large-v3-onnx',
    title: 'Whisper large-v3 (lyrics recognition)',
    license: 'Apache-2.0',
    files: [
      ModelFile('onnx/encoder_model.onnx', 412412, '484baaed2f03c4e521650eba3f5228bd59728cbc18edb5aa1c5223a6b94ca491'),
      ModelFile('onnx/encoder_model.onnx_data', 2547875840, '8983477ea590e9a4f5f755b5117a8d7f952da3dc28e993dea0594d7693d411da'),
      ModelFile('onnx/decoder_model_merged.onnx', 2305652, '31c3d7df27dad36be97dc6f5396ae96fdc9eafa51f7a6de816beb2ce71757bad'),
      ModelFile('onnx/decoder_model_merged.onnx_data', 3626086400, '69700fe5f05cae25e834e9f226e678aebbc18af13c5526ad81829489c357515d'),
      ModelFile('config.json', 1288, 'a306bdf86d5f79595082755649214d8ba2b4e2cb2a7c124c6325c3acb7abf303'),
      ModelFile('generation_config.json', 3896, '33ff6901e35fd6ff9d7ac219a7c88118d383dac59f4a48c1bca46b86a11e20c9'),
      ModelFile('preprocessor_config.json', 340, '7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711'),
      ModelFile('vocab.json', 1036558, 'e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387'),
      ModelFile('added_tokens.json', 34648, '3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0'),
      ModelFile('tokenizer.json', 3930645, '5c1bf30c9e716e1477bedef846b01be0013daecb89e9e3ef7ab89b23c178df1b'),
    ],
  );

  /// The int8 (dynamically quantized) build of the same model, for CPUs.
  static const whisperLargeInt8 = ModelSpec(
    id: 'whisper-large-v3-int8',
    repo: 'aaatmy/whisper-large-v3-onnx',
    title: 'Whisper large-v3 int8 (lyrics recognition)',
    license: 'Apache-2.0',
    files: [
      ModelFile('onnx/encoder_model_quantized.onnx', 644795348, 'f438cff17ce55089f5046c7392421ec646cdf3081098a6510558578321a15c3f'),
      ModelFile('onnx/decoder_model_merged_quantized.onnx', 1177130831, 'f0d0fd460448a18ef7835d2ba53fe40aeca244d18715e46fae68f149fb22e2d6'),
      ModelFile('generation_config.json', 3896, '33ff6901e35fd6ff9d7ac219a7c88118d383dac59f4a48c1bca46b86a11e20c9'),
      ModelFile('vocab.json', 1036558, 'e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387'),
      ModelFile('added_tokens.json', 34648, '3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0'),
      ModelFile('tokenizer.json', 3930645, '5c1bf30c9e716e1477bedef846b01be0013daecb89e9e3ef7ab89b23c178df1b'),
    ],
  );

  /// The Whisper build for this platform.
  static ModelSpec get whisperLarge => Platform.isMacOS ? whisperLargeInt8 : whisperLargeF32;

  static final all = [swiftF0, mdxVocals, mdxInstrumental, gameLarge, gameSmall, beatThis, jaReading, whisperLarge];

  /// Models required for the default pipeline.
  static const required = [swiftF0, mdxVocals, mdxInstrumental, gameLarge, beatThis];

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

  /// Full check (sha256) that skips files unchanged since they last passed.
  /// Files that fail are deleted so [install] downloads them again.
  Future<bool> verifyCached(ModelSpec m, {void Function(String file)? onFile}) =>
      verifyDir(dirOf(m), m.files, onFile: onFile);

  /// [verifyCached] for the files of one model directory. Passing files are
  /// remembered in `.verified.json` by size and modification time; only new
  /// or changed files are hashed (in an isolate).
  static Future<bool> verifyDir(String dir, List<ModelFile> files, {void Function(String file)? onFile}) async {
    final stampFile = File(p.join(dir, '.verified.json'));
    var stamp = <String, dynamic>{};
    try {
      stamp = (jsonDecode(await stampFile.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {}
    final next = <String, dynamic>{};
    var ok = true;
    for (final f in files) {
      final file = File(p.join(dir, f.name));
      if (!await file.exists() || await file.length() != f.bytes) {
        ok = false;
        continue;
      }
      final mtime = (await file.lastModified()).millisecondsSinceEpoch;
      final prev = stamp[f.name];
      if (prev is Map && prev['bytes'] == f.bytes && prev['mtime'] == mtime && prev['sha256'] == f.sha256) {
        next[f.name] = prev;
        continue;
      }
      onFile?.call(f.name);
      final path = file.path;
      final sha = await Isolate.run(() => Downloader.sha256OfFile(path));
      if (sha == f.sha256) {
        next[f.name] = {'bytes': f.bytes, 'mtime': mtime, 'sha256': f.sha256};
      } else {
        ok = false;
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    try {
      if (await Directory(dir).exists()) await stampFile.writeAsString(jsonEncode(next));
    } catch (_) {}
    return ok;
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
