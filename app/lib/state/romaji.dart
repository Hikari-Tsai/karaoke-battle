// Japanese -> romaji for lyrics. Readings come from kuromoji (katakana per
// token, with part of speech); this file turns them into Hepburn romaji with
// karaoke-friendly word spacing. Pure Dart, unit tested.

/// One kuromoji token: surface, katakana reading (null when unknown), part of
/// speech and its first detail (IPADIC tags).
class JaToken {
  const JaToken(this.surface, this.reading, this.pos, this.pos1);
  final String surface;
  final String? reading;
  final String pos;
  final String pos1;

  static JaToken fromJson(Map<String, dynamic> j) =>
      JaToken(j['s'] as String? ?? '', j['r'] as String?, j['p'] as String? ?? '', j['p1'] as String? ?? '');
}

const _mono = <String, String>{
  'ア': 'a', 'イ': 'i', 'ウ': 'u', 'エ': 'e', 'オ': 'o',
  'カ': 'ka', 'キ': 'ki', 'ク': 'ku', 'ケ': 'ke', 'コ': 'ko',
  'ガ': 'ga', 'ギ': 'gi', 'グ': 'gu', 'ゲ': 'ge', 'ゴ': 'go',
  'サ': 'sa', 'シ': 'shi', 'ス': 'su', 'セ': 'se', 'ソ': 'so',
  'ザ': 'za', 'ジ': 'ji', 'ズ': 'zu', 'ゼ': 'ze', 'ゾ': 'zo',
  'タ': 'ta', 'チ': 'chi', 'ツ': 'tsu', 'テ': 'te', 'ト': 'to',
  'ダ': 'da', 'ヂ': 'ji', 'ヅ': 'zu', 'デ': 'de', 'ド': 'do',
  'ナ': 'na', 'ニ': 'ni', 'ヌ': 'nu', 'ネ': 'ne', 'ノ': 'no',
  'ハ': 'ha', 'ヒ': 'hi', 'フ': 'fu', 'ヘ': 'he', 'ホ': 'ho',
  'バ': 'ba', 'ビ': 'bi', 'ブ': 'bu', 'ベ': 'be', 'ボ': 'bo',
  'パ': 'pa', 'ピ': 'pi', 'プ': 'pu', 'ペ': 'pe', 'ポ': 'po',
  'マ': 'ma', 'ミ': 'mi', 'ム': 'mu', 'メ': 'me', 'モ': 'mo',
  'ヤ': 'ya', 'ユ': 'yu', 'ヨ': 'yo',
  'ラ': 'ra', 'リ': 'ri', 'ル': 'ru', 'レ': 're', 'ロ': 'ro',
  'ワ': 'wa', 'ヰ': 'i', 'ヱ': 'e', 'ヲ': 'o', 'ヴ': 'vu',
  'ァ': 'a', 'ィ': 'i', 'ゥ': 'u', 'ェ': 'e', 'ォ': 'o',
  'ャ': 'ya', 'ュ': 'yu', 'ョ': 'yo', 'ヮ': 'wa', 'ヵ': 'ka', 'ヶ': 'ke',
};

const _di = <String, String>{
  'キャ': 'kya', 'キュ': 'kyu', 'キョ': 'kyo', 'ギャ': 'gya', 'ギュ': 'gyu', 'ギョ': 'gyo',
  'シャ': 'sha', 'シュ': 'shu', 'ショ': 'sho', 'ジャ': 'ja', 'ジュ': 'ju', 'ジョ': 'jo',
  'チャ': 'cha', 'チュ': 'chu', 'チョ': 'cho', 'ヂャ': 'ja', 'ヂュ': 'ju', 'ヂョ': 'jo',
  'ニャ': 'nya', 'ニュ': 'nyu', 'ニョ': 'nyo', 'ヒャ': 'hya', 'ヒュ': 'hyu', 'ヒョ': 'hyo',
  'ビャ': 'bya', 'ビュ': 'byu', 'ビョ': 'byo', 'ピャ': 'pya', 'ピュ': 'pyu', 'ピョ': 'pyo',
  'ミャ': 'mya', 'ミュ': 'myu', 'ミョ': 'myo', 'リャ': 'rya', 'リュ': 'ryu', 'リョ': 'ryo',
  // loanword sounds
  'シェ': 'she', 'ジェ': 'je', 'チェ': 'che', 'イェ': 'ye',
  'ファ': 'fa', 'フィ': 'fi', 'フェ': 'fe', 'フォ': 'fo', 'フュ': 'fyu',
  'ティ': 'ti', 'トゥ': 'tu', 'テュ': 'tyu', 'ディ': 'di', 'ドゥ': 'du', 'デュ': 'dyu',
  'ウィ': 'wi', 'ウェ': 'we', 'ウォ': 'wo',
  'ヴァ': 'va', 'ヴィ': 'vi', 'ヴェ': 've', 'ヴォ': 'vo', 'ヴュ': 'vyu',
  'ツァ': 'tsa', 'ツィ': 'tsi', 'ツェ': 'tse', 'ツォ': 'tso',
  'クァ': 'kwa', 'クィ': 'kwi', 'クェ': 'kwe', 'クォ': 'kwo', 'グァ': 'gwa',
};

