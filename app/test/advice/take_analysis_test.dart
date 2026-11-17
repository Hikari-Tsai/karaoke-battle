import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/advice/advice_prompt.dart';
import 'package:karaoke_battle/advice/take_analysis.dart';
import 'package:karaoke_battle/scoring/models.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/voice_range.dart';

/// Four lines of five notes. Line 1 is clean, line 2 is flat, line 3 is
/// mostly not sung, line 4 has long notes cut short.
({List<ReferenceNote> notes, Map<String, dynamic> score, List<LyricLine> lyrics}) _fixture({bool rushing = true}) {
  final notes = <ReferenceNote>[];
  final perNote = <Map<String, dynamic>>[];
  final rhythm = <Map<String, dynamic>>[];
  final lyrics = <LyricLine>[];
  for (var line = 0; line < 4; line++) {
    final start = line * 5.0;
    final dur = line == 3 ? 0.8 : 0.3;
    lyrics.add(LyricLine(start, start + 4.5, 'line ${line + 1} words'));
    for (var k = 0; k < 5; k++) {
      final i = notes.length;
      final on = start + k * (dur + 0.1);
      notes.add(ReferenceNote(onset: on, offset: on + dur, pitch: 60.0 + line * 2 + k));
      final flat = line == 1 && k < 4;
      final silent = line == 2 && k < 3;
      perNote.add({
        'index': i,
        'evaluable': true,
        'matched': !flat && !silent,
        'cents_deviation': silent ? null : (flat ? -70.0 : 5.0),
        'onset_error_ms': silent ? null : -40.0,
        'offset_error_ms': silent ? null : (line == 3 ? -150.0 : 0.0),
        'voiced_fraction': silent ? 0.1 : 0.9,
      });
      rhythm.add({'index': i, 'onset': silent ? 'miss' : 'perfect', 'offset': silent ? null : 'perfect'});
    }
  }
  final score = <String, dynamic>{
    'total': 80.0,
    'rank': 'A',
    'scale': 4,
    'shift': 0,
    'octave_exact_shift': 0,
    'sub_scores': {
      'pitch': {'value': 0.7, 'weight': 40},
      'rhythm': {'value': 0.85, 'weight': 20},
      'stability': {'value': 0.95, 'weight': 10},
      'vibrato': {'value': null, 'weight': 10},
      'expression': {'value': 0.9, 'weight': 10},
      'long_tone': {'value': 0.6, 'weight': 10},
    },
    'note_metrics': {'per_note': perNote},
    'rhythm': {
      'notes': rhythm,
      'windows': {'perfect_ms': 50, 'great_ms': 100, 'good_ms': 150},
      'clock_trusted': rushing,
      'tendency': rushing ? 'rushing' : 'steady',
      'tendency_ms': -40.0,
    },
    'technique': {
      'pitch_stability_cents': 40.0,
      'reference_pitch_stability_cents': 20.0,
      'long_notes': [
        {'index': 15, 'stability_cents': 55.0, 'vibrato': false, 'ref_stability_cents': 20.0},
        {'index': 16, 'stability_cents': 22.0, 'vibrato': false, 'ref_stability_cents': 20.0},
      ],
    },
  };
  return (notes: notes, score: score, lyrics: lyrics);
}

TakeAnalysis _analyze({bool lyrics = true, List<HistoryTake> history = const [], VoiceZone? own, bool rushing = true}) {
  final f = _fixture(rushing: rushing);
  return analyzeTake(TakeAnalysisInput(
    notes: f.notes,
    score: f.score,
    takeCreatedAt: DateTime(2026, 11, 17),
    songTitle: 'Song',
    lyrics: lyrics ? f.lyrics : const [],
    history: history,
    ownRange: own,
  ));
}

Finding? _find(TakeAnalysis a, String kind) => a.findings.where((f) => f.kind == kind).firstOrNull;

