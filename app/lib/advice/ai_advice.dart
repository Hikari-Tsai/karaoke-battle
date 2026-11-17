// Asks an AI service (Claude or OpenAI, with the user's own API key) for
// singing advice on a take and checks the answer against the analysis.
//
// The request carries the same Markdown the user could export by hand
// (advice_prompt.dart) and asks for JSON. Every tip must name the findings
// it is based on; a tip that names none of the take's findings is dropped,
// and the evidence shown next to a tip comes from the analysis, not from
// the model's text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'advice_prompt.dart';
import 'take_analysis.dart';

enum AiProvider {
  claude,
  openai;

  static AiProvider byName(String name) => name == 'openai' ? openai : claude;
}

/// Why a request failed; [detail] is the service's own message when it gave
/// one (never the API key).
class AiAdviceException implements Exception {
  AiAdviceException(this.kind, [this.detail = '']);

  /// auth | rateLimit | network | server | refused | truncated | badRequest | badResponse
  final String kind;
  final String detail;

  @override
  String toString() => 'AiAdviceException($kind${detail.isEmpty ? '' : ': $detail'})';
}

class AiTip {
  const AiTip({required this.findingIds, required this.title, required this.advice, required this.exercise});
  final List<String> findingIds;
  final String title;
  final String advice;
  final String exercise;

  Map<String, dynamic> toJson() => {'finding_ids': findingIds, 'title': title, 'advice': advice, 'exercise': exercise};

  static AiTip? fromJson(Object? j) {
    if (j is! Map) return null;
    final ids = j['finding_ids'];
    return AiTip(
      findingIds: [if (ids is List) for (final e in ids) if (e is String) e],
      title: _text(j['title']),
      advice: _text(j['advice']),
      exercise: _text(j['exercise']),
    );
  }
}

class AiAdvice {
  const AiAdvice({required this.summary, required this.tips, required this.closing});
  final String summary;
  final List<AiTip> tips;
  final String closing;

  Map<String, dynamic> toJson() => {'summary': summary, 'tips': [for (final t in tips) t.toJson()], 'closing': closing};

  static AiAdvice fromJson(Map<String, dynamic> j) => AiAdvice(
        summary: _text(j['summary']),
        tips: [if (j['tips'] is List) for (final e in j['tips'] as List) ?AiTip.fromJson(e)],
        closing: _text(j['closing']),
      );

  /// Plain text, for the clipboard.
  String toPlainText() => [
        summary,
        for (var i = 0; i < tips.length; i++)
          '${i + 1}. ${tips[i].title} [${tips[i].findingIds.join(', ')}]\n${tips[i].advice}\n→ ${tips[i].exercise}',
        closing,
      ].where((s) => s.trim().isNotEmpty).join('\n\n');
}

String _text(Object? v) => v is String ? v.trim() : '';

/// The answer's JSON schema (also valid for OpenAI's strict mode).
const Map<String, dynamic> adviceSchema = {
  'type': 'object',
  'properties': {
    'summary': {'type': 'string'},
    'tips': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'finding_ids': {'type': 'array', 'items': {'type': 'string'}},
          'title': {'type': 'string'},
          'advice': {'type': 'string'},
          'exercise': {'type': 'string'},
        },
        'required': ['finding_ids', 'title', 'advice', 'exercise'],
        'additionalProperties': false,
      },
    },
    'closing': {'type': 'string'},
  },
  'required': ['summary', 'tips', 'closing'],
  'additionalProperties': false,
};

const _languageNames = {'zh': 'Traditional Chinese (Taiwan)', 'en': 'English', 'ja': 'Japanese'};

/// How the answer maps onto the cards the app shows.
String adviceSystemPrompt(String lang) => 'Your answer is shown inside the Karaoke Battle app as cards, so reply with JSON only, '
    'following the schema. "summary" is the opening overall feedback (one or two sentences, starting with what went well). '
    '"tips" holds 3 to 5 pieces of advice, most important first. For each tip: "finding_ids" lists the ids of the findings '
    'it is based on, exactly as written in the file (for example "F2"), and must not be empty; "title" is a short title; '
    '"advice" explains the problem and what to change, quoting the lyric line and time when the finding has them; '
    '"exercise" is one concrete exercise. "closing" is one sentence of encouragement naming the one thing to focus on next time. '
    'The app shows the numbers of each finding next to your tip, so do not restate tables. '
    'Write every text in ${_languageNames[lang] ?? _languageNames['zh']}, as plain text without Markdown.';

