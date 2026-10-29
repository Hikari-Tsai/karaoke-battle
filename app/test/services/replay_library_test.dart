import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
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

    final text = await replays.export(song: song, files: files, take: take, player: 'P', includeVoice: true);
    final parsed = ReplayFile.parse(text);
    expect(parsed.appVersion, '9.9.9');
    expect(parsed.song.youtubeId, 'trrLxXbRjeM');
    expect(parsed.pitchShift, 3);
    expect(parsed.track, 'mix');
    expect(parsed.timeOffset, closeTo(0.3, 1e-9));
    expect(parsed.hasVoice, isFalse, reason: 'no take.wav to include');
    expect(text, isNot(contains(tmp.path)), reason: 'no local paths leak into the file');

    final r = (await replays.import((File(p.join(tmp.path, 'x.json'))..writeAsStringSync(text)).path)).single;
    expect(ReplayLibrary.findSong(library, r)?.id, song.id);
  });

  test('suggested file name drops characters file systems reject', () {
    expect(replayFileName('a/b:c?', 91.25), 'a b c 91.3.json');
    expect(replayFileName('  ', null), 'replay.json');
  });
}
