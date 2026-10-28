// Application support directory layout.
//
//   <support>/models/<model-id>/...      downloaded ONNX models
//   <support>/sidecars/{yt-dlp,ffmpeg,deno}
//   <support>/cuda_pack/                  Windows only
//   <support>/songs/<song-id>/...         see docs/ARCHITECTURE.md
//   <support>/cache/                      temporary downloads
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  AppPaths._(this.root);
  final String root;

  static AppPaths? _instance;

  static Future<AppPaths> init() async {
    if (_instance != null) return _instance!;
    final override = Platform.environment['KE_APP_SUPPORT'];
    final dir = override != null && override.isNotEmpty
        ? Directory(override)
        : Directory(p.join((await getApplicationSupportDirectory()).path, 'KaraokeBattle'));
    await dir.create(recursive: true);
    final paths = AppPaths._(dir.path);
    for (final d in [paths.models, paths.sidecars, paths.songs, paths.cache, paths.cudaPack, paths.logs]) {
      await Directory(d).create(recursive: true);
    }
    _instance = paths;
    return paths;
  }

  static AppPaths get instance {
    final i = _instance;
    if (i == null) throw StateError('AppPaths.init() not called');
    return i;
  }

  String get models => p.join(root, 'models');
  String get sidecars => p.join(root, 'sidecars');
  String get songs => p.join(root, 'songs');
  String get cache => p.join(root, 'cache');
  String get cudaPack => p.join(root, 'cuda_pack');
  String get logs => p.join(root, 'logs');

  String modelDir(String modelId) => p.join(models, modelId);
  String songDir(String songId) => p.join(songs, songId);
}
