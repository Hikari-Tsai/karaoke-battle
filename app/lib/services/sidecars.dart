// External executables: yt-dlp, ffmpeg/ffprobe, deno (JS runtime for yt-dlp's YouTube extractor).
//
// Binaries live in <support>/sidecars (never inside the signed bundle so
// yt-dlp can self-update). A system binary on PATH is used when present
// (developer convenience, also lets users bring their own ffmpeg).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'downloader.dart';

enum SidecarKind { ytDlp, ffmpeg, ffprobe, deno }

class SidecarSource {
  const SidecarSource({required this.url, this.sha256, this.archiveMember, this.license = ''});
  final String url;
  final String? sha256;
  /// When the download is a zip/tar, the path of the executable inside it.
  final String? archiveMember;
  final String license;
}

/// Platform/arch keyed sources. Loaded from assets/sidecars.json when present
/// (kept in scripts/sidecars.json in the repo), with these defaults as fallback.
class SidecarCatalog {
  SidecarCatalog(this.sources);
  final Map<SidecarKind, Map<String, SidecarSource>> sources; // kind -> platformKey -> source

  static String get platformKey => platformKeys.first;

  /// Keys to try in order for this machine (scripts/sidecars.json naming).
  static List<String> get platformKeys {
    if (Platform.isMacOS) {
      return _arch() == 'arm64'
          ? ['macos-arm64', 'macos-aarch64', 'macos-universal2', 'macos-universal']
          : ['macos-x86_64', 'macos-x64', 'macos-universal2', 'macos-universal'];
    }
    if (Platform.isWindows) return ['win-x64', 'windows-x64'];
    return ['linux-x64'];
  }

  static String _arch() {
    final v = Platform.version.toLowerCase();
    if (v.contains('arm64') || v.contains('aarch64')) return 'arm64';
    return 'x64';
  }

  SidecarSource? sourceFor(SidecarKind kind) {
    final m = sources[kind];
    if (m == null) return null;
    for (final k in platformKeys) {
      final s = m[k];
      if (s != null) return s;
    }
    return m['any'];
  }