/// Keeps the tips that are based on findings of [analysis] (ids normalised
/// to "F2"), at most five. Throws `badResponse` when nothing usable is left.
AiAdvice validateAdvice(AiAdvice raw, TakeAnalysis analysis) {
  final known = {for (final f in analysis.findings) f.id};
  final tips = <AiTip>[];
  for (final t in raw.tips) {
    final ids = <String>{
      for (final id in t.findingIds)
        for (final m in RegExp(r'F\d+').allMatches(id.toUpperCase()))
          if (known.contains(m.group(0))) m.group(0)!,
    };
    if (ids.isEmpty || t.title.isEmpty || (t.advice.isEmpty && t.exercise.isEmpty)) continue;
    tips.add(AiTip(findingIds: ids.toList(), title: t.title, advice: t.advice, exercise: t.exercise));
    if (tips.length == 5) break;
  }
  if (tips.isEmpty) throw AiAdviceException('badResponse', 'no tip is based on a finding');
  return AiAdvice(summary: raw.summary, tips: tips, closing: raw.closing);
}

/// Sends [prompt] (the exported Markdown) to [provider] and returns the
/// parsed answer, not yet validated. [client] is closed by the caller;
/// closing it cancels a request in flight.
Future<AiAdvice> requestAdvice({
  required AiProvider provider,
  required String apiKey,
  required String model,
  required String prompt,
  required String lang,
  required http.Client client,
  Duration timeout = const Duration(minutes: 3),
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final system = adviceSystemPrompt(lang);
  for (var attempt = 0;; attempt++) {
    try {
      final text = provider == AiProvider.claude
          ? await _askClaude(client, apiKey, model, system, prompt, timeout)
          : await _askOpenAi(client, apiKey, model, system, prompt, timeout);
      final Object? j;
      try {
        j = jsonDecode(text);
      } catch (_) {
        throw AiAdviceException('badResponse', 'not JSON');
      }
      if (j is! Map<String, dynamic>) throw AiAdviceException('badResponse', 'not an object');
      return AiAdvice.fromJson(j);
    } on AiAdviceException catch (e) {
      // One more try for trouble that usually passes.
      if (attempt == 0 && (e.kind == 'rateLimit' || e.kind == 'server' || e.kind == 'network')) {
        await Future<void>.delayed(retryDelay);
        continue;
      }
      rethrow;
    }
  }
}

Future<http.Response> _post(http.Client client, Uri url, Map<String, String> headers, Map<String, dynamic> body, Duration timeout) async {
  try {
    return await client.post(url, headers: {'content-type': 'application/json', ...headers}, body: jsonEncode(body)).timeout(timeout);
  } on TimeoutException {
    throw AiAdviceException('network', 'timed out');
  } on SocketException catch (e) {
    throw AiAdviceException('network', e.message);
  } on http.ClientException catch (e) {
    throw AiAdviceException('network', e.message);
  }
}

/// Maps an error status to an exception; [message] is the service's text.
Never _fail(int status, String message) {
  final kind = switch (status) {
    401 || 403 => 'auth',
    429 => 'rateLimit',
    400 || 404 || 413 || 422 => 'badRequest',
    _ => 'server',
  };
  throw AiAdviceException(kind, message.length > 300 ? '${message.substring(0, 300)}…' : message);
}

Map<String, dynamic> _decode(http.Response r) {
  try {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map<String, dynamic>) return j;
  } catch (_) {}
  if (r.statusCode >= 400) _fail(r.statusCode, 'HTTP ${r.statusCode}');
  throw AiAdviceException('badResponse', 'not JSON');
}

String _errorMessage(Map<String, dynamic> j, int status) {
  final e = j['error'];
  final m = e is Map ? e['message'] : null;
  return m is String && m.isNotEmpty ? m : 'HTTP $status';
}

// ---------------------------------------------------------------- Claude

/// Models that take a server-side fallback when a safety classifier declines.
bool _claudeHasFallback(String model) => !model.contains('haiku');

