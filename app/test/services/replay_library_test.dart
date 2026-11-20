import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:karaoke_battle/engine/engine.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/backend_manager.dart';
import 'package:karaoke_battle/services/backing_import.dart';
import 'package:karaoke_battle/services/model_registry.dart';
import 'package:karaoke_battle/services/prep_pipeline.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_cover.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/replay_archive.dart';
import 'package:karaoke_battle/state/replay_file.dart';
import 'package:karaoke_battle/ui/replays/export_replay_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

ReplayFile _file({String? yt = 'trrLxXbRjeM', String title = '食虫植物'}) => ReplayFile(
      player: 'Hikari',
      exportedAt: DateTime.utc(2026, 10, 29),
      appVersion: '0.2.0',
      song: ReplaySong(title: title, language: 'ja', sourceType: yt == null ? 'file' : 'youtube', youtubeId: yt, durationSec: 158),
      createdAt: DateTime.utc(2026, 10, 28),
      pitchShift: -2,
      track: 'inst',
      timeOffset: 0.12,
      notes: {
        'notes': [
          {'onset': 1.0, 'offset': 1.5, 'pitch': 64.0},
        ],
        'excluded_spans': [],
      },
      takeF0: {'hop': 0.016, 'sample_rate': 16000, 'times': [0.0, 0.016], 'f0': [0.0, 220.0], 'confidence': [0.1, 0.9]},
      score: {'total': 86.6, 'rank': 'A', 'raw_total': 79.1, 'scale': 4},
    );

