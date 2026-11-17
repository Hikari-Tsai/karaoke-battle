// The "AI analysis" export: one Markdown file holding instructions for a
// general-purpose AI assistant plus the take's analysis (see
// take_analysis.dart), in zh-TW, English or Japanese. The user takes the
// file to the assistant of their choice; the app itself sends nothing.
//
// Every number in the file comes from the analysis; the instructions tell
// the assistant to cite findings by id and lyric line and not to compute or
// guess anything else.
library;

import 'take_analysis.dart';

/// Version of the instructions, written into the file so answers can be
/// traced back to the prompt that produced them.
const advicePromptVersion = 1;

/// Builds the Markdown file for [a] in [lang] (zh, en or ja).
String buildAdvicePrompt(TakeAnalysis a, {required String lang, bool includeTitle = true, String appVersion = ''}) {
  final t = _Texts(lang);
  final b = StringBuffer();
  final title = a.input.songTitle.trim();
  final song = includeTitle && title.isNotEmpty ? (a.input.artist.trim().isEmpty ? title : '$title — ${a.input.artist.trim()}') : t.s('song.hidden');

  b.writeln('# ${t.s('title')}');
  b.writeln();
  b.writeln('> ${t.s('intro')}');
  b.writeln();

  // --- instructions ---------------------------------------------------------
  b.writeln('## ${t.s('h.instructions')}');
  b.writeln();
  b.writeln(t.s('role'));
  b.writeln();
  b.writeln(t.s('rules.title'));
  final rules = t.s('rules').split('\n');
  for (var i = 0; i < rules.length; i++) {
    b.writeln('${i + 1}. ${rules[i]}');
  }
  b.writeln();
  b.writeln(t.s('format.title'));
  for (final l in t.s('format').split('\n')) {
    b.writeln('- $l');
  }
  b.writeln();

  // --- glossary ---------------------------------------------------------------
  b.writeln('## ${t.s('h.glossary')}');
  b.writeln();
  final w = a.rhythmWindowsMs;
  for (final l in t.s('glossary').split('\n')) {
    b.writeln('- $l');
  }
  if (w != null) {
    b.writeln('- ${t.s('glossary.rhythm', {'p': w.perfect.round(), 'g': w.great.round(), 'd': w.good.round()})}');
  }
  b.writeln();

  // --- overview ---------------------------------------------------------------
  b.writeln('## ${t.s('h.overview')}');
  b.writeln();
  b.writeln('| ${t.s('col.item')} | ${t.s('col.value')} |');
  b.writeln('|---|---|');
  b.writeln('| ${t.s('ov.song')} | ${_cell(song)} |');
  b.writeln('| ${t.s('ov.total')} | ${a.total.toStringAsFixed(1)}（${a.rank}） |');
  for (final e in a.subScores.entries) {
    final v = e.value;
    final weight = a.weights[e.key];
    b.writeln('| ${t.s('sub.${e.key}')}${weight == null ? '' : ' (${t.s('ov.weight')} ${weight.round()})'} | ${v == null ? t.s('na') : v.round()} |');
  }
  final c = a.rhythmCounts;
  b.writeln('| ${t.s('ov.rhythm')} | PERFECT ${c['perfect']} / GREAT ${c['great']} / GOOD ${c['good']} / MISS ${c['miss']} |');
  b.writeln('| ${t.s('ov.tendency')} | ${t.s('tendency.${a.rhythmTendency}', {'ms': (a.rhythmTendencyMs ?? 0).abs().round()})} |');
  b.writeln('| ${t.s('ov.key')} | ${t.s('ov.keyValue', {'shift': _signed(a.input.pitchShift.round())})} |');
  for (final r in a.registers) {
    b.writeln('| ${t.s('reg.${r.label}')} (${r.range}) | ${t.s('reg.value', {'m': r.matched, 'n': r.evaluable, 'c': _cents(r.medianCents, t), 'u': r.unsung})} |');
  }
  if (a.input.ownRange != null) {
    final o = a.input.ownRange!;
    b.writeln('| ${t.s('ov.ownRange')} | ${_noteRange(o.low, o.high)} |');
  }
  b.writeln();

  // --- findings -----------------------------------------------------------------
  b.writeln('## ${t.s('h.findings')}');
  b.writeln();
  if (a.findings.isEmpty) b.writeln(t.s('findings.none'));
  for (final f in a.findings) {
    b.writeln('- **[${f.id}] ${t.s('kind.${f.kind}')}**${f.positive ? ' ✓' : ''} — ${_describe(f, a, t)}');
  }
  b.writeln();

  // --- lines ----------------------------------------------------------------------
  b.writeln('## ${t.s('h.lines')}');
  b.writeln();
  if (!a.hasLyrics) {
    b.writeln(t.s('lines.noLyrics'));
    b.writeln();
  }
  b.writeln('| # | ${t.s('col.time')} | ${t.s('col.lyric')} | ${t.s('col.range')} | ${t.s('col.hit')} | ${t.s('col.cents')} | ${t.s('col.sharpFlat')} | ${t.s('col.unsung')} | P/G/G/M | ${t.s('col.onset')} | ${t.s('col.release')} |');
  b.writeln('|---|---|---|---|---|---|---|---|---|---|---|');
  for (final l in a.lines) {
    final r = l.rhythm;
    b.writeln([
      '',
      '${l.number}',
      _time(l.start),
      _cell(l.lyric ?? '—'),
      l.range,
      '${l.matched}/${l.evaluable}',
      l.medianCents == null ? '—' : _signed(l.medianCents!.round()),
      '${l.sharp}/${l.flat}',
      '${l.unsung}',
      '${r['perfect']}/${r['great']}/${r['good']}/${r['miss']}',
      l.medianOnsetMs == null ? '—' : _signed(l.medianOnsetMs!.round()),
      l.longNotes == 0 ? '—' : '${l.earlyReleases}/${l.longNotes}',
      '',
    ].join(' | ').trim());
  }
  b.writeln();
  b.writeln(t.s('lines.legend'));
  b.writeln();

  // --- history ----------------------------------------------------------------------
  if (a.previous != null) {
    b.writeln('## ${t.s('h.history')}');
    b.writeln();
    b.writeln(t.s('history.count', {'n': a.historyCount}));
    b.writeln();
    b.writeln('| ${t.s('col.item')} | ${t.s('history.now')} | ${t.s('history.previous')} | ${t.s('history.best')} |');
    b.writeln('|---|---|---|---|');
    final p = a.previous!, best = a.best!;
    b.writeln('| ${t.s('ov.total')} | ${a.total.toStringAsFixed(1)} | ${p.total.toStringAsFixed(1)} | ${best.total.toStringAsFixed(1)} |');
    for (final k in a.subScores.keys) {
      String v(double? x) => x == null ? '—' : '${x.round()}';
      b.writeln('| ${t.s('sub.$k')} | ${v(a.subScores[k])} | ${v(p.subScores[k])} | ${v(best.subScores[k])} |');
    }
    b.writeln();
  }

  b.writeln('---');
  b.writeln(t.s('footer', {'v': advicePromptVersion, 'app': appVersion.isEmpty ? '' : ' $appVersion'}));
  return b.toString();
}