const _vowels = 'aiueo';

/// Hiragana to katakana (other characters unchanged).
String toKatakana(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r >= 0x3041 && r <= 0x3096 ? r + 0x60 : r);
  }
  return b.toString();
}

bool _isKana(int r) => (r >= 0x3041 && r <= 0x309F) || (r >= 0x30A0 && r <= 0x30FF);

/// True when [s] is made only of kana (and the prolonged sound mark).
bool isKana(String s) => s.isNotEmpty && s.runes.every(_isKana);

/// Katakana / hiragana to Hepburn romaji. ッ doubles the next consonant
/// (tch before ch), ン becomes n' before a vowel or y, ー repeats the
/// previous vowel. Non-kana characters are copied as is.
String kanaToRomaji(String kana) {
  final k = toKatakana(kana);
  final chars = k.split('');
  final out = StringBuffer();
  var geminate = false;
  var i = 0;
  String lastVowel() {
    final s = out.toString();
    for (var j = s.length - 1; j >= 0; j--) {
      if (_vowels.contains(s[j])) return s[j];
    }
    return '';
  }

  while (i < chars.length) {
    final c = chars[i];
    if (c == 'ッ') {
      geminate = true;
      i++;
      continue;
    }
    if (c == 'ー') {
      out.write(lastVowel());
      i++;
      continue;
    }
    String? syl;
    if (i + 1 < chars.length) syl = _di['${chars[i]}${chars[i + 1]}'];
    var used = syl != null ? 2 : 1;
    if (c == 'ン') {
      // n' before a vowel or y so it is not read as na / nya.
      String? next;
      if (i + 1 < chars.length) {
        next = (i + 2 < chars.length ? _di['${chars[i + 1]}${chars[i + 2]}'] : null) ?? _mono[chars[i + 1]];
      }
      syl = next != null && (_vowels.contains(next[0]) || next[0] == 'y') ? "n'" : 'n';
      used = 1;
    }
    syl ??= _mono[c];
    if (syl == null) {
      out.write(c);
      geminate = false;
      i++;
      continue;
    }
    if (geminate) {
      if (!_vowels.contains(syl[0]) && syl[0] != 'n') out.write(syl.startsWith('ch') ? 't' : syl[0]);
      geminate = false;
    }
    out.write(syl);
    i += used;
  }
  return out.toString();
}

/// Particles read differently from their kana.
String? _particle(JaToken t) {
  if (t.pos != '助詞') return null;
  return switch (t.surface) {
    'は' => 'wa',
    'へ' => 'e',
    'を' => 'o',
    _ => null,
  };
}

const _attachConj = {'て', 'で', 'ちゃ', 'じゃ', 'ば', 'たら', 'だら', 'ちゃう'};

/// Whether [t] is written joined to the previous word (inflections, verb
/// suffixes, -te / -cha connectors) rather than as its own word.
bool _attaches(JaToken t, JaToken? prev) {
  if (prev == null) return false;
  final inflecting = prev.pos == '動詞' || prev.pos == '形容詞' || prev.pos == '助動詞';
  if (t.pos == '助動詞') return inflecting;
  if (t.pos == '動詞' && t.pos1 == '接尾') return true;
  if ((t.pos == '名詞' || t.pos == '形容詞') && t.pos1 == '接尾') return true;
  if (t.pos == '助詞' && t.pos1 == '接続助詞' && _attachConj.contains(t.surface)) return inflecting;
  return false;
}

/// Romaji for one lyric line from its tokens. Words are separated by spaces;
/// punctuation keeps a light Latin equivalent; tokens without a reading keep
/// their surface (kana surfaces are transliterated directly).
String tokensToRomaji(List<JaToken> tokens) {
  final words = <String>[];
  JaToken? prev;
  for (final t in tokens) {
    if (t.pos == '記号') {
      final p = switch (t.surface) {
        '、' || '，' || ',' => ',',
        '。' || '．' => '.',
        '？' || '?' => '?',
        '！' || '!' => '!',
        '…' || '‥' => '…',
        _ => null,
      };
      if (p != null && words.isNotEmpty) words[words.length - 1] += p;
      prev = null; // spaces and punctuation break attachment
      continue;
    }
    final reading = t.reading ?? (isKana(t.surface) ? t.surface : null);
    final romaji = _particle(t) ?? (reading != null ? kanaToRomaji(reading) : t.surface);
    if (romaji.isEmpty) continue;
    if (_attaches(t, prev) && words.isNotEmpty) {
      words[words.length - 1] += romaji;
    } else {
      words.add(romaji);
    }
    prev = t;
  }
  return words.join(' ');
}