void main() {
  late Directory tmp;
  late AppPaths paths;
  late ReplayLibrary replays;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('replays_test');
    paths = AppPaths.forTest(tmp.path);
    replays = ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({})));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('import writes take files the replay screen reads and survives reload', () async {
    final src = File(p.join(tmp.path, 'in.json'))..writeAsStringSync(_file().encode());
    final r = (await replays.import(src.path)).single;
    expect(r.title, '食虫植物');
    expect(r.player, 'Hikari');
    expect(r.total, 86.6);
    expect(r.hasVoice, isFalse);
    final info = jsonDecode(File(r.take.infoJson).readAsStringSync()) as Map;
    expect(info['pitch_shift'], -2);
    final side = jsonDecode(File('${r.take.wav}.json').readAsStringSync()) as Map;
    expect(side['track_start_offset'], 0.12);
    expect(side['latency'], 0.0);
    expect(File(r.notesJson).existsSync(), isTrue);
    expect(File(r.take.f0Json).existsSync(), isTrue);

    final again = ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({})));
    await again.reload();
    expect(again.items.single.id, r.id);
    expect(again.items.single.youtubeId, 'trrLxXbRjeM');
  });

  test('a bad file leaves nothing behind', () async {
    final src = File(p.join(tmp.path, 'bad.json'))..writeAsStringSync('{"format":"karaoke-battle-replay","version":1}');
    await expectLater(replays.import(src.path), throwsA(isA<ReplayFormatException>()));
    final dir = Directory(replays.root);
    expect(!dir.existsSync() || dir.listSync().isEmpty, isTrue);
  });

  test('findSong matches by video id, then by title and duration', () async {
    final library = SongLibrary(paths);
    final yt = await library.create(title: 'Other title', sourceType: SourceType.youtube, sourceUrl: 'https://youtu.be/trrLxXbRjeM');
    final byTitle = await library.create(title: 'Local Song', sourceType: SourceType.file);
    byTitle.durationSec = 200;

    final a = (await replays.import((File(p.join(tmp.path, 'a.json'))..writeAsStringSync(_file().encode())).path)).single;
    expect(ReplayLibrary.findSong(library, a)?.id, yt.id);

    final b = (await replays.import((File(p.join(tmp.path, 'b.json'))..writeAsStringSync(_file(yt: null, title: 'local song').encode())).path)).single;
    expect(ReplayLibrary.findSong(library, b), isNull, reason: 'duration differs by more than 2 s');
    byTitle.durationSec = 159;
    expect(ReplayLibrary.findSong(library, b)?.id, byTitle.id);

    await replays.link(b, yt.id);
    expect(ReplayLibrary.findSong(library, b)?.id, yt.id, reason: 'a manual link wins');
  });

  test('export without voice round-trips through import', () async {
    PackageInfo.setMockInitialValues(appName: 'kb', packageName: 'kb', version: '9.9.9', buildNumber: '1', buildSignature: '');
    final library = SongLibrary(paths);
    final song = await library.create(title: 'Mine', sourceType: SourceType.youtube, sourceUrl: 'https://youtu.be/trrLxXbRjeM', language: 'ja');
    song.youtubeId = 'trrLxXbRjeM';
    final files = library.files(song);
    final f = _file();
    File(files.notesJson).writeAsStringSync(jsonEncode(f.notes));
    final takeDir = Directory(p.join(files.dir, 'takes', 't1'))..createSync(recursive: true);
    final take = TakeInfo(id: 't1', dir: takeDir.path, createdAt: DateTime.utc(2026, 10, 28), total: 88.5, rank: 'S');
    File(take.f0Json).writeAsStringSync(jsonEncode(f.takeF0));
    File(take.scoreJson).writeAsStringSync(jsonEncode(f.score));
    File(take.infoJson).writeAsStringSync(jsonEncode({'pitch_shift': 3, 'track': 'mix'}));
    File('${take.wav}.json').writeAsStringSync(jsonEncode({'track_start_offset': 0.5, 'latency': 0.2}));

    final zip = await replays.export(song: song, files: files, take: take, player: 'P', baseName: 'Mine 88.5');
    final bundle = unpackReplays(zip);
    expect(bundle.audio, isEmpty, reason: 'no take.wav, so no vocal file');
    final text = bundle.replays.single.text;
    final parsed = ReplayFile.parse(text);
    expect(parsed.appVersion, '9.9.9');
    expect(parsed.song.youtubeId, 'trrLxXbRjeM');
    expect(parsed.pitchShift, 3);
    expect(parsed.track, 'mix');
    expect(parsed.timeOffset, closeTo(0.3, 1e-9));
    expect(parsed.hasVoice, isFalse, reason: 'no take.wav to include');
    expect(parsed.voiceFile, isNull);
    expect(text, isNot(contains(tmp.path)), reason: 'no local paths leak into the file');

    final r = (await replays.import((File(p.join(tmp.path, 'x.zip'))..writeAsBytesSync(zip)).path)).single;
    expect(ReplayLibrary.findSong(library, r)?.id, song.id);
  });

  test('the player\'s own subtitles are exported and added to the song once', () async {
    PackageInfo.setMockInitialValues(appName: 'kb', packageName: 'kb', version: '9.9.9', buildNumber: '1', buildSignature: '');
    SharedPreferences.setMockInitialValues({});
    final library = SongLibrary(paths);
    final mine = await library.create(title: 'Local Song', sourceType: SourceType.file, language: 'zh');
    final files = library.files(mine);
    final f = _file(yt: null, title: 'Local Song');
    File(files.notesJson).writeAsStringSync(jsonEncode(f.notes));
    File(files.lyricsJson).writeAsStringSync(jsonEncode(Lyrics(tracks: [
      LyricTrack(lang: 'zh', auto: true, source: LyricSource.youtube, lines: const [LyricLine(1, 2, 'yt')]),
      LyricTrack(lang: 'zh-x-import', auto: false, source: LyricSource.imported, label: 'mine.srt', offset: 0.25, lines: const [LyricLine(1, 2, '你好', romaji: 'ni hao')]),
    ], primary: 'zh-x-import').toJson()));
    final takeDir = Directory(p.join(files.dir, 'takes', 't1'))..createSync(recursive: true);
    final take = TakeInfo(id: 't1', dir: takeDir.path, createdAt: DateTime.utc(2026, 10, 28), total: 88.5, rank: 'S');
    File(take.f0Json).writeAsStringSync(jsonEncode(f.takeF0));
    File(take.scoreJson).writeAsStringSync(jsonEncode(f.score));

    final zip = await replays.export(song: mine, files: files, take: take, player: 'P', baseName: 'Local Song 88.5');
    final text = unpackReplays(zip).replays.single.text;
    final shared = ReplayFile.parse(text).lyrics!;
    expect([for (final t in shared.tracks) t.lang], ['zh-x-import'], reason: 'the YouTube track is not shared');
    expect(shared.tracks.single.lines.single.start, 1.25, reason: 'offset applied');
    expect(text, isNot(contains('ni hao')), reason: 'romaji is not shared');

    // On the other computer: same title, its own lyrics from the video only.
    final r = (await replays.import((File(p.join(tmp.path, 'x.zip'))..writeAsBytesSync(zip)).path)).single;
    expect(File(r.lyricsJson).existsSync(), isTrue);
    final theirs = await library.create(title: 'Local Song', sourceType: SourceType.file, language: 'zh');
    File(library.files(theirs).lyricsJson)
        .writeAsStringSync(jsonEncode(Lyrics(tracks: [LyricTrack(lang: 'zh', auto: true, source: LyricSource.youtube, lines: const [LyricLine(1, 2, 'yt')])], primary: 'zh').toJson()));
    // Chinese lyrics: Japanese ones would start a romaji model download.
    final settings = await AppSettings.load();
    final pipeline = PrepPipeline(
      library: library,
      sidecars: Sidecars(paths, SidecarCatalog({})),
      models: ModelStore(paths),
      backend: BackendManager(Engine.instance, paths, settings),
      settings: settings,
    );
    expect(await replays.addSharedLyrics(r, theirs, pipeline), isTrue);
    var lyrics = await pipeline.loadLyrics(theirs);
    expect(lyrics.primaryTrack!.lines.single.text, '你好');
    expect(lyrics.primaryTrack!.label, 'mine.srt');
    // Once per song: deleting the track afterwards sticks, also after a reload.
    lyrics.tracks.removeWhere((t) => t.source == LyricSource.imported);
    lyrics.primary = 'zh';
    await pipeline.saveLyrics(theirs, lyrics);
    final again = ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({})));
    await again.reload();
    expect(await again.addSharedLyrics(again.items.single, theirs, pipeline), isFalse);
    lyrics = await pipeline.loadLyrics(theirs);
    expect(lyrics.tracks.length, 1);
  });

  test('suggested file name drops characters file systems reject', () {
    expect(replayBaseName('a/b:c?', 91.25), 'a b c 91.3');
    expect(replayBaseName('  ', null), 'replay');
    expect(replayBaseName('..Wait...', null), 'Wait.');
    expect(ReplayFile.isVoiceFileName('${replayBaseName('..Wait...', 70)} vocal.mp3'), isTrue);
  });

  test('with ffmpeg: the zip carries the vocal, and import decodes it (zip or unzipped JSON)', () async {
    final ff = await Sidecars(paths, SidecarCatalog({})).resolve(SidecarKind.ffmpeg);
    if (ff == null) {
      markTestSkipped('ffmpeg not installed');
      return;
    }
    PackageInfo.setMockInitialValues(appName: 'kb', packageName: 'kb', version: '9.9.9', buildNumber: '1', buildSignature: '');
    final library = SongLibrary(paths);
    final song = await library.create(title: '食虫植物', sourceType: SourceType.youtube, sourceUrl: 'https://youtu.be/trrLxXbRjeM', language: 'ja');
    final files = library.files(song);
    final f = _file();
    File(files.notesJson).writeAsStringSync(jsonEncode(f.notes));
    final takeDir = Directory(p.join(files.dir, 'takes', 't1'))..createSync(recursive: true);
    final take = TakeInfo(id: 't1', dir: takeDir.path, createdAt: DateTime.utc(2026, 10, 28), total: 88.5, rank: 'S');
    File(take.f0Json).writeAsStringSync(jsonEncode(f.takeF0));
    File(take.scoreJson).writeAsStringSync(jsonEncode(f.score));
    // A 2 s sine as the recording.
    final gen = await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=220:duration=2', '-ar', '48000', '-ac', '1', take.wav]);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');

    final zip = await replays.export(song: song, files: files, take: take, player: 'P', baseName: '食虫植物 88.5');
    final bundle = unpackReplays(zip);
    expect(bundle.audio.keys, ['食虫植物 88.5 vocal.mp3']);
    final parsed = ReplayFile.parse(bundle.replays.single.text);
    expect(parsed.voiceFile, '食虫植物 88.5 vocal.mp3');
    expect(bundle.replays.single.text, isNot(contains('base64')));

    final fromZip = (await replays.import((File(p.join(tmp.path, 'out.zip'))..writeAsBytesSync(zip)).path)).single;
    expect(fromZip.hasVoice, isTrue);
    expect(File(fromZip.take.wav).lengthSync(), greaterThan(100000));
    expect(File(p.join(fromZip.dir, 'vocal.mp3')).existsSync(), isTrue);

    // Unzipped: pick the JSON alone, the vocal is found next to it.
    final out = Directory(p.join(tmp.path, 'unzipped'))..createSync();
    File(p.join(out.path, '食虫植物 88.5.json')).writeAsStringSync(bundle.replays.single.text);
    File(p.join(out.path, '食虫植物 88.5 vocal.mp3')).writeAsBytesSync(bundle.audio.values.single);
    final fromJson = (await replays.import(p.join(out.path, '食虫植物 88.5.json'))).single;
    expect(fromJson.hasVoice, isTrue);
  });

  test('with ffmpeg: a local song can be packed in; import keeps it for preparing', () async {
    final ff = await Sidecars(paths, SidecarCatalog({})).resolve(SidecarKind.ffmpeg);
    if (ff == null) {
      markTestSkipped('ffmpeg not installed');
      return;
    }
    PackageInfo.setMockInitialValues(appName: 'kb', packageName: 'kb', version: '9.9.9', buildNumber: '1', buildSignature: '');
    final library = SongLibrary(paths);
    final local = await library.create(title: 'Local Song', sourceType: SourceType.file, language: 'ja');
    final files = library.files(local);
    final f = _file(yt: null, title: 'Local Song');
    File(files.notesJson).writeAsStringSync(jsonEncode(f.notes));
    // A 3 s stereo tone as the song.
    final gen = await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=330:duration=3', '-ar', '44100', '-ac', '2', files.mixWav]);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    final takeDir = Directory(p.join(files.dir, 'takes', 't1'))..createSync(recursive: true);
    final take = TakeInfo(id: 't1', dir: takeDir.path, createdAt: DateTime.utc(2026, 10, 28), total: 88.5, rank: 'S');
    File(take.f0Json).writeAsStringSync(jsonEncode(f.takeF0));
    File(take.scoreJson).writeAsStringSync(jsonEncode(f.score));

    final without = unpackReplays(await replays.export(song: local, files: files, take: take, player: 'P', baseName: 'Local Song 88.5'));
    expect(without.audio, isEmpty);
    expect(ReplayFile.parse(without.replays.single.text).hasSongAudio, isFalse);

    // The cover the player set goes with the included song.
    final png = p.join(tmp.path, 'cover.png');
    expect((await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=320x180', '-frames:v', '1', png])).exitCode, 0);
    await setSongCover(replays.sidecars, files, png);
    final withoutSong = unpackReplays(await replays.export(song: local, files: files, take: take, player: 'P', baseName: 'Local Song 88.5'));
    expect(withoutSong.audio, isEmpty, reason: 'no song, no cover');

    final noBacking = unpackReplays(await replays.export(song: local, files: files, take: take, player: 'P', baseName: 'Local Song 88.5', includeSong: true));
    expect(noBacking.audio.keys, unorderedEquals(['Local Song 88.5 song.mp3', 'Local Song 88.5 cover.jpg']));
    expect(ReplayFile.parse(noBacking.replays.single.text).backingFile, isNull);

    // The backing track the player imported (inst.user.wav) goes with the song.
    final inst = await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=110:duration=3', '-ar', '44100', '-ac', '2', '-c:a', 'pcm_f32le', files.userInstWav]);
    expect(inst.exitCode, 0, reason: '${inst.stderr}');
    final zip = await replays.export(song: local, files: files, take: take, player: 'P', baseName: 'Local Song 88.5', includeSong: true);
    final bundle = unpackReplays(zip);
    expect(bundle.audio.keys, unorderedEquals(['Local Song 88.5 song.mp3', 'Local Song 88.5 cover.jpg', 'Local Song 88.5 backing.mp3']));
    final sent = ReplayFile.parse(bundle.replays.single.text);
    expect(sent.songAudioFile, 'Local Song 88.5 song.mp3');
    expect(sent.songCoverFile, 'Local Song 88.5 cover.jpg');
    expect(sent.backingFile, 'Local Song 88.5 backing.mp3');

    final r = (await replays.import((File(p.join(tmp.path, 'x.zip'))..writeAsBytesSync(zip)).path)).single;
    expect(r.hasSongAudio, isTrue);
    expect(File(r.songAudio).lengthSync(), bundle.audio['Local Song 88.5 song.mp3']!.length);
    expect(r.hasCover, isTrue);
    expect(File(r.cover).readAsBytesSync(), File(files.coverJpg).readAsBytesSync());
    expect(r.hasBacking, isTrue);
    expect(File(r.backingAudio).lengthSync(), bundle.audio['Local Song 88.5 backing.mp3']!.length);
    // The song prepared from the included copy gets the cover.
    final theirs = SongFiles(p.join(tmp.path, 'theirs'));
    await ReplayLibrary.adoptCover(r, theirs);
    expect(theirs.shownThumb, theirs.coverJpg);
    final again = ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({})));
    await again.reload();
    expect(again.items.single.hasSongAudio, isTrue, reason: 'kept across restarts');
    expect(again.items.single.hasCover, isTrue);
    expect(again.items.single.hasBacking, isTrue);
    // The packed song decodes to the same length as the original.
    final probe = await Process.run(ff, ['-hide_banner', '-i', r.songAudio]);
    expect('${probe.stderr}', contains('Duration: 00:00:03'));

    // A YouTube song is never packed in: the receiver downloads it.
    final yt = await library.create(title: 'YT', sourceType: SourceType.youtube, sourceUrl: 'https://youtu.be/trrLxXbRjeM', language: 'ja');
    final ytFiles = library.files(yt);
    File(ytFiles.notesJson).writeAsStringSync(jsonEncode(f.notes));
    File(files.mixWav).copySync(ytFiles.mixWav);
    final ytZip = unpackReplays(await replays.export(song: yt, files: ytFiles, take: take, player: 'P', baseName: 'YT', includeSong: true));
    expect(ytZip.audio, isEmpty);
  });

  test('a cover that is not a JPEG is dropped; the song still comes', () async {
    final json = ReplayFile.parse(_file(yt: null).encode()).toJson()
      ..['song_audio'] = {'codec': 'mp3', 'file': 's.mp3'}
      ..['song_cover'] = {'type': 'jpeg', 'file': 'c.jpg'};
    final dir = Directory(p.join(tmp.path, 'loose'))..createSync();
    File(p.join(dir.path, 'r.json')).writeAsStringSync(jsonEncode(json));
    File(p.join(dir.path, 's.mp3')).writeAsBytesSync([0xff, 0xfb, 0x90, 0x00]);
    File(p.join(dir.path, 'c.jpg')).writeAsStringSync('<svg>not a jpeg</svg>');
    final r = (await replays.import(p.join(dir.path, 'r.json'))).single;
    expect(r.hasSongAudio, isTrue);
    expect(r.hasCover, isFalse);
    expect(File(r.cover).existsSync(), isFalse);
  });

  test('with ffmpeg: the included backing is applied once, only to the song prepared from the included copy', () async {
    final ff = await Sidecars(paths, SidecarCatalog({})).resolve(SidecarKind.ffmpeg);
    if (ff == null) {
      markTestSkipped('ffmpeg not installed');
      return;
    }
    SharedPreferences.setMockInitialValues({});
    final json = ReplayFile.parse(_file(yt: null).encode()).toJson()
      ..['song_audio'] = {'codec': 'mp3', 'file': 's.mp3'}
      ..['backing_audio'] = {'codec': 'mp3', 'file': 'b.mp3'};
    final dir = Directory(p.join(tmp.path, 'loose'))..createSync();
    File(p.join(dir.path, 'r.json')).writeAsStringSync(jsonEncode(json));
    for (final (name, hz) in [('s.mp3', 330), ('b.mp3', 110)]) {
      final gen = await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'sine=frequency=$hz:duration=3', '-ac', '2', '-c:a', 'libmp3lame', p.join(dir.path, name)]);
      expect(gen.exitCode, 0, reason: '${gen.stderr}');
    }
    final r = (await replays.import(p.join(dir.path, 'r.json'))).single;
    expect(r.hasBacking, isTrue);

    final library = SongLibrary(paths);
    final settings = await AppSettings.load();
    final sidecars = Sidecars(paths, SidecarCatalog({}));
    final pipeline = PrepPipeline(library: library, sidecars: sidecars, models: ModelStore(paths), backend: BackendManager(Engine.instance, paths, settings), settings: settings);
    final backing = BackingImport(library: library, sidecars: sidecars, engine: Engine.instance, paths: paths, pipeline: pipeline);
    // Stand-in for the song prepared from the included copy (its mix is that audio).
    final song = await library.create(title: r.title, sourceType: SourceType.file, language: 'ja');
    final f = library.files(song);
    expect((await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-i', r.songAudio, '-ar', '44100', '-ac', '2', f.mixWav])).exitCode, 0);
    File(f.instWav).writeAsBytesSync(File(f.mixWav).readAsBytesSync());

    // Not prepared from the included copy, or not ready yet: left alone.
    song.stage = PrepStage.done;
    expect(await replays.addIncludedBacking(r, song, backing), isFalse);
    r.includedSongId = song.id;
    song.stage = PrepStage.separateVocals;
    expect(await replays.addIncludedBacking(r, song, backing), isFalse);
    expect(f.hasUserInst, isFalse);

    song.stage = PrepStage.done;
    expect(await replays.addIncludedBacking(r, song, backing), isTrue);
    expect(f.hasUserInst, isTrue);
    final probe = await Process.run(ff, ['-hide_banner', '-i', f.userInstWav]);
    expect('${probe.stderr}', contains('Duration: 00:00:03'), reason: 'cut to the song length');
    // Once: reverting afterwards sticks, also after a restart.
    await backing.revert(song);
    final again = ReplayLibrary(paths, sidecars);
    await again.reload();
    expect(again.items.single.backingAddedTo, song.id);
    expect(await again.addIncludedBacking(again.items.single, song, backing), isFalse);
    expect(f.hasUserInst, isFalse);
  });
}
