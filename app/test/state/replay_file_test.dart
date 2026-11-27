import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/models.dart' show scaledTotal;
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/replay_file.dart';
import 'package:karaoke_battle/state/track_timeline.dart';

ReplayFile sample({String? voice}) => ReplayFile(
      player: 'Hikari',
      exportedAt: DateTime.utc(2026, 10, 29, 12),
      appVersion: '0.2.0',
      song: const ReplaySong(title: '食虫植物', language: 'ja', sourceType: 'youtube', youtubeId: 'trrLxXbRjeM', durationSec: 158),
      createdAt: DateTime.utc(2026, 10, 29, 11),
      pitchShift: -2,
      track: 'inst',
      timeOffset: -0.03,
      notes: {
        'notes': [
          {'onset': 1.0, 'offset': 1.5, 'pitch': 64.2},
        ],
        'excluded_spans': [
          [3.0, 3.4],
        ],
      },
      takeF0: {'hop': 0.016, 'sample_rate': 16000, 'times': [0.0, 0.016], 'f0': [0.0, 220.0], 'confidence': [0.1, 0.9]},
      score: {'total': 91.0, 'rank': 'S', 'raw_total': 88.0, 'scale': 4, 'sub_scores': {}},
      voiceFile: voice,
    );

void main() {
  test('a duet take says which part it sang', () {
    final base = sample().toJson();
    expect((base['take'] as Map).containsKey('duet'), isFalse);
    expect(ReplayFile.parse(jsonEncode(base)).duetPart, isNull);
    for (final (v, want) in [('a', 'a'), ('b', 'b'), ('both', null), (1, null)]) {
      final j = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      (j['take'] as Map)['duet'] = v;
      expect(ReplayFile.parse(jsonEncode(j)).duetPart, want, reason: '$v');
    }
  });

  test('a challenge is accepted only when the sharer ticked it', () {
    final base = sample().toJson();
    expect(base.containsKey('accepts_challenge'), isFalse, reason: 'not written unless ticked');
    expect(ReplayFile.parse(jsonEncode(base)).acceptsChallenge, isFalse, reason: 'older files: no');
    for (final v in ['true', 1, 'yes', null]) {
      expect(ReplayFile.parse(jsonEncode({...base, 'accepts_challenge': v})).acceptsChallenge, isFalse, reason: '$v');
    }
    expect(ReplayFile.parse(jsonEncode({...base, 'accepts_challenge': true})).acceptsChallenge, isTrue);
    final ticked = ReplayFile(
      player: 'Hikari', exportedAt: DateTime.utc(2026), appVersion: '1', song: const ReplaySong(title: 't'), createdAt: DateTime.utc(2026),
      pitchShift: 0, track: 'inst', timeOffset: 0, notes: base['notes'] as Map<String, dynamic>, takeF0: base['take_f0'] as Map<String, dynamic>,
      score: base['score'] as Map<String, dynamic>, acceptsChallenge: true,
    );
    expect(ReplayFile.parse(ticked.encode()).acceptsChallenge, isTrue);
  });

  test('round trip keeps every field', () {
    final r = ReplayFile.parse(sample(voice: '食虫植物 91.0 vocal.mp3').encode());
    expect(r.player, 'Hikari');
    expect(r.song.youtubeId, 'trrLxXbRjeM');
    expect(r.song.title, '食虫植物');
    expect(r.pitchShift, -2);
    expect(r.timeOffset, closeTo(-0.03, 1e-9));
    expect((r.notes['notes'] as List).length, 1);
    expect(r.notes['excluded_spans'], [
      [3.0, 3.4],
    ]);
    expect(r.total, 91.0);
    expect(r.rank, 'S');
    expect(r.hasVoice, isTrue);
    expect(r.voiceFile, '食虫植物 91.0 vocal.mp3');
  });

  test('the track timeline travels with the replay; older files have none', () {
    final base = sample();
    final withLog = ReplayFile(
      player: base.player,
      exportedAt: base.exportedAt,
      appVersion: base.appVersion,
      song: base.song,
      createdAt: base.createdAt,
      pitchShift: base.pitchShift,
      track: 'midi',
      timeOffset: base.timeOffset,
      notes: base.notes,
      takeF0: base.takeF0,
      score: base.score,
      trackTimeline: const [TrackSwitch(0, 'inst'), TrackSwitch(12.345, 'mix'), TrackSwitch(40.5, 'midi')],
    );
    final r = ReplayFile.parse(withLog.encode());
    expect(r.track, 'midi');
    expect([for (final e in r.trackTimeline) (e.t, e.track)], [(0.0, 'inst'), (12.345, 'mix'), (40.5, 'midi')]);
    expect(ReplayFile.parse(base.encode()).trackTimeline, isEmpty);
    // A malformed timeline is dropped, not the replay.
    final j = jsonDecode(withLog.encode()) as Map<String, dynamic>;
    (j['take'] as Map)['track_timeline'] = [
      {'t': -1, 'track': 'inst'},
    ];
    expect(ReplayFile.parse(jsonEncode(j)).trackTimeline, isEmpty);
    expect(TrackSwitch.listFromJson([
      {'t': 1, 'track': 'karaoke'},
    ]), isEmpty);
  });

  test('rejects non-JSON, other formats and newer versions', () {
    expect(() => ReplayFile.parse('not json'), throwsA(isA<ReplayFormatException>().having((e) => e.code, 'code', 'notJson')));
    expect(() => ReplayFile.parse('{"format":"x"}'), throwsA(isA<ReplayFormatException>().having((e) => e.code, 'code', 'wrongFormat')));
    final newer = sample().toJson()..['version'] = 99;
    expect(() => ReplayFile.parse(jsonEncode(newer)), throwsA(isA<ReplayFormatException>().having((e) => e.code, 'code', 'newerVersion')));
    final older = sample().toJson()..['version'] = 1;
    expect(() => ReplayFile.parse(jsonEncode(older)), throwsA(isA<ReplayFormatException>().having((e) => e.code, 'code', 'oldVersion')));
  });

  test('drops anything that is not a plain YouTube id and ignores paths/urls', () {
    final j = sample().toJson();
    (j['song'] as Map)['youtube_id'] = 'https://evil.example/x';
    (j['song'] as Map)['source_url'] = 'file:///etc/passwd';
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.song.youtubeId, isNull);
    expect(r.toJson()['song'], isNot(contains('source_url')));
  });

  test('rejects malformed curves and notes', () {
    final badF0 = sample().toJson();
    (badF0['take_f0'] as Map)['f0'] = [1.0];
    expect(() => ReplayFile.parse(jsonEncode(badF0)), throwsA(isA<ReplayFormatException>()));
    final badNote = sample().toJson();
    (badNote['notes'] as Map)['notes'] = [
      {'onset': 'x', 'offset': 1, 'pitch': 60},
    ];
    expect(() => ReplayFile.parse(jsonEncode(badNote)), throwsA(isA<ReplayFormatException>()));
    final badVoice = sample().toJson();
    badVoice['voice'] = {'base64': '<script>'};
    expect(() => ReplayFile.parse(jsonEncode(badVoice)), throwsA(isA<ReplayFormatException>()));
  });

  test('clamps out-of-range numbers', () {
    final j = sample().toJson();
    (j['take'] as Map)['pitch_shift'] = 1000;
    (j['take'] as Map)['time_offset'] = -1e9;
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.pitchShift, 24);
    expect(r.timeOffset, -30);
  });

  test('voice file: round trip and only bare .mp3 names', () {
    final j = sample().toJson()..['voice'] = {'codec': 'mp3', 'file': '食虫植物 91.0 vocal.mp3'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.voiceFile, '食虫植物 91.0 vocal.mp3');
    expect(r.hasVoice, isTrue);
    expect((ReplayFile.parse(r.encode()).toJson()['voice'] as Map)['file'], '食虫植物 91.0 vocal.mp3');
    for (final bad in ['../x.mp3', 'a/b.mp3', r'a\b.mp3', '.hidden.mp3', 'x.exe', 'C:x.mp3', 'x.m4a', '']) {
      final b = sample().toJson()..['voice'] = {'file': bad};
      expect(() => ReplayFile.parse(jsonEncode(b)), throwsA(isA<ReplayFormatException>()), reason: bad);
    }
  });

  test('included song: round trip; a bad name drops only the song; older files have none', () {
    expect(sample().hasSongAudio, isFalse);
    expect(sample().toJson().containsKey('song_audio'), isFalse);
    final j = sample(voice: 'x vocal.mp3').toJson()..['song_audio'] = {'codec': 'mp3', 'file': 'x song.mp3'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.songAudioFile, 'x song.mp3');
    expect(r.hasSongAudio, isTrue);
    expect(ReplayFile.parse(r.encode()).songAudioFile, 'x song.mp3');
    for (final bad in <Object?>['../x.mp3', 'a/b.mp3', '.h.mp3', 'x.wav', '', 'x vocal.mp3', 42, null]) {
      final b = sample(voice: 'x vocal.mp3').toJson()..['song_audio'] = {'file': bad};
      final parsed = ReplayFile.parse(jsonEncode(b));
      expect(parsed.songAudioFile, isNull, reason: '$bad');
      expect(parsed.voiceFile, 'x vocal.mp3');
    }
    final notMap = sample().toJson()..['song_audio'] = 'x song.mp3';
    expect(ReplayFile.parse(jsonEncode(notMap)).songAudioFile, isNull);
  });

  test('cover: only with the included song, only bare .jpg names', () {
    final j = sample().toJson()
      ..['song_audio'] = {'file': 's.mp3'}
      ..['song_cover'] = {'type': 'jpeg', 'file': 's cover.jpg'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.songCoverFile, 's cover.jpg');
    expect(ReplayFile.parse(r.encode()).songCoverFile, 's cover.jpg');
    final alone = sample().toJson()..['song_cover'] = {'file': 's cover.jpg'};
    expect(ReplayFile.parse(jsonEncode(alone)).songCoverFile, isNull, reason: 'no song, no cover');
    for (final bad in ['../c.jpg', 'a/c.jpg', '.c.jpg', 'c.png', 'c.jpeg.exe', '']) {
      final b = sample().toJson()
        ..['song_audio'] = {'file': 's.mp3'}
        ..['song_cover'] = {'file': bad};
      expect(ReplayFile.parse(jsonEncode(b)).songCoverFile, isNull, reason: bad);
    }
  });

  test('backing track: only with the included song, a distinct bare .mp3 name', () {
    Map<String, dynamic> withSong(Object? backing) => sample(voice: 'v.mp3').toJson()
      ..['song_audio'] = {'file': 's.mp3'}
      ..['backing_audio'] = {'codec': 'mp3', 'file': backing};
    final r = ReplayFile.parse(jsonEncode(withSong('b.mp3')));
    expect(r.backingFile, 'b.mp3');
    expect(ReplayFile.parse(r.encode()).backingFile, 'b.mp3');
    final alone = sample().toJson()..['backing_audio'] = {'file': 'b.mp3'};
    expect(ReplayFile.parse(jsonEncode(alone)).backingFile, isNull, reason: 'no song, no backing');
    for (final bad in ['../b.mp3', 'a/b.mp3', 'b.wav', 'v.mp3', 's.mp3', '', 3]) {
      expect(ReplayFile.parse(jsonEncode(withSong(bad))).backingFile, isNull, reason: '$bad');
    }
  });

  test('a score without the scale field is converted to the DAM-like scale', () {
    final j = sample().toJson()..['score'] = {'total': 85.0, 'rank': 'S'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.total, closeTo(scaledTotal(85), 1e-9));
    expect(r.score['raw_total'], 85);
  });

  test('exports carry the video id only, no URL', () {
    final song = sample().toJson()['song'] as Map;
    expect(song['youtube_id'], 'trrLxXbRjeM');
    expect(song.containsKey('youtube_url'), isFalse);
  });

  test('files without a YouTube id (local songs) import with no link', () {
    final none = sample().toJson();
    (none['song'] as Map).remove('youtube_id');
    final r = ReplayFile.parse(jsonEncode(none));
    expect(r.song.youtubeId, isNull);
    expect((r.toJson()['song'] as Map).containsKey('youtube_id'), isFalse);
  });

  test('a URL in the file is never read, even a YouTube one', () {
    final j = sample().toJson();
    (j['song'] as Map)
      ..remove('youtube_id')
      ..['youtube_url'] = 'https://www.youtube.com/watch?v=trrLxXbRjeM';
    expect(ReplayFile.parse(jsonEncode(j)).song.youtubeId, isNull);
  });

  test('youtubeIdFromUrl (for songs added from a link) accepts YouTube links only', () {
    for (final url in [
      'https://www.youtube.com/watch?v=trrLxXbRjeM&t=12s',
      'https://youtu.be/trrLxXbRjeM?si=abc',
      'https://m.youtube.com/watch?v=trrLxXbRjeM',
      'https://music.youtube.com/watch?v=trrLxXbRjeM&list=x',
      'https://www.youtube.com/shorts/trrLxXbRjeM',
    ]) {
      expect(youtubeIdFromUrl(url), 'trrLxXbRjeM', reason: url);
    }
    for (final url in [
      'https://evil.example/watch?v=trrLxXbRjeM',
      'https://youtube.com.evil.example/watch?v=trrLxXbRjeM',
      'file:///etc/passwd',
      'https://www.youtube.com/watch?v=short',
      'not a url',
      null,
    ]) {
      expect(youtubeIdFromUrl(url), isNull, reason: url);
    }
  });

  test('shared subtitles travel with the replay; older files have none', () {
    expect(ReplayFile.parse(sample().encode()).lyrics, isNull);
    final j = sample().toJson()
      ..['lyrics'] = {
        'primary': 'ja-x-import',
        'tracks': [
          {
            'lang': 'ja-x-import',
            'source': 'imported',
            'label': 'song.srt',
            'lines': [
              {'start': 2.0, 'end': 3.0, 'text': 'second'},
              {'start': 1.0, 'end': 2.0, 'text': 'first'},
            ],
          },
          {'lang': 'ja-x-edit', 'source': 'edited', 'lines': [{'start': 1.0, 'end': 2.0, 'text': 'x'}]},
        ],
      };
    final l = ReplayFile.parse(jsonEncode(j)).lyrics!;
    expect([for (final t in l.tracks) t.lang], ['ja-x-import', 'ja-x-edit']);
    expect(l.primary, 'ja-x-import');
    expect(l.tracks.first.source, LyricSource.imported);
    expect(l.tracks.first.label, 'song.srt');
    expect([for (final x in l.tracks.first.lines) x.text], ['first', 'second'], reason: 'sorted by time');
    // Written back the same way.
    final again = ReplayFile.parse(ReplayFile.parse(jsonEncode(j)).encode()).lyrics!;
    expect(again.tracks.first.lines.length, 2);
  });

  test('bad shared subtitles are dropped without refusing the replay', () {
    Map<String, dynamic> withTracks(List<Object?> tracks) => sample().toJson()..['lyrics'] = {'primary': 'zz', 'tracks': tracks};
    final line = {'start': 1.0, 'end': 2.0, 'text': 'ok'};
    final r = ReplayFile.parse(jsonEncode(withTracks([
      {'lang': 'ja', 'source': 'youtube', 'lines': [line]}, // the video's own: fetched from YouTube instead
      {'lang': '../etc', 'source': 'imported', 'lines': [line]}, // not a track key
      {'lang': 'ja-x-import', 'source': 'nope', 'lines': [line]},
      {'lang': 'ja-x-manual', 'source': 'manual', 'lines': [{'start': 3.0, 'end': 1.0, 'text': 'backwards'}, {'start': 'a', 'end': 1, 'text': 'x'}]},
      'not a map',
      {'lang': 'zh-x-import', 'source': 'imported', 'lines': [line, {'start': 2.0, 'end': 2.5, 'text': '   '}]},
    ])));
    expect(r.total, 91.0);
    expect([for (final t in r.lyrics!.tracks) t.lang], ['zh-x-import']);
    expect(r.lyrics!.tracks.single.lines.length, 1);
    expect(r.lyrics!.primary, 'zh-x-import', reason: 'unknown primary falls back to the first track');
    expect(ReplayFile.parse(jsonEncode(sample().toJson()..['lyrics'] = 'x')).lyrics, isNull);
    final long = 'あ' * 2000;
    final big = ReplayFile.parse(jsonEncode(withTracks([
      {'lang': 'ja-x-import', 'source': 'imported', 'lines': [{'start': 0, 'end': 1, 'text': long}]},
    ])));
    expect(big.lyrics!.tracks.single.lines.single.text.length, ReplayFile.maxLyricText);
  });
}