/// One finding as a sentence, with the lines it is about.
String _describe(Finding f, TakeAnalysis a, _Texts t) {
  final d = f.data;
  final text = switch (f.kind) {
    'weak_line' => t.s('d.weak_line', {
        'm': d['matched'],
        'n': d['evaluable'],
        'c': _cents(d['median_cents'], t),
        's': d['sharp'],
        'f': d['flat'],
        'u': d['unsung'],
        'r': d['range'],
      }),
    'sharp_overall' || 'flat_overall' => t.s('d.bias', {'c': _cents(d['median_cents'], t), 'n': d['notes']}),
    'high_register' || 'low_register' => t.s('d.register', {
        'r': d['range'],
        'a': d['accuracy'],
        'o': d['overall_accuracy'],
        'c': _cents(d['median_cents'], t),
        'u': d['unsung'],
      }),
    'out_of_range' => t.s('d.out_of_range.${d['fit']}', {
        'own': d['own_range'],
        'song': d['song_tessitura'],
        'n': d['semitones'],
        'above': d['time_above'],
        'below': d['time_below'],
        'acc': d['accuracy_outside'] ?? t.s('na'),
        'now': _signed(d['current_key_change'] as int),
        'best': _signed(d['suggested_key_change'] as int),
      }),
    'unsung' => t.s('d.unsung', {'u': d['unsung'], 'n': d['evaluable']}),
    'rushing' || 'dragging' => t.s('d.${f.kind}', {'ms': (d['median_ms'] as int).abs()}),
    'timing_lines' => t.s('d.timing_lines'),
    'early_release' => t.s('d.early_release', {'e': d['early'], 'n': d['long_notes'], 'ms': (d['median_offset_ms'] as int).abs()}),
    'unsteady_long_notes' => t.s(d['reference_cents'] == null ? 'd.unsteady' : 'd.unsteady.ref', {
          's': d['stability_cents'],
          'r': d['reference_cents'],
        }) +
        [
          for (final n in (d['notes'] as List).cast<Map>())
            t.s('d.unsteady.note', {'l': n['line'] ?? '?', 'note': n['note'], 's': n['stability_cents']}),
        ].join(),
    'little_vibrato' => t.s('d.little_vibrato', {'a': d['amount'], 'r': d['reference_amount']}),
    'flat_dynamics' => t.s('d.flat_dynamics', {'r': d['correlation']}),
    'regression' => t.s('d.regression', {'t': _signedNum(d['total_change']), 'k': _subList(d['dropped'], t, signed: true)}),
    'strong_scores' => t.s('d.strong_scores', {'k': _subList(d, t)}),
    'clean_lines' => t.s('d.clean_lines'),
    'progress' => t.s('d.progress', {'t': _signedNum(d['total_change']), 'k': (d['improved'] as Map).isEmpty ? '—' : _subList(d['improved'], t, signed: true)}),
    _ => d.toString(),
  };
  final refs = [
    for (final n in f.lines)
      if (n >= 1 && n <= a.lines.length) _lineRef(a.lines[n - 1], t),
  ];
  if (f.kind == 'timing_lines') {
    final parts = [
      for (final n in f.lines)
        if (d['line_$n'] is Map)
          '${_lineRef(a.lines[n - 1], t)}${t.s('d.timing_line', {'b': (d['line_$n'] as Map)['good_or_miss'], 'n': (d['line_$n'] as Map)['sung'], 'ms': _ms((d['line_$n'] as Map)['median_onset_ms'], t)})}',
    ];
    return '$text${t.s('space')}${parts.join(t.s('sep'))}';
  }
  if (refs.isEmpty) return text;
  // clean_lines' sentence already ends by introducing the lines.
  final label = f.kind == 'clean_lines' ? '' : t.s('d.lines');
  return '$text${t.s('space')}$label${refs.join(t.s('sep'))}';
}

