import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/advice/advice_prompt.dart';
import 'package:karaoke_battle/advice/ai_advice.dart';
import 'package:karaoke_battle/advice/take_analysis.dart';
import 'package:karaoke_battle/scoring/models.dart';
import 'package:karaoke_battle/services/ai_keys.dart';

/// A take with one flat line, so the analysis has a finding F1.
TakeAnalysis _analysis() {
  final notes = [for (var i = 0; i < 4; i++) ReferenceNote(onset: i * 0.5, offset: i * 0.5 + 0.4, pitch: 60.0 + i)];
  return analyzeTake(TakeAnalysisInput(
    notes: notes,
    takeCreatedAt: DateTime(2026, 11, 17),
    score: {
      'total': 60.0,
      'rank': 'B',
      'scale': 4,
      'sub_scores': {
        'pitch': {'value': 0.4, 'weight': 40},
      },
      'note_metrics': {
        'per_note': [
          for (var i = 0; i < 4; i++) {'index': i, 'evaluable': true, 'matched': false, 'cents_deviation': -80.0, 'voiced_fraction': 0.9},
        ],
      },
    },
  ));
}

const _answer = {
  'summary': 'Good start.',
  'tips': [
    {'finding_ids': ['F1'], 'title': 'Flat line', 'advice': 'Aim higher.', 'exercise': 'Sing with a tuner.'},
    {'finding_ids': ['[F1]', 'F99'], 'title': 'Brackets', 'advice': 'Still F1.', 'exercise': 'Hum it.'},
    {'finding_ids': ['F42'], 'title': 'Made up', 'advice': 'Not in the data.', 'exercise': 'None.'},
    {'finding_ids': <String>[], 'title': 'No basis', 'advice': 'x', 'exercise': 'y'},
  ],
  'closing': 'Keep going.',
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Future<AiAdvice> _ask(AiProvider provider, MockClient client, {String model = 'm'}) =>
    requestAdvice(provider: provider, apiKey: 'secret-key', model: model, prompt: 'PROMPT', lang: 'ja', client: client, retryDelay: Duration.zero);

void main() {
  test('Claude: request shape and the answer from the first text block', () async {
    late http.Request sent;
    final client = MockClient((r) async {
      sent = r;
      return _json({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {'type': 'text', 'text': jsonEncode(_answer)},
        ],
      });
    });
    final a = await _ask(AiProvider.claude, client, model: 'claude-opus-5-5');
    expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(sent.headers['x-api-key'], 'secret-key');
    expect(sent.headers['anthropic-version'], '2026-10-21');
    expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'claude-opus-5-5');
    expect(body['fallbacks'], 'default');
    expect(body['messages'], [
      {'role': 'user', 'content': 'PROMPT'},
    ]);
    expect(body['system'], contains('Japanese'));
    expect(body['output_config']['format'], {'type': 'json_schema', 'schema': adviceSchema});
    expect(body.containsKey('temperature'), isFalse);
    expect(a.summary, 'Good start.');
    expect(a.tips.length, 4);
  });

  test('the AI Mentor: the same Claude request to the relay, without a key', () async {
    late http.Request sent;
    final client = MockClient((r) async {
      sent = r;
      return _json({'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': jsonEncode(_answer)}]});
    });
    final a = await requestAdvice(
        provider: AiProvider.claude, apiKey: '', model: 'claude-sonnet-5-5', prompt: 'PROMPT', lang: 'ja', client: client, retryDelay: Duration.zero,
        relay: Uri.parse('https://relay.example/advice'), clientId: 'user-1');
    expect(sent.url.toString(), 'https://relay.example/advice');
    expect(sent.headers.containsKey('x-api-key'), isFalse, reason: 'the relay holds the key');
    expect(sent.headers['x-kb-client'], 'user-1');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['messages'], [
      {'role': 'user', 'content': 'PROMPT'},
    ], reason: 'the same raw data as "Ask AI"');
    expect(body['system'], contains('Japanese'));
    expect(a.summary, 'Good start.');
  });

  test('Claude: Haiku is asked without a fallback, and a fallback refusal is retried without it', () async {
    final bodies = <Map<String, dynamic>>[];
    final ok = _json({'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': jsonEncode(_answer)}]});
    await _ask(AiProvider.claude, MockClient((r) async {
      bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
      expect(r.headers.containsKey('anthropic-beta'), isFalse);
      return ok;
    }), model: 'claude-haiku-5-5');
    expect(bodies.single.containsKey('fallbacks'), isFalse);

    bodies.clear();
    await _ask(AiProvider.claude, MockClient((r) async {
      bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
      return bodies.length == 1 ? _json({'error': {'type': 'invalid_request_error', 'message': 'fallbacks: not available'}}, 400) : ok;
    }), model: 'claude-opus-5-5');
    expect(bodies.length, 2);
    expect(bodies[1].containsKey('fallbacks'), isFalse);
  });

  test('OpenAI: request shape and the answer from the message content', () async {
    late http.Request sent;
    final a = await _ask(AiProvider.openai, MockClient((r) async {
      sent = r;
      return _json({
        'choices': [
          {'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': jsonEncode(_answer), 'refusal': null}},
        ],
      });
    }), model: 'gpt-6.1-sol');
    expect(sent.url.toString(), 'https://api.openai.com/v1/chat/completions');
    expect(sent.headers['authorization'], 'Bearer secret-key');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['model'], 'gpt-6.1-sol');
    expect(body['messages'][1], {'role': 'user', 'content': 'PROMPT'});
    expect(body['response_format']['json_schema']['strict'], isTrue);
    expect(body['response_format']['json_schema']['schema'], adviceSchema);
    expect(a.closing, 'Keep going.');
  });

  test('errors are told apart and never carry the key', () async {
    Future<AiAdviceException> fail(AiProvider p, http.Response r) async {
      try {
        await _ask(p, MockClient((_) async => r));
      } on AiAdviceException catch (e) {
        expect(e.toString(), isNot(contains('secret-key')));
        return e;
      }
      fail0('no exception');
    }

    expect((await fail(AiProvider.claude, _json({'error': {'message': 'invalid x-api-key'}}, 401))).kind, 'auth');
    expect((await fail(AiProvider.openai, _json({'error': {'message': 'The model `x` does not exist'}}, 404))).kind, 'badRequest');
    expect((await fail(AiProvider.openai, _json({'error': {'message': 'quota'}}, 429))).kind, 'rateLimit');
    expect((await fail(AiProvider.claude, _json({'error': {'message': 'overloaded'}}, 529))).kind, 'server');
    expect((await fail(AiProvider.claude, _json({'stop_reason': 'refusal', 'content': []}))).kind, 'refused');
    expect((await fail(AiProvider.claude, _json({'stop_reason': 'max_tokens', 'content': [{'type': 'text', 'text': '{"summ'}]}))).kind, 'truncated');
    expect((await fail(AiProvider.openai, _json({'choices': [{'finish_reason': 'stop', 'message': {'content': null, 'refusal': 'no'}}]}))).kind, 'refused');
    expect((await fail(AiProvider.openai, _json({'choices': [{'finish_reason': 'stop', 'message': {'content': 'not json'}}]}))).kind, 'badResponse');
  });

  test('a busy or failing service is asked once more', () async {
    var calls = 0;
    final a = await _ask(AiProvider.openai, MockClient((_) async {
      calls++;
      if (calls == 1) return _json({'error': {'message': 'busy'}}, 503);
      return _json({'choices': [{'finish_reason': 'stop', 'message': {'content': jsonEncode(_answer)}}]});
    }));
    expect(calls, 2);
    expect(a.tips, isNotEmpty);

    calls = 0;
    await expectLater(
      _ask(AiProvider.openai, MockClient((_) async {
        calls++;
        return _json({'error': {'message': 'bad key'}}, 401);
      })),
      throwsA(isA<AiAdviceException>()),
    );
    expect(calls, 1, reason: 'a wrong key is not retried');
  });

  test('only tips based on findings of the take are kept', () {
    final analysis = _analysis();
    expect(analysis.findings.map((f) => f.id), contains('F1'));
    final v = validateAdvice(AiAdvice.fromJson(_answer), analysis);
    expect(v.tips.map((t) => t.title), ['Flat line', 'Brackets']);
    expect(v.tips[1].findingIds, ['F1']);
    expect(
      () => validateAdvice(const AiAdvice(summary: 's', tips: [AiTip(findingIds: ['F42'], title: 't', advice: 'a', exercise: 'e')], closing: 'c'), analysis),
      throwsA(isA<AiAdviceException>().having((e) => e.kind, 'kind', 'badResponse')),
    );
  });

  test('the evidence shown with a tip comes from the analysis', () {
    final analysis = _analysis();
    final f = analysis.findings.firstWhere((f) => f.id == 'F1');
    for (final lang in ['zh', 'en', 'ja']) {
      expect(findingTitle(f, lang), isNot(contains('kind.')));
      expect(describeFinding(f, analysis, lang), isNot(contains('{')));
    }
  });

  test('an answer is kept in the take folder and read back', () async {
    final dir = await Directory.systemTemp.createTemp('kb_advice');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/advice.json';
    expect(await SavedAdvice.load(path), isNull);
    final saved = SavedAdvice(advice: AiAdvice.fromJson(_answer), provider: 'claude', model: 'claude-opus-5-5', lang: 'zh', createdAt: DateTime(2026, 11, 17, 15));
    await saved.save(path);
    final back = (await SavedAdvice.load(path))!;
    expect(back.model, 'claude-opus-5-5');
    expect(back.advice.tips.first.exercise, 'Sing with a tuner.');
    expect(back.createdAt, DateTime(2026, 11, 17, 15));
    // Another prompt version is not reused.
    final j = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    await File(path).writeAsString(jsonEncode({...j, 'version': advicePromptVersion + 1}));
    expect(await SavedAdvice.load(path), isNull);
    expect(saved.advice.toPlainText(), contains('1. Flat line [F1]'));
  });

  test('Claude models: paged, newest first, only ones that can answer in JSON', () async {
    final urls = <Uri>[];
    final models = await listModels(
      provider: AiProvider.claude,
      apiKey: 'secret-key',
      client: MockClient((r) async {
        urls.add(r.url);
        expect(r.method, 'GET');
        expect(r.headers['x-api-key'], 'secret-key');
        expect(r.headers['anthropic-version'], '2026-10-21');
        if (r.url.queryParameters['after_id'] == null) {
          return _json({
            'data': [
              {'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5', 'capabilities': {'structured_outputs': {'supported': true}}},
              {'id': 'claude-old', 'display_name': 'Old', 'capabilities': {'structured_outputs': {'supported': false}}},
            ],
            'has_more': true,
            'last_id': 'claude-old',
          });
        }
        return _json({
          'data': [
            {'id': 'claude-haiku-5-5', 'display_name': 'Claude Haiku 5.5'},
          ],
          'has_more': false,
          'last_id': 'claude-haiku-5-5',
        });
      }),
    );
    expect(models.map((m) => m.id), ['claude-opus-5-5', 'claude-haiku-5-5']);
    expect(models.first.label, 'Claude Opus 5.5 · claude-opus-5-5');
    expect(urls.length, 2);
    expect(urls[1].queryParameters['after_id'], 'claude-old');
  });

  test('OpenAI models: only chat models, without snapshots, newest first', () async {
    final models = await listModels(
      provider: AiProvider.openai,
      apiKey: 'secret-key',
      client: MockClient((r) async {
        expect(r.url.toString(), 'https://api.openai.com/v1/models');
        expect(r.headers['authorization'], 'Bearer secret-key');
        return _json({
          'data': [
            for (final (i, id) in [
              'text-embedding-3-large', 'gpt-4o', 'gpt-4o-2024-08-06', 'o3', 'o3-pro', 'gpt-5.4-mini', 'gpt-5.4-mini-2026-03-17', 'gpt-5.3-codex',
              'gpt-5.5-pro', 'chat-latest', 'gpt-realtime-2.1', 'gpt-transcribe', 'gpt-6-sol', 'gpt-live-1', 'gpt-6.1-sol', 'gpt-image-2.6-flare',
              'whisper-1', 'tts-1-1106', 'omni-moderation-latest', 'gpt-audio-mini', 'gpt-5-search-api', 'gpt-4o-mini-tts',
            ].indexed)
              {'id': id, 'created': 1000 + i, 'owned_by': 'system'},
          ],
        });
      }),
    );
    expect(models.map((m) => m.id), ['gpt-6.1-sol', 'gpt-6-sol', 'chat-latest', 'gpt-5.4-mini', 'o3', 'gpt-4o']);
    expect(models.first.label, 'gpt-6.1-sol');
  });

  test('listing models tells a wrong key, and the list survives the settings', () async {
    await expectLater(
      listModels(provider: AiProvider.openai, apiKey: 'bad', client: MockClient((_) async => _json({'error': {'message': 'Incorrect API key'}}, 401))),
      throwsA(isA<AiAdviceException>().having((e) => e.kind, 'kind', 'auth')),
    );
    const list = [AiModelInfo('claude-opus-5-5', 'Claude Opus 5.5'), AiModelInfo('gpt-6.1-sol')];
    final back = AiModelInfo.listFromJson(AiModelInfo.listToJson(list));
    expect(back.map((m) => m.label), ['Claude Opus 5.5 · claude-opus-5-5', 'gpt-6.1-sol']);
    expect(AiModelInfo.listFromJson(''), isEmpty);
    expect(AiModelInfo.listFromJson('not json'), isEmpty);
  });

  test('the in-memory key store trims and removes', () async {
    final store = MemoryAiKeyStore();
    await store.write('claude', '  sk-test  ');
    expect(await store.read('claude'), 'sk-test');
    await store.write('claude', '');
    expect(await store.read('claude'), isNull);
  });
}

Never fail0(String message) => throw TestFailure(message);
