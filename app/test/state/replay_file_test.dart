import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/replay_file.dart';

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
      score: {'total': 93.4, 'rank': 'S', 'raw_total': 88.0, 'scale': 2, 'sub_scores': {}},
      voiceFile: voice,
    );

void main() {
  test('round trip keeps every field', () {
    final r = ReplayFile.parse(sample(voice: '食虫植物 93.4 vocal.mp3').encode());
    expect(r.player, 'Hikari');
    expect(r.song.youtubeId, 'trrLxXbRjeM');
    expect(r.song.title, '食虫植物');
    expect(r.pitchShift, -2);
    expect(r.timeOffset, closeTo(-0.03, 1e-9));
    expect((r.notes['notes'] as List).length, 1);
    expect(r.notes['excluded_spans'], [
      [3.0, 3.4],
    ]);
    expect(r.total, 93.4);
    expect(r.rank, 'S');
    expect(r.hasVoice, isTrue);
    expect(r.voiceFile, '食虫植物 93.4 vocal.mp3');
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
    final j = sample().toJson()..['voice'] = {'codec': 'mp3', 'file': '食虫植物 93.4 vocal.mp3'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.voiceFile, '食虫植物 93.4 vocal.mp3');
    expect(r.hasVoice, isTrue);
    expect((ReplayFile.parse(r.encode()).toJson()['voice'] as Map)['file'], '食虫植物 93.4 vocal.mp3');
    for (final bad in ['../x.mp3', 'a/b.mp3', r'a\b.mp3', '.hidden.mp3', 'x.exe', 'C:x.mp3', 'x.m4a', '']) {
      final b = sample().toJson()..['voice'] = {'file': bad};
      expect(() => ReplayFile.parse(jsonEncode(b)), throwsA(isA<ReplayFormatException>()), reason: bad);
    }
  });

  test('a score without the scale field is converted to the DAM-like scale', () {
    final j = sample().toJson()..['score'] = {'total': 85.0, 'rank': 'S'};
    final r = ReplayFile.parse(jsonEncode(j));
    expect(r.total, closeTo(91.75, 1e-9));
    expect(r.score['raw_total'], 85);
  });
}