String _lineRef(LineStats l, _Texts t) {
  final lyric = l.lyric == null ? '' : t.s('quote', {'q': _inline(l.lyric!)});
  return t.s('lineRef', {'n': l.number, 'lyric': lyric, 'time': _time(l.start)});
}

/// "Pitch 92; Rhythm 90" from a sub-score map; [signed] for changes.
String _subList(Object? m, _Texts t, {bool signed = false}) {
  if (m is! Map) return '—';
  return [
    for (final e in m.entries)
      if (e.key is String && e.value is num) '${t.s('sub.${e.key}')} ${signed ? _signed((e.value as num).round()) : (e.value as num).round()}',
  ].join(t.s('sep'));
}

String _signed(int v) => v > 0 ? '+$v' : '$v';
String _signedNum(Object? v) => v is num ? (v > 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1)) : '—';
String _cents(Object? v, _Texts t) => v is num ? t.s('unit.cents', {'v': _signed(v.round())}) : t.s('na');
String _ms(Object? v, _Texts t) => v is num ? '${_signed(v.round())} ms' : t.s('na');

String _time(double s) {
  final m = s ~/ 60;
  final sec = (s - m * 60).floor();
  return '$m:${sec.toString().padLeft(2, '0')}';
}

String _noteRange(double low, double high) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  String n(double m) => '${names[m.round() % 12]}${m.round() ~/ 12 - 1}';
  return '${n(low)}–${n(high)}';
}

/// Text inside a table cell: no pipes or line breaks.
String _cell(String s) => s.replaceAll('|', '／').replaceAll(RegExp(r'[\r\n]+'), ' ');
String _inline(String s) => s.replaceAll(RegExp(r'[\r\n]+'), ' ');

class _Texts {
  _Texts(String lang) : _i = switch (lang) { 'en' => 1, 'ja' => 2, _ => 0 };
  final int _i;

  String s(String key, [Map<String, Object?>? args]) {
    final e = _strings[key];
    var out = e == null ? key : [e.$1, e.$2, e.$3][_i];
    args?.forEach((k, v) => out = out.replaceAll('{$k}', '${v ?? ''}'));
    return out;
  }
}

