// External executables: yt-dlp, ffmpeg/ffprobe, deno (JS runtime for yt-dlp's YouTube extractor).
//
// Binaries live in <support>/sidecars (never inside the signed bundle so
// yt-dlp can self-update). A system binary on PATH is used when present
// (developer convenience, also lets users bring their own ffmpeg).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/i18n.dart';
import '../state/loudness.dart';
import 'app_paths.dart';
import 'downloader.dart';

enum SidecarKind { ytDlp, ffmpeg, ffprobe, deno }

/// What the launch check found about yt-dlp.
enum YtDlpHealth {
  /// The app's own copy runs.
  ok,

  /// No yt-dlp at all.
  missing,

  /// Only one from PATH (winget, scoop, pip, Homebrew), which the app can't update.
  pathOnly,

  /// The app's own copy is there but does not run.
  broken,
}

class SidecarSource {
  const SidecarSource({
    required this.url,
    this.sha256,
    this.sha256Url,
    this.sha256Suffix,
    this.archiveMember,
    this.license = '',
    this.fallbacks = const [],
  });
  final String url;

  /// Pinned hash of the file at [url].
  final String? sha256;

  /// For a link that follows new versions ("latest"): the publisher's
  /// checksum list, read at install time; the line for this file's name is
  /// used.
  final String? sha256Url;

  /// Like [sha256Url], but the checksum sits next to the file the link
  /// redirects to (this suffix appended to the final URL, e.g. ".sha256").
  final String? sha256Suffix;

  /// When the download is a zip/tar, the path of the executable inside it.
  final String? archiveMember;
  final String license;

  /// Tried in order when [url] fails (a deleted release, a bad hash). Each
  /// one must be verifiable: a pinned hash or a publisher checksum.
  final List<SidecarSource> fallbacks;

  bool get verifiable => sha256 != null || sha256Url != null || sha256Suffix != null;
}