void main() {
  test('notes are grouped into lyric lines with per-line statistics', () {
    final a = _analyze();
    expect(a.lines.length, 4);
    expect(a.lines.map((l) => l.lyric), ['line 1 words', 'line 2 words', 'line 3 words', 'line 4 words']);
    final l2 = a.lines[1];
    expect(l2.matched, 1);
    expect(l2.flat, 4);
    expect(l2.medianCents, -70);
    expect(a.lines[2].unsung, 3);
    expect(a.lines[3].longNotes, 5);
    expect(a.lines[3].earlyReleases, 5);
  });

  test('without lyrics the notes are split at pauses', () {
    final a = _analyze(lyrics: false);
    expect(a.lines.length, 4);
    expect(a.lines.every((l) => l.lyric == null), isTrue);
    expect(a.lines.map((l) => l.noteIndexes.length), [5, 5, 5, 5]);
  });

  test('findings name the weak lines, timing, releases and steadiness', () {
    final a = _analyze();
    final weak = a.findings.where((f) => f.kind == 'weak_line').expand((f) => f.lines).toSet();
    // Line 3 is mostly not sung: reported as such, not as out of tune.
    expect(weak, {2});
    expect(_find(a, 'unsung')!.lines, [3]);
    expect(_find(a, 'rushing')!.data['median_ms'], -40);
    expect(_find(a, 'early_release')!.lines, [4]);
    expect(_find(a, 'unsteady_long_notes')!.lines, [4]);
    expect(_find(a, 'unsung')!.data['unsung'], 3);
    expect(_find(a, 'strong_scores')!.positive, isTrue);
    expect(_find(a, 'clean_lines')!.lines, [1]);
  });

  test('timing tendency is not reported without a calibrated clock', () {
    final a = _analyze(rushing: false);
    expect(_find(a, 'rushing'), isNull);
    expect(a.rhythmTendency, 'none');
  });

  test('findings are ranked problems first, at most six, with sequential ids', () {
    final a = _analyze(history: [HistoryTake(createdAt: DateTime(2026, 11, 1), total: 70, subScores: {'pitch': 60, 'rhythm': 95})]);
    final firstPositive = a.findings.indexWhere((f) => f.positive);
    expect(a.findings.skip(firstPositive).every((f) => f.positive), isTrue);
    expect(a.findings.where((f) => !f.positive).length, lessThanOrEqualTo(6));
    for (var i = 0; i < a.findings.length; i++) {
      expect(a.findings[i].id, 'F${i + 1}');
    }
    final problems = a.findings.where((f) => !f.positive).toList();
    for (var i = 1; i < problems.length; i++) {
      expect(problems[i].severity, lessThanOrEqualTo(problems[i - 1].severity));
    }
  });

  test('history compares with the latest earlier take only', () {
    // Without the rushing finding the regression makes the top six.
    final a = _analyze(rushing: false, history: [
      HistoryTake(createdAt: DateTime(2026, 11, 1), total: 70, subScores: {'pitch': 60, 'rhythm': 95}),
      HistoryTake(createdAt: DateTime(2026, 10, 1), total: 85, subScores: {'pitch': 80}),
      HistoryTake(createdAt: DateTime(2026, 12, 1), total: 99), // later: ignored
    ]);
    expect(a.previous!.total, 70);
    expect(a.best!.total, 85);
    expect(a.historyCount, 2);
    expect(_find(a, 'progress')!.data['improved'], {'pitch': 10});
    expect(_find(a, 'regression')!.data['dropped'], {'rhythm': -10});
  });

  test('a song above the singer range gets a key suggestion', () {
    // Notes span C4..A#4 (60..70); a range of A2..F#3 is far below.
    final a = _analyze(own: const VoiceZone(VoiceType.you, 45, 54));
    final f = _find(a, 'out_of_range')!;
    expect(f.data['fit'], 'high');
    expect(f.data['suggested_key_change'] as int, lessThan(0));
  });

  test('the Markdown export is complete in every language', () {
    final a = _analyze(
      history: [HistoryTake(createdAt: DateTime(2026, 11, 1), total: 70, subScores: {'pitch': 60, 'rhythm': 95})],
      own: const VoiceZone(VoiceType.you, 45, 54),
    );
    for (final lang in ['zh', 'en', 'ja']) {
      final md = buildAdvicePrompt(a, lang: lang, appVersion: '1.0.0');
      expect(md, isNot(contains('{')), reason: 'unreplaced argument in $lang');
      expect(RegExp(r'\b(kind|d|sub|reg|col|ov|h)\.[a-z_.]+').hasMatch(md), isFalse, reason: 'missing string in $lang');
      for (final f in a.findings) {
        expect(md, contains('[${f.id}]'));
      }
      expect(md, contains('line 2 words'));
      expect(md, contains('Song'));
    }
    expect(buildAdvicePrompt(a, lang: 'zh', includeTitle: false), isNot(contains('| Song')));
  });

  test('every finding kind has text in every language', () {
    // Build one finding of each kind through the public API by checking the
    // strings the renderer looks up.
    const kinds = [
      'weak_line', 'sharp_overall', 'flat_overall', 'high_register', 'low_register', 'out_of_range', 'unsung', 'rushing', 'dragging',
      'timing_lines', 'early_release', 'unsteady_long_notes', 'little_vibrato', 'flat_dynamics', 'regression', 'strong_scores', 'clean_lines', 'progress',
    ];
    final a = _analyze();
    for (final kind in kinds) {
      a.findings
        ..clear()
        ..add(Finding(kind: kind, severity: 1, data: _sampleData(kind))..id = 'F1');
      for (final lang in ['zh', 'en', 'ja']) {
        final md = buildAdvicePrompt(a, lang: lang);
        expect(md, isNot(contains('kind.$kind')), reason: '$kind title missing in $lang');
        expect(md, isNot(contains('{')), reason: '$kind has unreplaced arguments in $lang');
      }
    }
  });
}

Map<String, Object?> _sampleData(String kind) => switch (kind) {
      'weak_line' => {'matched': 1, 'evaluable': 5, 'median_cents': -30, 'sharp': 0, 'flat': 3, 'unsung': 1, 'range': 'C4–G4'},
      'sharp_overall' || 'flat_overall' => {'median_cents': 20, 'notes': 40},
      'high_register' || 'low_register' => {'range': 'C5–E5', 'accuracy': 50, 'overall_accuracy': 80, 'median_cents': -25, 'unsung': 2},
      'out_of_range' => {
          'fit': 'wide', 'semitones': 3, 'own_range': 'A2–F4', 'song_tessitura': 'C3–A4', 'time_above': 20, 'time_below': 10,
          'accuracy_outside': 40, 'current_key_change': 0, 'suggested_key_change': -2,
        },
      'unsung' => {'unsung': 5, 'evaluable': 40},
      'rushing' || 'dragging' => {'median_ms': -40},
      'timing_lines' => {},
      'early_release' => {'early': 5, 'long_notes': 10, 'median_offset_ms': -90},
      'unsteady_long_notes' => {'stability_cents': 40, 'reference_cents': 20, 'notes': [{'line': 2, 'note': 'C4', 'stability_cents': 50}]},
      'little_vibrato' => {'amount': 5, 'reference_amount': 40},
      'flat_dynamics' => {'correlation': 0.3},
      'regression' => {'total_change': -3.0, 'dropped': {'rhythm': -8}},
      'strong_scores' => {'stability': 95},
      'clean_lines' => {},
      'progress' => {'total_change': 4.0, 'improved': {'pitch': 6}},
      _ => {},
    };
