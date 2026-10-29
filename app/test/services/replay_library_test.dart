import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/replay_archive.dart';
import 'package:karaoke_battle/state/replay_file.dart';
import 'package:karaoke_battle/ui/replays/export_replay_dialog.dart';
import 'package:path/path.dart' as p;

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
      score: {'total': 88.5, 'rank': 'S'},
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
    expect(r.total, 88.5);
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
}