Future<String> _askClaude(http.Client client, String apiKey, String model, String system, String prompt, Duration timeout) async {
  Future<http.Response> send({required bool fallback}) => _post(
        client,
        Uri.parse('https://api.anthropic.com/v1/messages'),
        {
          'x-api-key': apiKey,
          'anthropic-version': '2026-10-21',
          if (fallback) 'anthropic-beta': 'server-side-fallback-2026-07-01',
        },
        {
          'model': model,
          'max_tokens': 16000,
          'system': system,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'output_config': {
            'effort': 'medium',
            'format': {'type': 'json_schema', 'schema': adviceSchema},
          },
          if (fallback) 'fallbacks': 'default',
        },
        timeout,
      );

  var fallback = _claudeHasFallback(model);
  var r = await send(fallback: fallback);
  var j = _decode(r);
  // An account or model without the fallback beta: ask again without it.
  if (r.statusCode == 400 && fallback && _errorMessage(j, 400).toLowerCase().contains('fallback')) {
    r = await send(fallback: false);
    j = _decode(r);
  }
  if (r.statusCode != 200) _fail(r.statusCode, _errorMessage(j, r.statusCode));
  final stop = j['stop_reason'];
  if (stop == 'refusal') throw AiAdviceException('refused');
  if (stop == 'max_tokens') throw AiAdviceException('truncated');
  final content = j['content'];
  if (content is List) {
    for (final b in content) {
      if (b is Map && b['type'] == 'text' && b['text'] is String) return b['text'] as String;
    }
  }
  throw AiAdviceException('badResponse', 'no text in the answer');
}

// ---------------------------------------------------------------- OpenAI

Future<String> _askOpenAi(http.Client client, String apiKey, String model, String system, String prompt, Duration timeout) async {
  final r = await _post(
    client,
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    {'authorization': 'Bearer $apiKey'},
    {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': prompt},
      ],
      'response_format': {
        'type': 'json_schema',
        'json_schema': {'name': 'singing_advice', 'strict': true, 'schema': adviceSchema},
      },
    },
    timeout,
  );
  final j = _decode(r);
  if (r.statusCode != 200) _fail(r.statusCode, _errorMessage(j, r.statusCode));
  final choices = j['choices'];
  final choice = choices is List && choices.isNotEmpty && choices.first is Map ? choices.first as Map : null;
  final message = choice?['message'];
  if (message is! Map) throw AiAdviceException('badResponse', 'no message in the answer');
  if (message['refusal'] is String && (message['refusal'] as String).isNotEmpty) throw AiAdviceException('refused');
  if (choice?['finish_reason'] == 'length') throw AiAdviceException('truncated');
  final content = message['content'];
  if (content is! String || content.isEmpty) throw AiAdviceException('badResponse', 'no text in the answer');
  return content;
}

// ---------------------------------------------------------------- models

/// A model the API key can use, for the model menu in Settings.
class AiModelInfo {
  const AiModelInfo(this.id, [this.name = '']);
  final String id;

  /// Display name when the service gives one ("Claude Opus 5.5"), else ''.
  final String name;

  String get label => name.isEmpty || name == id ? id : '$name · $id';

  Map<String, dynamic> toJson() => {'id': id, if (name.isNotEmpty) 'name': name};

  static AiModelInfo? fromJson(Object? j) => j is Map && j['id'] is String && (j['id'] as String).isNotEmpty ? AiModelInfo(j['id'] as String, _text(j['name'])) : null;