// (zh-TW, English, 日本語)
const Map<String, (String, String, String)> _strings = {
  'title': ('Karaoke Battle 演唱分析', 'Karaoke Battle singing analysis', 'Karaoke Battle 歌唱分析'),
  'intro': (
    '把這整份檔案交給 ChatGPT、Claude、Gemini 等 AI 助理（上傳或貼上），就能得到演唱建議。檔案裡只有評分數據與歌詞，不含錄音。',
    'Give this whole file to an AI assistant such as ChatGPT, Claude or Gemini (upload or paste it) to get singing advice. It holds only scoring data and lyrics, no recording.',
    'このファイルをまるごと ChatGPT・Claude・Gemini などの AI アシスタントに渡す（アップロードまたは貼り付け）と、歌唱アドバイスがもらえます。中身は採点データと歌詞だけで、録音は含まれません。',
  ),
  'song.hidden': ('（未提供）', '(not given)', '（非公開）'),
  'h.instructions': ('給 AI 的指示', 'Instructions for the AI', 'AI への指示'),
  'role': (
    '你是一位專業又親切的歌唱教練。以下是卡拉 OK 評分軟體 Karaoke Battle 對使用者一次演唱的客觀量測結果（以原唱人聲為基準）。請根據這些數據，給使用者具體、可以馬上練習的演唱建議。',
    'You are a professional, friendly singing coach. Below are objective measurements that the karaoke scoring app Karaoke Battle made of one of the user\'s takes (judged against the original vocal). Based on this data, give the user concrete singing advice they can practise right away.',
    'あなたはプロで親しみやすいボイストレーナーです。以下は、カラオケ採点アプリ Karaoke Battle がユーザーの 1 回の歌唱を（原曲のボーカルを基準に）客観的に測定した結果です。このデータをもとに、すぐ練習できる具体的な歌唱アドバイスをしてください。',
  ),
  'rules.title': ('規則：', 'Rules:', 'ルール：'),
  'rules': (
    '只根據本檔案的數據說話。你沒有聽到錄音，不要評論數據裡沒有的事（例如音色、咬字、情感、氣息聲）。\n'
        '每條建議都要標出所根據的發現編號（例如 [F2]），有歌詞時引用該句歌詞原文與時間。\n'
        '直接引用檔案裡的數字，不要自行計算、換算或估計新的數字。\n'
        '音高偏差是相對於演唱者實際唱的調：評分允許整首移調，也不分八度，所以不要說「唱錯調」或「唱低八度」，音域問題只依「音域」相關的發現討論。\n'
        '發現已依重要性排序，標 ✓ 的是做得好的地方或進步。\n'
        '用繁體中文（台灣用語）回答，歌詞維持原文。',
    'Only use the data in this file. You have not heard the recording, so do not comment on anything the data does not cover (tone, diction, emotion, breathiness).\n'
        'Tag every piece of advice with the finding ids it is based on (for example [F2]) and, when there are lyrics, quote the lyric line and its time.\n'
        'Quote numbers from the file as they are; do not calculate, convert or estimate new numbers.\n'
        'Pitch deviations are relative to the key the singer actually sang in: the scoring allows a whole-song key change and ignores octaves, so never say they sang in the wrong key or octave; discuss range only through the range findings.\n'
        'Findings are ranked by importance; ones marked ✓ are strengths or improvements.\n'
        'Answer in English and keep lyrics in their original language.',
    'このファイルのデータだけを根拠にしてください。録音は聞いていないので、データにないこと（声色・滑舌・感情・息の混じり方など）には触れないでください。\n'
        '各アドバイスに根拠となる発見番号（例：[F2]）を付け、歌詞がある場合はその行の歌詞と時間を引用してください。\n'
        '数値はファイルの値をそのまま引用し、新しい数値を計算・換算・推測しないでください。\n'
        '音程のずれは歌い手が実際に歌ったキーに対する値です。採点は曲全体の移調を認め、オクターブも区別しないので、「キーが違う」「1 オクターブ低い」とは言わず、音域の問題は音域に関する発見だけで扱ってください。\n'
        '発見は重要度順で、✓ が付いたものはよくできた点や上達した点です。\n'
        '日本語で答え、歌詞は原文のままにしてください。',
  ),
  'format.title': ('回答格式：', 'Answer format:', '回答の形式：'),
  'format': (
    '開頭一到兩句總評，先說做得好的地方。\n'
        '接著 3 到 5 條建議，依重要性排序。每條包含：標題、根據（[F#]、歌詞與時間）、問題說明、一個具體的練習方法。\n'
        '最後一句鼓勵，並提醒下一次唱的時候最該注意的一件事。',
    'Start with one or two sentences of overall feedback, beginning with what went well.\n'
        'Then 3 to 5 pieces of advice, most important first. Each has a title, its basis ([F#], lyric line and time), what the problem is and one concrete exercise.\n'
        'End with a sentence of encouragement and the one thing to focus on next time.',
    '最初に 1〜2 文の総評（よかった点から）。\n'
        '続いて重要度順に 3〜5 個のアドバイス。それぞれにタイトル、根拠（[F#]、歌詞と時間）、問題の説明、具体的な練習方法を 1 つ。\n'
        '最後に励ましの一言と、次に歌うとき一番意識すべきことを 1 つ。',
  ),
  'h.glossary': ('名詞說明', 'Terms', '用語'),
  'glossary': (
    'cents：音高單位，100 cents = 1 個半音。正值是偏高，負值是偏低，±50 cents 以內算唱準。\n'
        '命中：該音有一半以上的時間唱在 ±50 cents 以內。\n'
        '沒出聲：該音的時間內出聲不到 30%。\n'
        '起音：開始唱這個音的時間和原唱相比，負值是搶拍（太早），正值是拖拍（太晚）。\n'
        '長音穩定度：長音扣掉顫音後的音高標準差（cents），越小越穩。',
    'cents: pitch unit, 100 cents = 1 semitone. Positive is sharp, negative is flat; within ±50 cents counts as in tune.\n'
        'Hit: the note was sung within ±50 cents for at least half of its length.\n'
        'Not sung: voice was heard for less than 30 % of the note.\n'
        'Onset: when the note was started compared with the original; negative is early (rushing), positive is late (dragging).\n'
        'Long-note stability: standard deviation of pitch on long notes with vibrato removed (cents); smaller is steadier.',
    'cent：音程の単位。100 cent = 半音 1 つ。正は高め、負は低め、±50 cent 以内なら音程が合っているとみなします。\n'
        'ヒット：その音の半分以上の時間を ±50 cent 以内で歌えた。\n'
        '無声：その音の間、声が出ていたのが 30% 未満。\n'
        '入り：原曲と比べた歌い出しのずれ。負は早い（走り）、正は遅い（もたり）。\n'
        'ロングトーンの安定度：ビブラートを除いたロングトーンの音程の標準偏差（cent）。小さいほど安定。',
  ),
  'glossary.rhythm': (
    '節奏判定（依曲速調整）：PERFECT ≤{p} ms、GREAT ≤{g} ms、GOOD ≤{d} ms，超過或沒唱為 MISS。',
    'Timing judgements (scaled by tempo): PERFECT ≤{p} ms, GREAT ≤{g} ms, GOOD ≤{d} ms, beyond that or not sung is MISS.',
    'タイミング判定（テンポで調整）：PERFECT ≤{p} ms、GREAT ≤{g} ms、GOOD ≤{d} ms、それ以上または歌っていないと MISS。',
  ),
  'h.overview': ('演唱概況', 'Overview', '概要'),
  'col.item': ('項目', 'Item', '項目'),
  'col.value': ('數值', 'Value', '値'),
  'ov.song': ('歌曲', 'Song', '曲'),
  'ov.total': ('總分', 'Total', '総合点'),
  'ov.weight': ('權重', 'weight', '配点'),
  'ov.rhythm': ('節奏判定（起音）', 'Timing (onsets)', 'タイミング判定（入り）'),
  'ov.tendency': ('整體節奏傾向', 'Overall timing', '全体のタイミング傾向'),
  'ov.key': ('移調', 'Key change', 'キー変更'),
  'ov.keyValue': ('{shift} 個半音（相對原調）', '{shift} semitones (from the original key)', '{shift} 半音（原曲キーから）'),
  'ov.ownRange': ('使用者測得的音域', 'The singer\'s measured range', '測定した本人の音域'),
  'reg.high': ('高音區（最高的 1/4 音）', 'High register (top quarter of notes)', '高音域（上位 1/4 の音）'),
  'reg.low': ('低音區（最低的 1/4 音）', 'Low register (bottom quarter of notes)', '低音域（下位 1/4 の音）'),
  'reg.value': ('命中 {m}/{n}，音高中位 {c}，沒出聲 {u}', 'hit {m}/{n}, median {c}, not sung {u}', 'ヒット {m}/{n}、音程の中央値 {c}、無声 {u}'),
  'unit.cents': ('{v} cents', '{v} cents', '{v} cent'),
  'sub.pitch': ('音準', 'Pitch', '音程'),
  'sub.rhythm': ('節奏', 'Rhythm', 'リズム'),
  'sub.stability': ('穩定度', 'Stability', '安定感'),
  'sub.vibrato': ('顫音', 'Vibrato', 'ビブラート'),
  'sub.expression': ('表現力', 'Expression', '抑揚'),
  'sub.long_tone': ('長音', 'Long tone', 'ロングトーン'),
  'na': ('無法評估', 'n/a', '評価なし'),
  'tendency.rushing': ('偏早約 {ms} ms（搶拍）', 'about {ms} ms early (rushing)', '約 {ms} ms 早い（走り気味）'),
  'tendency.dragging': ('偏晚約 {ms} ms（拖拍）', 'about {ms} ms late (dragging)', '約 {ms} ms 遅い（もたり気味）'),
  'tendency.steady': ('穩定（約 {ms} ms）', 'steady (about {ms} ms)', '安定（約 {ms} ms）'),
  'tendency.none': ('無法判斷（錄音時間沒有校準）', 'not measurable (recording clock not calibrated)', '判定できません（録音のタイミングが未校正）'),
  'h.findings': ('主要發現', 'Findings', '主な発見'),
  'findings.none': ('沒有明顯的問題。', 'No clear problems.', 'はっきりした問題はありません。'),
  'kind.weak_line': ('不太準的句子', 'Inaccurate line', '音程が不安定な行'),
  'kind.sharp_overall': ('整體偏高', 'Sharp overall', '全体に高め'),
  'kind.flat_overall': ('整體偏低', 'Flat overall', '全体に低め'),
  'kind.high_register': ('高音區比較不準', 'High notes less accurate', '高音域が不安定'),
  'kind.low_register': ('低音區比較不準', 'Low notes less accurate', '低音域が不安定'),
  'kind.out_of_range': ('歌曲超出使用者音域', 'Song outside the singer\'s range', '曲が本人の音域を超えている'),
  'kind.unsung': ('有些音沒唱出來', 'Notes not sung', '歌えていない音がある'),
  'kind.rushing': ('有搶拍傾向', 'Rushing', '走り気味'),
  'kind.dragging': ('有拖拍傾向', 'Dragging', 'もたり気味'),
  'kind.timing_lines': ('這幾句進拍不準', 'Lines with off-beat entries', '入りがずれた行'),
  'kind.early_release': ('長音提早收', 'Long notes cut short', 'ロングトーンを早く切っている'),
  'kind.unsteady_long_notes': ('長音不穩', 'Unsteady long notes', 'ロングトーンが不安定'),
  'kind.little_vibrato': ('顫音比原唱少', 'Less vibrato than the original', 'ビブラートが原曲より少ない'),
  'kind.flat_dynamics': ('強弱起伏和原唱不同', 'Dynamics differ from the original', '強弱の付け方が原曲と違う'),
  'kind.regression': ('比上一次退步的項目', 'Worse than last time', '前回より下がった項目'),
  'kind.strong_scores': ('表現好的項目', 'Strong areas', 'よくできた項目'),
  'kind.clean_lines': ('完美的句子', 'Clean lines', '完璧だった行'),
  'kind.progress': ('比上一次進步', 'Better than last time', '前回より上達'),
  'd.weak_line': (
    '命中 {m}/{n} 個音，音高中位 {c}（偏高 {s}、偏低 {f}），沒出聲 {u} 個，音域 {r}。',
    '{m}/{n} notes hit, median {c} ({s} sharp, {f} flat), {u} not sung, range {r}.',
    '{n} 音中 {m} 音ヒット、音程の中央値 {c}（高め {s}・低め {f}）、無声 {u}、音域 {r}。',
  ),
  'd.bias': ('全曲 {n} 個音的音高中位是 {c}。', 'The median of {n} notes is {c}.', '全 {n} 音の音程の中央値は {c}。'),
  'd.register': (
    '{r} 的命中率 {a}%，全曲是 {o}%；音高中位 {c}，沒出聲 {u} 個。',
    '{r}: {a} % hit against {o} % for the whole song; median {c}, {u} not sung.',
    '{r} のヒット率 {a}%（曲全体は {o}%）、音程の中央値 {c}、無声 {u}。',
  ),
  'd.out_of_range.high': (
    '使用者音域 {own}，歌曲主要音域（換算到最接近使用者音域的八度）{song}，高出約 {n} 個半音，{above}% 的歌唱時間在音域之上，那些音的命中率 {acc}%。目前移調 {now}，建議移調 {best}（相對原調）。',
    'Singer\'s range {own}; the song\'s main range (in the octave closest to the singer\'s range) is {song}, about {n} semitones too high, with {above} % of the sung time above the range and {acc} % of those notes hit. Current key change {now}; suggested {best} (from the original key).',
    '本人の音域は {own}、曲の主な音域（本人の音域に最も近いオクターブで）は {song} で約 {n} 半音高く、歌唱時間の {above}% が音域より上、その音のヒット率は {acc}%。現在のキー変更 {now}、おすすめは {best}（原曲キーから）。',
  ),
  'd.out_of_range.low': (
    '使用者音域 {own}，歌曲主要音域（換算到最接近使用者音域的八度）{song}，低了約 {n} 個半音，{below}% 的歌唱時間在音域之下，那些音的命中率 {acc}%。目前移調 {now}，建議移調 {best}（相對原調）。',
    'Singer\'s range {own}; the song\'s main range (in the octave closest to the singer\'s range) is {song}, about {n} semitones too low, with {below} % of the sung time below the range and {acc} % of those notes hit. Current key change {now}; suggested {best} (from the original key).',
    '本人の音域は {own}、曲の主な音域（本人の音域に最も近いオクターブで）は {song} で約 {n} 半音低く、歌唱時間の {below}% が音域より下、その音のヒット率は {acc}%。現在のキー変更 {now}、おすすめは {best}（原曲キーから）。',
  ),
  'd.out_of_range.wide': (
    '使用者音域 {own}，這首歌的主要音域 {song} 比使用者音域還寬（{above}% 的時間在上方、{below}% 在下方），移調也無法完全放進去。目前移調 {now}，最接近的是 {best}（相對原調）。',
    'Singer\'s range {own}; the song spans {song}, wider than the range ({above} % of the time above, {below} % below), so no key fits it entirely. Current key change {now}; closest {best} (from the original key).',
    '本人の音域は {own}、曲の主な音域 {song} はそれより広く（上に {above}%、下に {below}%）、どのキーでも収まりません。現在のキー変更 {now}、最も近いのは {best}（原曲キーから）。',
  ),
  'd.unsung': ('{n} 個音裡有 {u} 個幾乎沒出聲。', '{u} of {n} notes were barely sung.', '{n} 音中 {u} 音がほとんど声になっていません。'),
  'd.rushing': ('有唱到的音，起音中位比原唱早約 {ms} ms。', 'Sung notes start about {ms} ms before the original (median).', '歌えた音の入りが原曲より約 {ms} ms 早い（中央値）。'),
  'd.dragging': ('有唱到的音，起音中位比原唱晚約 {ms} ms。', 'Sung notes start about {ms} ms after the original (median).', '歌えた音の入りが原曲より約 {ms} ms 遅い（中央値）。'),
  'd.timing_lines': ('以下句子有較多音的起音只拿到 GOOD 或 MISS：', 'In these lines many sung notes started only GOOD or MISS:', '次の行は、歌えた音の入りの多くが GOOD か MISS でした：'),
  'd.timing_line': ('（{n} 個有唱的音裡 {b} 個，起音中位 {ms}）', ' ({b} of {n} sung notes, median onset {ms})', '（歌えた {n} 音中 {b} 音、入りの中央値 {ms}）'),
  'd.early_release': (
    '{n} 個長音裡有 {e} 個比原唱提早 100 ms 以上收掉，收音中位提早約 {ms} ms。',
    '{e} of {n} long notes ended at least 100 ms before the original; median about {ms} ms early.',
    'ロングトーン {n} 音中 {e} 音が原曲より 100 ms 以上早く終わり、中央値で約 {ms} ms 早い。',
  ),
  'd.unsteady': ('長音穩定度 {s} cents。', 'Long-note stability {s} cents.', 'ロングトーンの安定度 {s} cent。'),
  'd.unsteady.ref': ('長音穩定度 {s} cents，原唱是 {r} cents。', 'Long-note stability {s} cents; the original has {r} cents.', 'ロングトーンの安定度 {s} cent（原曲は {r} cent）。'),
  'd.unsteady.note': ('第 {l} 句的 {note}：{s} cents。', ' Line {l}, {note}: {s} cents.', '{l} 行目の {note}：{s} cent。'),
  'd.little_vibrato': ('長音裡有顫音的比例 {a}%，原唱是 {r}%。', 'Vibrato on {a} % of the long-note windows; the original has {r} %.', 'ロングトーンでビブラートがかかっている割合 {a}%（原曲は {r}%）。'),
  'd.flat_dynamics': ('音量起伏和原唱的相關係數 {r}（1 是完全一致）。', 'Loudness follows the original with a correlation of {r} (1 = identical).', '音量の起伏と原曲の相関係数 {r}（1 で完全一致）。'),
  'd.regression': ('總分 {t}；下降的項目：{k}。', 'Total {t}; lower: {k}.', '総合点 {t}、下がった項目：{k}。'),
  'd.strong_scores': ('{k}。', '{k}.', '{k}。'),
  'd.clean_lines': ('每個音都命中、沒有 MISS：', 'Every note hit, no MISS:', '全音ヒット、MISS なし：'),
  'd.progress': ('總分 {t}；進步的項目：{k}。', 'Total {t}; better: {k}.', '総合点 {t}、上がった項目：{k}。'),
  'd.lines': ('相關句子：', 'Lines: ', '該当行：'),
  'sep': ('；', '; ', '／'),
  'space': ('', ' ', ''),
  'quote': ('「{q}」', ' “{q}”', '「{q}」'),
  'lineRef': ('第 {n} 句{lyric}（{time}）', 'line {n}{lyric} ({time})', '{n} 行目{lyric}（{time}）'),
  'h.lines': ('每句明細', 'Line by line', '行ごとの詳細'),
  'lines.noLyrics': (
    '這首歌沒有歌詞，句子是依停頓自動切分的，請用句子編號和時間指稱。',
    'This song has no lyrics; lines were split at pauses, so refer to them by number and time.',
    'この曲には歌詞がないため、行は息継ぎで自動的に区切っています。番号と時間で示してください。',
  ),
  'col.time': ('時間', 'Time', '時間'),
  'col.lyric': ('歌詞', 'Lyric', '歌詞'),
  'col.range': ('音域', 'Range', '音域'),
  'col.hit': ('命中', 'Hit', 'ヒット'),
  'col.cents': ('音高中位 (cents)', 'Median (cents)', '音程中央値 (cent)'),
  'col.sharpFlat': ('偏高/偏低', 'Sharp/flat', '高め/低め'),
  'col.unsung': ('沒出聲', 'Not sung', '無声'),
  'col.onset': ('起音中位 (ms)', 'Onset median (ms)', '入り中央値 (ms)'),
  'col.release': ('長音提早收', 'Long notes cut short', 'ロングトーン早切り'),
  'lines.legend': (
    'P/G/G/M = 起音的 PERFECT/GREAT/GOOD/MISS 數。音域是使用者實際唱的調。「長音提早收」= 提早 100 ms 以上收掉的長音數 / 長音（≥0.5 秒）數。',
    'P/G/G/M = onset PERFECT/GREAT/GOOD/MISS counts. Range is in the key the singer actually sang. "Long notes cut short" = long notes (≥ 0.5 s) ending at least 100 ms early / long notes.',
    'P/G/G/M = 入りの PERFECT/GREAT/GOOD/MISS の数。音域は実際に歌ったキー。「ロングトーン早切り」＝100 ms 以上早く終わったロングトーン数／ロングトーン（0.5 秒以上）数。',
  ),
  'h.history': ('和之前的演唱比較', 'Compared with earlier takes', '以前の歌唱との比較'),
  'history.count': ('這首歌之前唱過 {n} 次。', 'The singer has sung this song {n} times before.', 'この曲は以前に {n} 回歌っています。'),
  'history.now': ('這次', 'This take', '今回'),
  'history.previous': ('上一次', 'Previous', '前回'),
  'history.best': ('之前最佳', 'Best before', 'これまでの最高'),
  'footer': ('由 Karaoke Battle{app} 產生 · 分析格式 v{v}', 'Made by Karaoke Battle{app} · analysis format v{v}', 'Karaoke Battle{app} で作成 · 分析形式 v{v}'),
};
