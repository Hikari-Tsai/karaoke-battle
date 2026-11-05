// Whisper's byte-level BPE tokenizer (GPT-2 style), read from the model's
// vocab.json, added_tokens.json and tokenizer.json (merges). Decodes the
// engine's token ids to text and encodes prompts. Pure Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

class WhisperTokenizer {
  WhisperTokenizer(Map<String, int> vocab, Map<String, int> added, List<(String, String)> merges)
      : _toId = {...vocab, ...added},
        _special = added,
        _ranks = {for (var i = 0; i < merges.length; i++) '${merges[i].$1} ${merges[i].$2}': i} {
    for (final e in _toId.entries) {
      _toToken[e.value] = e.key;
    }
  }

  final Map<String, int> _toId;
  final Map<int, String> _toToken = {};
  final Map<String, int> _special;
  final Map<String, int> _ranks;
  final Map<String, List<String>> _cache = {};

  /// Loads the tokenizer files of a Whisper model directory (in an isolate:
  /// tokenizer.json is a few MB).
  static Future<WhisperTokenizer> load(String dir) => Isolate.run(() {
        final vocab = (jsonDecode(File(p.join(dir, 'vocab.json')).readAsStringSync()) as Map).cast<String, int>();
        final added = (jsonDecode(File(p.join(dir, 'added_tokens.json')).readAsStringSync()) as Map).cast<String, int>();
        final tj = jsonDecode(File(p.join(dir, 'tokenizer.json')).readAsStringSync()) as Map;
        final merges = <(String, String)>[];
        for (final m in (tj['model'] as Map)['merges'] as List) {
          if (m is String) {
            final i = m.indexOf(' ');
            merges.add((m.substring(0, i), m.substring(i + 1)));
          } else if (m is List && m.length == 2) {
            merges.add((m[0] as String, m[1] as String));
          }
        }
        return WhisperTokenizer(vocab, added, merges);
      });

  /// Id of a special token such as `<|zh|>`, or null.
  int? special(String token) => _special[token];

  /// First id of the special tokens (`<|endoftext|>`); text tokens are below.
  int get eot => _special['<|endoftext|>'] ?? 50257;

  // ---- decoding -------------------------------------------------------------

  /// Text of [ids]; special tokens and timestamps are skipped.
  String decode(Iterable<int> ids) {
    final bytes = <int>[];
    for (final id in ids) {
      if (id >= eot) continue;
      final tok = _toToken[id];
      if (tok == null) continue;
      for (final r in tok.runes) {
        final b = _unicodeToByte[r];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ---- encoding -------------------------------------------------------------

  static final _pretokenize = RegExp(r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+", unicode: true);

  /// Token ids of plain [text] (no special tokens).
  List<int> encode(String text) {
    final out = <int>[];
    for (final m in _pretokenize.allMatches(text)) {
      final piece = String.fromCharCodes(utf8.encode(m.group(0)!).map((b) => _byteToUnicode[b]!));
      for (final t in _bpe(piece)) {
        final id = _toId[t];
        if (id != null) out.add(id);
      }
    }
    return out;
  }

  List<String> _bpe(String token) {
    final cached = _cache[token];
    if (cached != null) return cached;
    var word = [for (final r in token.runes) String.fromCharCode(r)];
    while (word.length > 1) {
      var best = -1, bestRank = 1 << 30;
      for (var i = 0; i + 1 < word.length; i++) {
        final r = _ranks['${word[i]} ${word[i + 1]}'];
        if (r != null && r < bestRank) {
          bestRank = r;
          best = i;
        }
      }
      if (best < 0) break;
      final a = word[best], b = word[best + 1];
      final next = <String>[];
      for (var i = 0; i < word.length;) {
        if (i + 1 < word.length && word[i] == a && word[i + 1] == b) {
          next.add(a + b);
          i += 2;
        } else {
          next.add(word[i]);
          i++;
        }
      }
      word = next;
    }
    if (_cache.length < 20000) _cache[token] = word;
    return word;
  }

  // GPT-2's reversible byte <-> printable character map.
  static final Map<int, int> _byteToUnicode = () {
    final bs = <int>[
      for (var b = 0x21; b <= 0x7E; b++) b,
      for (var b = 0xA1; b <= 0xAC; b++) b,
      for (var b = 0xAE; b <= 0xFF; b++) b,
    ];
    final cs = [...bs];
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    return {for (var i = 0; i < bs.length; i++) bs[i]: cs[i]};
  }();
  static final Map<int, int> _unicodeToByte = {for (final e in _byteToUnicode.entries) e.value: e.key};
}