  static List<AiModelInfo> listFromJson(String text) {
    try {
      final j = jsonDecode(text);
      return [if (j is List) for (final e in j) ?fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<AiModelInfo> models) => jsonEncode([for (final m in models) m.toJson()]);
}

/// The models [apiKey] can ask for advice, newest first. Also the way to
/// check a key: a wrong one throws `auth`.
Future<List<AiModelInfo>> listModels({
  required AiProvider provider,
  required String apiKey,
  required http.Client client,
  Duration timeout = const Duration(seconds: 20),
}) =>
    provider == AiProvider.claude ? _listClaude(client, apiKey, timeout) : _listOpenAi(client, apiKey, timeout);

Future<Map<String, dynamic>> _get(http.Client client, Uri url, Map<String, String> headers, Duration timeout) async {
  final http.Response r;
  try {
    r = await client.get(url, headers: headers).timeout(timeout);
  } on TimeoutException {
    throw AiAdviceException('network', 'timed out');
  } on SocketException catch (e) {
    throw AiAdviceException('network', e.message);
  } on http.ClientException catch (e) {
    throw AiAdviceException('network', e.message);
  }
  final j = _decode(r);
  if (r.statusCode != 200) _fail(r.statusCode, _errorMessage(j, r.statusCode));
  return j;
}

Future<List<AiModelInfo>> _listClaude(http.Client client, String apiKey, Duration timeout) async {
  final out = <AiModelInfo>[];
  String? after;
  // Newest first; a few pages at most.
  for (var page = 0; page < 5; page++) {
    final j = await _get(
      client,
      Uri.https('api.anthropic.com', '/v1/models', {'limit': '100', 'after_id': ?after}),
      {'x-api-key': apiKey, 'anthropic-version': '2026-10-21'},
      timeout,
    );
    for (final m in (j['data'] as List? ?? const [])) {
      if (m is! Map || m['id'] is! String) continue;
      // The answer is asked for as JSON, so the model has to support that.
      final caps = m['capabilities'];
      final structured = caps is Map && caps['structured_outputs'] is Map ? (caps['structured_outputs'] as Map)['supported'] : null;
      if (structured == false) continue;
      out.add(AiModelInfo(m['id'] as String, _text(m['display_name'])));
    }
    after = j['last_id'] is String ? j['last_id'] as String : null;
    if (j['has_more'] != true || after == null) break;
  }
  return out;
}

Future<List<AiModelInfo>> _listOpenAi(http.Client client, String apiKey, Duration timeout) async {
  final j = await _get(client, Uri.parse('https://api.openai.com/v1/models'), {'authorization': 'Bearer $apiKey'}, timeout);
  return filterOpenAiModels(j['data'] as List? ?? const []);
}

final _openAiChat = RegExp(r'^(gpt-|o\d|chat-)');
final _openAiOther = RegExp(r'image|audio|realtime|transcribe|tts|live|search|codex|moderation|embedding|whisper|instruct|-pro\b');
final _openAiSnapshot = RegExp(r'-\d{4}(-\d{2}-\d{2})?$');

/// OpenAI lists every kind of model together: keeps the chat models
/// (no image, audio, realtime, search or code models, no "pro" models that
/// only the Responses API serves, no dated snapshots), newest first.
List<AiModelInfo> filterOpenAiModels(List raw) {
  final kept = <(int, String)>[];
  for (final m in raw) {
    if (m is! Map || m['id'] is! String) continue;
    final id = m['id'] as String;
    if (!_openAiChat.hasMatch(id) || _openAiOther.hasMatch(id) || _openAiSnapshot.hasMatch(id)) continue;
    kept.add((m['created'] is num ? (m['created'] as num).toInt() : 0, id));
  }
  kept.sort((a, b) => b.$1 != a.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  return [for (final k in kept) AiModelInfo(k.$2)];
}

// ---------------------------------------------------------------- cache

/// An answer kept in the take folder (advice.json).
class SavedAdvice {
  const SavedAdvice({required this.advice, required this.provider, required this.model, required this.lang, required this.createdAt});
  final AiAdvice advice;
  final String provider, model, lang;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'version': advicePromptVersion,
        'provider': provider,
        'model': model,
        'lang': lang,
        'created_at': createdAt.toIso8601String(),
        'advice': advice.toJson(),
      };

  /// Null for a file from another prompt version or one that cannot be read.
  static SavedAdvice? fromJson(Object? j) {
    if (j is! Map || j['version'] != advicePromptVersion || j['advice'] is! Map) return null;
    final advice = AiAdvice.fromJson((j['advice'] as Map).cast<String, dynamic>());
    if (advice.tips.isEmpty) return null;
    return SavedAdvice(
      advice: advice,
      provider: _text(j['provider']),
      model: _text(j['model']),
      lang: _text(j['lang']),
      createdAt: DateTime.tryParse(_text(j['created_at'])) ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static Future<SavedAdvice?> load(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      return fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String path) => File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
}