/// The hash for [fileName] in a checksum list (`<hash>  <name>` lines, as
/// sha256sum writes them; or PowerShell Get-FileHash output, `Hash : <hash>`
/// followed by `Path : <path>`), or the hash of a file holding just one
/// bare hash.
String? checksumFor(String text, String fileName) {
  for (final m in RegExp(r'Hash\s*:\s*([0-9A-Fa-f]{64})\s*[\r\n]+\s*Path\s*:\s*(\S[^\r\n]*)').allMatches(text)) {
    if (m.group(2)!.trim().split(RegExp(r'[\\/]')).last == fileName) return m.group(1)!.toLowerCase();
  }
  final bare = <String>[];
  var lines = 0;
  for (final raw in const LineSplitter().convert(text)) {
    if (raw.trim().isEmpty) continue;
    lines++;
    final m = RegExp(r'^([0-9a-fA-F]{64})(?:\s+\*?(.+))?$').firstMatch(raw.trim());
    if (m == null) continue;
    final hash = m.group(1)!.toLowerCase();
    final name = m.group(2)?.trim();
    if (name == null) {
      bare.add(hash);
    } else if (p.basename(name) == fileName) {
      return hash;
    }
  }
  return lines == 1 && bare.length == 1 ? bare.single : null;
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
  ///
  /// Each source may list `"fallbacks": [{url, sha256 | sha256_url |
  /// sha256_suffix, extract?}]`, tried when the pinned link fails. Only
  /// https links are used. With [withDefaults] false, kinds missing from
  /// the JSON stay missing (for the online copy, which only overrides).
  static SidecarCatalog fromJson(Map<String, dynamic> j, {bool withDefaults = true}) {
    final out = <SidecarKind, Map<String, SidecarSource>>{};
    bool https(Object? u) => u is String && u.startsWith('https://');
    List<SidecarSource> fallbacksOf(Map<String, dynamic> a, String? member, String license) => [
          for (final f in (a['fallbacks'] is List ? a['fallbacks'] as List : const []))
            if (f is Map<String, dynamic> && https(f['url']))
              if (SidecarSource(
                url: f['url'] as String,
                sha256: f['sha256'] as String?,
                sha256Url: https(f['sha256_url']) ? f['sha256_url'] as String : null,
                sha256Suffix: f['sha256_suffix'] as String?,
                archiveMember: f['extract'] is String ? f['extract'] as String : member,
                license: license,
              ) case final s when s.verifiable)
                s,
        ];
    SidecarSource? asset(Map<String, dynamic>? a, String license) {
      if (a == null || !https(a['url'])) return null;
      final extract = a['extract'];
      final member = extract is String ? extract : (a['archive_member'] as String?);
      return SidecarSource(
        url: a['url'] as String,
        sha256: a['sha256'] as String?,
        archiveMember: member,
        license: license,
        fallbacks: fallbacksOf(a, member, license),
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
          if (!https(ar['url'])) continue;
          SidecarSource src(String member) => SidecarSource(
                url: ar['url'] as String,
                sha256: ar['sha256'] as String?,
                archiveMember: member,
                license: lic,
                fallbacks: fallbacksOf(ar, member, lic),
              );
          if (m1 != null) ffm[e.key] = src(m1);
          if (m2 != null) ffp[e.key] = src(m2);
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
    if (!withDefaults) return SidecarCatalog(out);
    final d = defaults();
    for (final kind in SidecarKind.values) {
      out.putIfAbsent(kind, () => d.sources[kind] ?? {});
    }
    return SidecarCatalog(out);
  }
}

class Sidecars {
  Sidecars(this.paths, this.catalog, {Downloader? downloader, this.onlineManifest}) : _dl = downloader ?? Downloader();
  final AppPaths paths;
  final SidecarCatalog catalog;
  final Downloader _dl;

  /// The repo's current sidecars.json. Read before an install so a dead
  /// download link can be fixed by updating that file, without a new app
  /// release; the bundled catalog is used when it can't be read.
  final Uri? onlineManifest;
  Future<SidecarCatalog?>? _online;

  static final defaultOnlineManifest = Uri.parse('https://raw.githubusercontent.com/Hikari-Tsai/karaoke-battle/main/app/assets/sidecars.json');

  Future<SidecarCatalog?> _loadOnline() async {
    final url = onlineManifest;
    if (url == null) return null;
    try {
      final text = await _dl.fetchText(url, timeout: const Duration(seconds: 8));
      return SidecarCatalog.fromJson(jsonDecode(text) as Map<String, dynamic>, withDefaults: false);
    } catch (_) {
      return null;
    }
  }

  /// Where to download [k] from: the online catalog when it has an entry,
  /// else the bundled one. A failed read is retried on the next install.
  Future<SidecarSource?> sourceFor(SidecarKind k) async {
    final online = await (_online ??= _loadOnline());
    if (online == null) _online = null;
    return online?.sourceFor(k) ?? catalog.sourceFor(k);
  }

  /// Installs in flight, so the settings button, the setup rows and the
  /// download retry share one download instead of racing on the same file.
  final Map<SidecarKind, Future<String>> _installs = {};

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

  /// Downloads the managed copy of [k] (no-op if already present). A call
  /// while one is already downloading waits for that one; only the first
  /// caller's [onProgress] is called.
  Future<String> install(SidecarKind k, {void Function(DownloadProgress)? onProgress}) {
    final running = _installs[k];
    if (running != null) return running;
    final job = _install(k, onProgress: onProgress);
    _installs[k] = job;
    return job.whenComplete(() => _installs.remove(k));
  }

  Future<String> _install(SidecarKind k, {void Function(DownloadProgress)? onProgress}) async {
    final dest = managedPath(k);
    if (await File(dest).exists()) return dest;
    final src = await sourceFor(k);
    if (src == null) throw StateError('no download source for ${k.name} on ${SidecarCatalog.platformKey}');
    // The pinned link first, then the fallbacks (links that follow new
    // versions, checked against the publisher's checksums).
    final errors = <Object>[];
    for (final s in [src, ...src.fallbacks]) {
      try {
        await _installFrom(s, dest, onProgress);
        await _makeExecutable(dest);
        return dest;
      } catch (e) {
        errors.add(e);
      }
    }
    if (errors.length == 1) throw errors.single;
    throw DownloadException([
      '${errors.first}'.replaceFirst('DownloadException: ', ''),
      for (final e in errors.skip(1)) '${tr('sidecars.fallbackFailed')}: ${'$e'.replaceFirst('DownloadException: ', '')}',
    ].join('\n'));
  }

  Future<void> _installFrom(SidecarSource s, String dest, void Function(DownloadProgress)? onProgress) async {
    var url = Uri.parse(s.url);
    var sha = s.sha256;
    if (sha == null && (s.sha256Url != null || s.sha256Suffix != null)) {
      final name = p.basename(url.path);
      Uri sums;
      if (s.sha256Suffix != null) {
        // Download the very file the checksum belongs to, not whatever the
        // link points at a moment later.
        url = await _dl.resolve(url);
        sums = Uri.parse('$url${s.sha256Suffix}');
      } else {
        sums = Uri.parse(s.sha256Url!);
      }
      sha = checksumFor(await _dl.fetchText(sums), name);
      if (sha == null) throw DownloadException('no checksum for $name in $sums');
    }
    if (s.archiveMember == null) {
      await _dl.download(url, dest, sha256: sha, onProgress: onProgress);
    } else {
      final tmp = p.join(paths.cache, p.basename(url.path));
      await _dl.download(url, tmp, sha256: sha, onProgress: onProgress);
      await _extractMember(tmp, s.archiveMember!, dest);
      await File(tmp).delete();
    }
  }

  Future<void> _extractMember(String archive, String member, String dest) async {
    await Directory(p.dirname(dest)).create(recursive: true);
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

  /// Runs `yt-dlp -U` on the app's own copy. A yt-dlp found on PATH (winget,
  /// scoop, pip, Homebrew) belongs to its package manager and is left alone;
  /// when the managed copy is missing it is installed from the catalog first,
  /// and [resolve] prefers it from then on. [installed] says that happened;
  /// [ok] is false when `-U` itself failed.
  Future<({bool installed, bool ok, String output})> updateYtDlp({void Function(DownloadProgress)? onProgress}) async {
    final exe = managedPath(SidecarKind.ytDlp);
    final installed = !await File(exe).exists();
    if (installed) await install(SidecarKind.ytDlp, onProgress: onProgress);
    final r = await Process.run(exe, ['-U'], environment: _env());
    return (installed: installed, ok: r.exitCode == 0, output: '${r.stdout}${r.stderr}'.trim());
  }

  /// Launch check: does the app's own yt-dlp run, and if there is none, is
  /// there one on PATH? Also clears a `.part` left by an interrupted install.
  Future<({YtDlpHealth health, String detail})> checkYtDlp() async {
    const k = SidecarKind.ytDlp;
    final managed = managedPath(k);
    if (!_installs.containsKey(k)) {
      final part = File('$managed.part');
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    if (await File(managed).exists()) {
      try {
        final r = await Process.run(managed, ['--version'], environment: _env()).timeout(const Duration(minutes: 1));
        if (r.exitCode == 0) return (health: YtDlpHealth.ok, detail: '${r.stdout}'.trim());
        final out = '${r.stdout}${r.stderr}'.trim();
        return (health: YtDlpHealth.broken, detail: out.isEmpty ? 'exit code ${r.exitCode}' : out);
      } catch (e) {
        return (health: YtDlpHealth.broken, detail: '$e');
      }
    }
    final other = await resolve(k);
    return other == null ? (health: YtDlpHealth.missing, detail: '') : (health: YtDlpHealth.pathOnly, detail: other);
  }

  // ---- running --------------------------------------------------------------

  /// Runs a process, streaming stderr/stdout lines to [onLine]. Returns exit code.
  ///
  /// [cancel] kills the process together with what it started (yt-dlp runs
  /// ffmpeg and deno), and the call returns once the process is gone even if
  /// a leftover child still holds the output pipes open.
  Future<int> run(String exe, List<String> args, {void Function(String line)? onLine, Future<void>? cancel, String? workingDir, Map<String, String>? env}) async {
    final proc = await Process.start(exe, args, environment: {..._env(), ...?env}, workingDirectory: workingDir, runInShell: false);
    var cancelled = false;
    cancel?.then((_) {
      cancelled = true;
      killTree(proc);
    });
    final done = Completer<void>();
    var open = 2;
    void closeOne() {
      if (--open == 0 && !done.isCompleted) done.complete();
    }

    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l), onDone: closeOne, onError: (_) {});
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l), onDone: closeOne, onError: (_) {});
    final code = await proc.exitCode;
    // Normally the pipes close with the process; a child it left behind can
    // keep them open, so do not wait for them after a cancel or for long.
    await done.future.timeout(cancelled ? const Duration(milliseconds: 300) : const Duration(seconds: 5), onTimeout: () {});
    return code;
  }

  /// Kills [proc] and the processes it started. On Windows killing a process
  /// leaves its children running, so the whole tree goes through taskkill.
  static void killTree(Process proc) {
    if (Platform.isWindows) {
      Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']).then((r) {
        if (r.exitCode != 0) proc.kill();
      }, onError: (Object _) {
        proc.kill();
      });
    } else {
      proc.kill();
    }
  }

  static final _ytProgress = RegExp(r'\[download\]\s+([\d.]+)%');

  /// Downloads a YouTube (or any yt-dlp supported) URL as an mp4 with the best
  /// audio, into [outDir]. Returns the output file path. Progress 0..1.
  ///
  /// YouTube changes often break an old yt-dlp, and the app's copy is only
  /// updated on request, so a failed download updates the managed copy
  /// (installing it first when only a PATH yt-dlp or none was there) and,
  /// when that changed the yt-dlp in use, tries once more.
  Future<String> downloadVideo(String url, String outDir, {void Function(double, String)? onProgress, Future<void>? cancel}) async {
    var cancelled = false;
    cancel?.then((_) => cancelled = true);
    try {
      return await _downloadVideo(url, outDir, onProgress: onProgress, cancel: cancel);
    } on StateError catch (e, st) {
      if (cancelled) rethrow;
      final hasManaged = await File(managedPath(SidecarKind.ytDlp)).exists();
      onProgress?.call(0, hasManaged ? 'yt-dlp -U' : tr('sidecars.ytDlpInstalling'));
      final ({bool installed, bool ok, String output}) update;
      try {
        update = await updateYtDlp(onProgress: (dp) => onProgress?.call(dp.fraction, tr('sidecars.ytDlpInstalling')));
      } catch (_) {
        // No catalog entry or no network: the download's own error says more.
        Error.throwWithStackTrace(e, st);
      }
      final updated = update.output.contains('Updated yt-dlp to');
      // A fresh managed copy replaces a PATH yt-dlp of unknown age (or none).
      if (!updated && !update.installed) rethrow;
      onProgress?.call(0, updated ? update.output.split('\n').last.trim() : tr('sidecars.ytDlpInstalled'));
      return _downloadVideo(url, outDir, onProgress: onProgress, cancel: cancel);
    }
  }

  Future<String> _downloadVideo(String url, String outDir, {void Function(double, String)? onProgress, Future<void>? cancel}) async {
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
    String? error;
    final code = await run(yt, args, cancel: cancel, onLine: (l) {
      final m = _ytProgress.firstMatch(l);
      if (m != null) onProgress?.call(double.parse(m.group(1)!) / 100.0, l.trim());
      if (l.startsWith(outDir) && (l.endsWith('.mp4') || l.endsWith('.mkv') || l.endsWith('.webm'))) outPath = l.trim();
      if (l.contains('ERROR')) {
        error = l.trim();
        onProgress?.call(-1, error!);
      }
    });
    if (code != 0) throw StateError(error == null ? 'yt-dlp exited with $code' : 'yt-dlp exited with $code: $error');
    outPath ??= await _find(Directory(outDir), 'source.mp4');
    if (outPath == null) throw StateError('yt-dlp produced no file');
    return outPath!;
  }

  /// How long [probeUrl] waits for yt-dlp.
  static const probeTimeout = Duration(minutes: 2);

  /// yt-dlp metadata (title, duration, id) without downloading.
  Future<Map<String, dynamic>> probeUrl(String url) async {
    final yt = await resolve(SidecarKind.ytDlp);
    if (yt == null) throw StateError('yt-dlp not available');
    final deno = await resolve(SidecarKind.deno);
    final out = StringBuffer(), err = StringBuffer();
    final proc = await Process.start(yt, ['--no-playlist', '-J', if (deno != null) ...['--js-runtimes', 'deno:$deno'], url], environment: _env());
    final o = proc.stdout.transform(utf8.decoder).listen(out.write, onError: (_) {});
    final e = proc.stderr.transform(utf8.decoder).listen(err.write, onError: (_) {});
    // A stalled network must not leave the add-song dialog spinning forever.
    final code = await proc.exitCode.timeout(probeTimeout, onTimeout: () {
      killTree(proc);
      throw StateError('yt-dlp -J: no answer after ${probeTimeout.inSeconds} s');
    });
    await Future.wait([o.asFuture<void>(), e.asFuture<void>()]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    if (code != 0) throw StateError('yt-dlp -J failed: $err');
    return jsonDecode(out.toString()) as Map<String, dynamic>;
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

  /// Integrated loudness (EBU R128) and sample peak of [input]; null when
  /// ffmpeg is missing or the measurement fails.
  Future<TrackLoudness?> measureLoudness(String input) async {
    final ff = await resolve(SidecarKind.ffmpeg);
    if (ff == null) return null;
    final err = StringBuffer();
    final code = await run(ff, ['-nostdin', '-hide_banner', '-nostats', '-i', input, '-af', 'ebur128=peak=sample:framelog=quiet', '-f', 'null', '-'], onLine: (l) => err.writeln(l));
    if (code != 0) return null;
    return parseEbur128Summary(err.toString());
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