  static SidecarCatalog defaults() => SidecarCatalog({
        SidecarKind.ytDlp: {
          'macos-arm64': const SidecarSource(url: 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos', license: 'Unlicense'),
          'macos-x64': const SidecarSource(url: 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos', license: 'Unlicense'),
          'windows-x64': const SidecarSource(url: 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe', license: 'Unlicense'),
        },
        SidecarKind.deno: {
          'macos-arm64': const SidecarSource(url: 'https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip', archiveMember: 'deno', license: 'MIT'),
          'macos-x64': const SidecarSource(url: 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip', archiveMember: 'deno', license: 'MIT'),
          'windows-x64': const SidecarSource(url: 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip', archiveMember: 'deno.exe', license: 'MIT'),
        },
        // ffmpeg sources are filled from assets/sidecars.json (see scripts/sidecars.json);
        // without it we rely on a system ffmpeg.
        SidecarKind.ffmpeg: const {},
        SidecarKind.ffprobe: const {},
      });

  /// Parses scripts/sidecars.json (see that file for the layout):
  /// `"yt-dlp"/"deno": {"assets": {"<platform>": {url, sha256, extract?}}}` and
  /// `"ffmpeg": {"assets": {"<platform>": {"ffmpeg": {...}, "ffprobe": {...}} | {"archive": {...}}}}`.
  static SidecarCatalog fromJson(Map<String, dynamic> j) {
    final out = <SidecarKind, Map<String, SidecarSource>>{};
    SidecarSource? asset(Map<String, dynamic>? a, String license) {
      if (a == null || a['url'] is! String) return null;
      final extract = a['extract'];
      return SidecarSource(
        url: a['url'] as String,
        sha256: a['sha256'] as String?,
        archiveMember: extract is String ? extract : (a['archive_member'] as String?),
        license: license,
      );
    }

    for (final kind in [SidecarKind.ytDlp, SidecarKind.deno]) {
      final key = kind == SidecarKind.ytDlp ? 'yt-dlp' : 'deno';
      final sec = j[key];
      if (sec is! Map<String, dynamic>) continue;
      final license = '${sec['license'] ?? ''}';
      final assets = sec['assets'];
      if (assets is! Map<String, dynamic>) continue;
      out[kind] = {
        for (final e in assets.entries)
          if (asset(e.value as Map<String, dynamic>?, license) case final s?) e.key: s,
      };
    }
    final ff = j['ffmpeg'];
    if (ff is Map<String, dynamic> && ff['assets'] is Map<String, dynamic>) {
      final license = '${ff['license'] ?? ''}';
      final ffm = <String, SidecarSource>{};
      final ffp = <String, SidecarSource>{};
      for (final e in (ff['assets'] as Map<String, dynamic>).entries) {
        final a = e.value as Map<String, dynamic>;
        final lic = '${a['license'] ?? license}';
        if (a['archive'] is Map<String, dynamic>) {
          final ar = a['archive'] as Map<String, dynamic>;
          final extract = (ar['extract'] as Map<String, dynamic>?) ?? {};
          String? memberFor(String name) =>
              extract.entries.where((x) => '${x.value}'.toLowerCase().startsWith(name)).map((x) => x.key).firstOrNull;
          final m1 = memberFor('ffmpeg'), m2 = memberFor('ffprobe');
          if (m1 != null) ffm[e.key] = SidecarSource(url: ar['url'] as String, sha256: ar['sha256'] as String?, archiveMember: m1, license: lic);
          if (m2 != null) ffp[e.key] = SidecarSource(url: ar['url'] as String, sha256: ar['sha256'] as String?, archiveMember: m2, license: lic);
        } else {
          final s1 = asset(a['ffmpeg'] as Map<String, dynamic>?, lic);
          final s2 = asset(a['ffprobe'] as Map<String, dynamic>?, lic);
          if (s1 != null) ffm[e.key] = s1;
          if (s2 != null) ffp[e.key] = s2;
        }
      }
      out[SidecarKind.ffmpeg] = ffm;
      out[SidecarKind.ffprobe] = ffp;
    }
    final d = defaults();
    for (final kind in SidecarKind.values) {
      out.putIfAbsent(kind, () => d.sources[kind] ?? {});
    }
    return SidecarCatalog(out);
  }
}

class Sidecars {
  Sidecars(this.paths, this.catalog, {Downloader? downloader}) : _dl = downloader ?? Downloader();
  final AppPaths paths;
  final SidecarCatalog catalog;
  final Downloader _dl;

  String _exeName(SidecarKind k) {
    final base = switch (k) {
      SidecarKind.ytDlp => 'yt-dlp',
      SidecarKind.ffmpeg => 'ffmpeg',
      SidecarKind.ffprobe => 'ffprobe',
      SidecarKind.deno => 'deno',
    };
    return Platform.isWindows ? '$base.exe' : base;
  }

  String managedPath(SidecarKind k) => p.join(paths.sidecars, _exeName(k));

  /// Returns the executable to use: managed copy first, then PATH lookup, else null.
  Future<String?> resolve(SidecarKind k) async {
    final managed = managedPath(k);
    if (await File(managed).exists()) return managed;
    return _which(_exeName(k));
  }

  Future<String?> _which(String name) async {
    final cmd = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(cmd, [name], environment: _env());
      if (r.exitCode == 0) {
        final line = (r.stdout as String).split('\n').map((s) => s.trim()).firstWhere((s) => s.isNotEmpty, orElse: () => '');
        if (line.isNotEmpty) return line;
      }
    } catch (_) {}
    // Common Homebrew locations are not on PATH for GUI apps on macOS.
    if (Platform.isMacOS) {
      for (final d in ['/opt/homebrew/bin', '/usr/local/bin']) {
        final f = p.join(d, name);
        if (await File(f).exists()) return f;
      }
    }
    return null;
  }

  Map<String, String> _env() {
    final env = Map<String, String>.from(Platform.environment);
    final extra = [paths.sidecars, if (Platform.isMacOS) '/opt/homebrew/bin', if (Platform.isMacOS) '/usr/local/bin'];
    final sep = Platform.isWindows ? ';' : ':';
    env['PATH'] = [...extra, env['PATH'] ?? ''].join(sep);
    return env;
  }

  Future<bool> isAvailable(SidecarKind k) async => (await resolve(k)) != null;

  /// Downloads the managed copy of [k] (no-op if already present).
  Future<String> install(SidecarKind k, {void Function(DownloadProgress)? onProgress}) async {
    final dest = managedPath(k);
    if (await File(dest).exists()) return dest;
    final src = catalog.sourceFor(k);
    if (src == null) throw StateError('no download source for ${k.name} on ${SidecarCatalog.platformKey}');
    if (src.archiveMember == null) {
      await _dl.download(Uri.parse(src.url), dest, sha256: src.sha256, onProgress: onProgress);
    } else {
      final tmp = p.join(paths.cache, p.basename(Uri.parse(src.url).path));
      await _dl.download(Uri.parse(src.url), tmp, sha256: src.sha256, onProgress: onProgress);
      await _extractMember(tmp, src.archiveMember!, dest);
      await File(tmp).delete();
    }
    await _makeExecutable(dest);
    return dest;
  }

  Future<void> _extractMember(String archive, String member, String dest) async {
    // Use the platform's own tools to avoid pulling a tar implementation in.
    if (archive.endsWith('.zip')) {
      final tmpDir = await Directory(paths.cache).createTemp('unzip');
      final r = Platform.isWindows
          ? await Process.run('powershell', ['-NoProfile', '-Command', 'Expand-Archive -Force -Path "$archive" -DestinationPath "${tmpDir.path}"'])
          : await Process.run('unzip', ['-o', '-q', archive, '-d', tmpDir.path]);
      if (r.exitCode != 0) throw StateError('unzip failed: ${r.stderr}');
      final found = await _find(tmpDir, p.basename(member));
      if (found == null) throw StateError('$member not found in $archive');
      await File(found).copy(dest);
      await tmpDir.delete(recursive: true);
    } else {
      final tmpDir = await Directory(paths.cache).createTemp('untar');
      final r = await Process.run('tar', ['-xf', archive, '-C', tmpDir.path]);
      if (r.exitCode != 0) throw StateError('tar failed: ${r.stderr}');
      final found = await _find(tmpDir, p.basename(member));
      if (found == null) throw StateError('$member not found in $archive');
      await File(found).copy(dest);
      await tmpDir.delete(recursive: true);
    }
  }

  Future<String?> _find(Directory dir, String name) async {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path) == name) return e.path;
    }
    return null;
  }

  Future<void> _makeExecutable(String path) async {
    if (Platform.isWindows) return;
    await Process.run('chmod', ['+x', path]);
    if (Platform.isMacOS) await Process.run('xattr', ['-d', 'com.apple.quarantine', path]);
  }

  /// `yt-dlp -U` (only the managed copy can update itself).
  Future<String> updateYtDlp() async {
    final exe = managedPath(SidecarKind.ytDlp);
    if (!await File(exe).exists()) return 'yt-dlp is not managed by the app';
    final r = await Process.run(exe, ['-U'], environment: _env());
    return '${r.stdout}${r.stderr}'.trim();
  }

  // ---- running --------------------------------------------------------------

  /// Runs a process, streaming stderr/stdout lines to [onLine]. Returns exit code.
  Future<int> run(String exe, List<String> args, {void Function(String line)? onLine, Future<void>? cancel, String? workingDir, Map<String, String>? env}) async {
    final proc = await Process.start(exe, args, environment: {..._env(), ...?env}, workingDirectory: workingDir, runInShell: false);
    cancel?.then((_) => proc.kill());
    final done = Completer<void>();
    var open = 2;
    void closeOne() {
      if (--open == 0) done.complete();
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l), onDone: closeOne);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l), onDone: closeOne);
    await done.future;
    return proc.exitCode;
  }

  static final _ytProgress = RegExp(r'\[download\]\s+([\d.]+)%');

  /// Downloads a YouTube (or any yt-dlp supported) URL as an mp4 with the best
  /// audio, into [outDir]. Returns the output file path. Progress 0..1.
  Future<String> downloadVideo(String url, String outDir, {void Function(double, String)? onProgress, Future<void>? cancel}) async {
    final yt = await resolve(SidecarKind.ytDlp);
    if (yt == null) throw StateError('yt-dlp not available');
    final ffmpeg = await resolve(SidecarKind.ffmpeg);
    final deno = await resolve(SidecarKind.deno);
    final outTemplate = p.join(outDir, 'source.%(ext)s');
    final args = <String>[
      '--no-playlist',
      '--newline',
      '-f', 'bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best',
      '--merge-output-format', 'mp4',
      '-o', outTemplate,
      '--print', 'after_move:filepath',
      if (ffmpeg != null) ...['--ffmpeg-location', p.dirname(ffmpeg)],
      if (deno != null) ...['--js-runtimes', 'deno:$deno'],
      url,
    ];
    String? outPath;
    final code = await run(yt, args, cancel: cancel, onLine: (l) {
      final m = _ytProgress.firstMatch(l);
      if (m != null) onProgress?.call(double.parse(m.group(1)!) / 100.0, l.trim());
      if (l.startsWith(outDir) && (l.endsWith('.mp4') || l.endsWith('.mkv') || l.endsWith('.webm'))) outPath = l.trim();
      if (l.contains('ERROR')) onProgress?.call(-1, l.trim());
    });
    if (code != 0) throw StateError('yt-dlp exited with $code');
    outPath ??= await _find(Directory(outDir), 'source.mp4');
    if (outPath == null) throw StateError('yt-dlp produced no file');
    return outPath!;
  }

  /// yt-dlp metadata (title, duration, id) without downloading.
  Future<Map<String, dynamic>> probeUrl(String url) async {
    final yt = await resolve(SidecarKind.ytDlp);
    if (yt == null) throw StateError('yt-dlp not available');
    final deno = await resolve(SidecarKind.deno);
    final r = await Process.run(yt, ['--no-playlist', '-J', if (deno != null) ...['--js-runtimes', 'deno:$deno'], url], environment: _env());
    if (r.exitCode != 0) throw StateError('yt-dlp -J failed: ${r.stderr}');
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  }

  /// Subtitle track keys (uploader-provided and automatic) for a URL.
  Future<({List<String> manual, List<String> auto})> subtitleTracks(String url) async {
    final info = await probeUrl(url);
    List<String> keys(Object? m) => m is Map ? [for (final k in m.keys) '$k'] : <String>[];
    return (manual: keys(info['subtitles']), auto: keys(info['automatic_captions']));
  }

  /// Downloads the given subtitle tracks as WebVTT into [outDir] as
  /// `subs.<key>.vtt`. [auto] selects automatic captions.
  Future<void> downloadSubtitles(String url, String outDir, List<String> keys, {required bool auto, Future<void>? cancel}) async {
    if (keys.isEmpty) return;
    final yt = await resolve(SidecarKind.ytDlp);
    if (yt == null) throw StateError('yt-dlp not available');
    final deno = await resolve(SidecarKind.deno);
    final code = await run(yt, [
      '--no-playlist',
      '--skip-download',
      auto ? '--write-auto-subs' : '--write-subs',
      '--sub-langs', keys.join(','),
      '--sub-format', 'vtt',
      '-o', p.join(outDir, 'subs.%(ext)s'),
      if (deno != null) ...['--js-runtimes', 'deno:$deno'],
      url,
    ], cancel: cancel);
    if (code != 0) throw StateError('yt-dlp subtitles exited with $code');
  }

  /// Runs the Japanese reading script of the extracted pack at [packDir] on
  /// [inJson] (a JSON array of lines), writing token lists to [outJson].
  /// Offline: Deno resolves kuromoji from the pack's node_modules only.
  Future<void> readJapanese(String packDir, String inJson, String outJson, {Future<void>? cancel}) async {
    final deno = await resolve(SidecarKind.deno);
    if (deno == null) throw StateError('deno not available');
    final lines = <String>[];
    final code = await run(
      deno,
      [
        'run',
        '--cached-only',
        '--no-prompt',
        '--config', p.join(packDir, 'deno.json'),
        '--allow-read=$packDir,$inJson',
        '--allow-write=$outJson',
        p.join(packDir, 'ja_reading.ts'),
        inJson,
        outJson,
      ],
      cancel: cancel,
      env: {'DENO_DIR': p.join(paths.cache, 'deno'), 'NO_COLOR': '1'},
      onLine: lines.add,
    );
    if (code != 0) throw StateError('ja_reading exited with $code: ${lines.take(5).join(' | ')}');
  }

  static final _ffTime = RegExp(r'time=(\d+):(\d+):([\d.]+)');
  static final _ffDuration = RegExp(r'Duration: (\d+):(\d+):([\d.]+)');

  /// Media duration in seconds via ffprobe (or ffmpeg -i fallback).
  Future<double?> duration(String input) async {
    final probe = await resolve(SidecarKind.ffprobe);
    if (probe != null) {
      final r = await Process.run(probe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', input], environment: _env());
      final v = double.tryParse((r.stdout as String).trim());
      if (v != null) return v;
    }
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) return null;
    final r = await Process.run(ff, ['-i', input], environment: _env());
    final m = _ffDuration.firstMatch('${r.stderr}');
    if (m == null) return null;
    return int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + double.parse(m.group(3)!);
  }

  /// Does [input] contain a video stream?
  Future<bool> hasVideo(String input) async {
    final probe = await resolve(SidecarKind.ffprobe);
    if (probe != null) {
      final r = await Process.run(probe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', input], environment: _env());
      return (r.stdout as String).trim().startsWith('video');
    }
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) return false;
    final r = await Process.run(ff, ['-i', input], environment: _env());
    return '${r.stderr}'.contains('Video:');
  }

  /// Decodes any media file to a 44.1 kHz stereo 32-bit float WAV.
  Future<void> toWav(String input, String outputWav, {int sampleRate = 44100, int channels = 2, void Function(double)? onProgress, Future<void>? cancel}) async {
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    final total = await duration(input) ?? 0;
    final code = await run(ff, ['-y', '-hide_banner', '-nostdin', '-i', input, '-vn', '-ac', '$channels', '-ar', '$sampleRate', '-c:a', 'pcm_f32le', outputWav], cancel: cancel, onLine: (l) {
      final m = _ffTime.firstMatch(l);
      if (m != null && total > 0) {
        final t = int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + double.parse(m.group(3)!);
        onProgress?.call((t / total).clamp(0, 1));
      }
    });
    if (code != 0) throw StateError('ffmpeg exited with $code');
  }

  /// Grabs one video frame at [atSeconds] as a JPEG, [width] px wide.
  Future<void> extractFrame(String input, String outputJpg, {double atSeconds = 5, int width = 640}) async {
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    final code = await run(ff, ['-y', '-hide_banner', '-nostdin', '-ss', atSeconds.toStringAsFixed(2), '-i', input, '-frames:v', '1', '-vf', 'scale=$width:-2', '-q:v', '3', outputJpg]);
    if (code != 0) throw StateError('ffmpeg frame grab exited with $code');
  }

  /// Produces a video-only mp4 (no audio) for the muted video player, re-muxing
  /// when the codec is already H.264, otherwise transcoding.
  Future<void> toVideoOnlyMp4(String input, String outputMp4, {Future<void>? cancel, void Function(String)? onLine}) async {
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    var code = await run(ff, ['-y', '-hide_banner', '-nostdin', '-i', input, '-an', '-c:v', 'copy', '-movflags', '+faststart', outputMp4], cancel: cancel, onLine: onLine);
    if (code != 0) {
      code = await run(ff, ['-y', '-hide_banner', '-nostdin', '-i', input, '-an', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', outputMp4], cancel: cancel, onLine: onLine);
    }
    if (code != 0) throw StateError('ffmpeg video export exited with $code');
  }
}
