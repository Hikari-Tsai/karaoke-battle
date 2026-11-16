// English and Japanese texts for the page. Chinese is the page itself:
// index.html holds it, and it is read from there when switching back.
// Each key matches a data-i18n (inner HTML) or data-i18n-aria (aria-label)
// attribute; meta.* set the title and descriptions.
window.KB_I18N = {
  en: {
      "meta.title": "Karaoke Battle | A smart karaoke system, optimized in one click",
      "meta.desc": "A karaoke scoring system that runs on your own machine. Paste a YouTube link or drop in a media file: it separates the vocals, transcribes the notes, shows your pitch as you sing and scores the take. macOS and Windows, free and open source.",
      "meta.ogdesc": "A karaoke scoring system that runs on your own machine. macOS and Windows, free and open source.",
      "skip": "Skip to content",
      "a.home": "Karaoke Battle home",
      "a.nav": "Main menu",
      "a.lang": "Language",
      "a.footnav": "Footer links",
      "nav.how": "How it works",
      "nav.features": "Features",
      "nav.scoring": "Scoring",
      "nav.tech": "Tech",
      "nav.download": "Download",
      "star": "Star on GitHub",
      "star.short": "Star",
      "hero.eyebrow": "Paste a link, sing. Finish, get a score.",
      "hero.h1": "A smart karaoke system, optimized in one click",
      "hero.lead": "Paste a YouTube link or drop in a media file. On your own computer the app separates the vocals, builds the accompaniment and transcribes the melody notes. Watch your pitch as you sing, and get a score from 0 to 100 when you finish.",
      "dl.mac": "Download for macOS",
      "dl.win": "Download for Windows",
      "dl.winsub": "10 / 11 x64",
      "hero.fine": "Free and open source (MIT). The models, about 500 MB, download on first launch.",
      "film.fallback": "Your browser cannot play this video. You can <a href=\"assets/promo.mp4\">download it</a> instead.",
      "film.cap": "Intro film (32 s, with sound; the on-screen text is in Chinese). Demo song: 多帕 Topa, 冬天．我們不說再見",
      "how.h2": "Three steps to a score",
      "how.1.t": "Paste a link",
      "how.1.p": "Paste a YouTube link, or drop in a media file. You can queue several songs at once.",
      "how.2.t": "Sing",
      "how.2.p": "When the song is ready, press “Preview”, put on headphones and press “Start recording”. You can listen to the guide vocal or the backing first.",
      "how.3.t": "See your score",
      "how.3.p": "Right after you sing you get a total score, a rank from D to SSS and six sub-scores.",
      "a.add": "A YouTube link is pasted and the song is prepared in the background",
      "a.sing": "Singing screen: piano roll, live pitch curve, judgements and lyrics",
      "a.results": "Results: share card, total score and sub-scores",
      "a.range": "Range keyboard: finding your own range, then one-click key",
      "a.key": "Key shift, vocal return and hall reverb settings",
      "a.replay": "Judgements in the replay, with reverb and volume adjusted live",
      "a.lyrics": "Pasted lyrics are timed automatically and colour in word by word",
      "a.notes": "Dragging a note to fix its pitch",
      "feat.h2": "Features",
      "feat.lead": "Every clip below was recorded from the real app. The clips have no sound and show the app in Chinese; it also comes in English and Japanese.",
      "f1.t": "See exactly which notes went off",
      "f1.p1": "A scrolling piano roll shows every note of the original singer, and your pitch is drawn live on top of it: green is on pitch, yellow is close, red is off.",
      "f1.p2": "Each note pops a rhythm-game PERFECT / GREAT / GOOD / MISS judgement as you sing it.",
      "f2.t": "Range keyboard and one-click key",
      "f2.p1": "A piano keyboard fills in the song’s range right on the keys, next to the comfortable male and female ranges, and tells you whom the key suits.",
      "f2.p2": "Sing a few notes into the mic to find your own range. “One-click key” then moves the backing, the notes and the keyboard into a male, a female or your own range.",
      "f3.t": "Key shift, vocal return and reverb",
      "f3.p1": "Key moves the accompaniment and the reference notes together. The vocal return sends your voice to the headphones along with the music, with an optional hall reverb.",
      "f4.t": "Scores, share cards and videos",
      "f4.p1": "Staying in tune and on the beat gets you around 80; an S (91+) takes steady pitch and rhythm throughout. Wrong or forgotten words cost nothing.",
      "f4.p2": "One click turns the result into a share card, and you can export a 1080p video of your take. Every take stays in the library, with your best score on top.",
      "f5.t": "Judgements in the replay too",
      "f5.p1": "The replay weighs timing and pitch together: besides FAST / LATE it adds HIGH / LOW, so you can see at a glance whether a note was early, late, sharp or flat.",
      "f5.p2": "Export a replay as a zip and send it to a friend; they import it and watch your take.",
      "f6.t": "Lyrics: subtitles, paste and align, or AI",
      "f6.p1": "When the YouTube video has subtitles they become the lyrics. Otherwise import SRT / VTT / LRC, paste the whole song and let the app time it, or generate them with Whisper speech recognition.",
      "f6.p2": "You can also edit the text and times line by line, then export to SRT or LRC.",
      "f7.t": "Fix notes by hand",
      "f7.p1": "A transcribed note is wrong? Press “Edit notes” and drag it up or down; a tone plays the new pitch while you drag. You can restore the original transcription at any time.",
      "f8.t": "Hot songs",
      "f8.p1": "Can’t decide what to sing? “Hot songs” lists the weekly request charts of Holiday KTV, Cashbox Party, JOYSOUND and DAM, plus the KKBOX weekly single charts. Every song has a “Search on YouTube” button.",
      "sc.h2": "How the score works",
      "sc.lead": "After you sing, the app aligns your recorded pitch curve with the original singer’s and compares them. Six sub-scores are weighted into a score from 0 to 100.",
      "sc.pitch": "Pitch",
      "sc.rhythm": "Rhythm",
      "sc.stab": "Stability",
      "sc.vib": "Vibrato",
      "sc.expr": "Expression",
      "sc.long": "Long tone",
      "sc.w40": "40% of the score",
      "sc.w20": "20% of the score",
      "sc.w10": "10% of the score",
      "sc.pitch.d": "Whether the notes you sing land on the melody",
      "sc.rhythm.d": "Each note judged from PERFECT to MISS; the window follows the tempo",
      "sc.stab.d": "How steady the pitch of your long notes is",
      "sc.vib.d": "Vibrato on long notes; counted only for songs whose original singer uses a lot of it",
      "sc.expr.d": "Whether your loud and soft follow the original",
      "sc.long.d": "Whether long notes are held to the end and on pitch",
      "pt1.t": "An octave up or down still counts",
      "pt1.p": "Notes an octave apart are treated as the same note.",
      "pt2.t": "Singing in another key is fine",
      "pt2.p": "One semitone offset is used for the whole song, and the app estimates it for you.",
      "pt3.t": "Wrong words cost nothing",
      "pt3.p": "The score never looks at the lyrics; humming a forgotten line works too.",
      "sc.more": "The full scoring method and formulas",
      "te.h2": "Technical points",
      "te1": "<b>Runs locally, your data stays with you</b>The conversion engine runs on your own machine: nothing is uploaded, and it works offline (the models download on first use).",
      "te2": "<b>Native C++ engine</b>No Python to install; the installer is about 60 MB.",
      "te3": "<b>Two platforms: macOS and Windows</b>Universal on Mac (Apple Silicon + Intel); CUDA, DirectML and CPU on Windows.",
      "te4": "<b>Dual pitch detection</b>DSP (an algorithm) and SwiftF0 (a model) run side by side, for both speed and accuracy.",
      "te5": "<b>Automatic calibration and one-click key</b>Latency and your vocal range are measured automatically.",
      "te6": "<b>Automatic lyric timing</b>Two models, GAME and Whisper, help place the lyrics on the timeline.",
      "te7": "<b>A rigorous scoring algorithm</b>Designed from a large body of real-world test data and feedback from singers and streamers.",
      "te8": "<b>Models download themselves</b>Fetched from Hugging Face on first launch and verified with SHA-256.",
      "te9": "<b>Advanced transcription model and algorithms</b>The noise-robust GAME model, combined with vocal separation and noise-rejection algorithms, keeps misreadings as low as possible.",
      "te.more": "Full technical notes (in Chinese)",
      "dl.h2": "Download Karaoke Battle",
      "dl.lead": "Free and open source (MIT).",
      "in.mac": "Open the DMG and drag the app to Applications. The first time, right-click the app and choose Open.",
      "in.win": "Unzip and run <code>karaoke_battle.exe</code>. If SmartScreen appears, choose “Run anyway”.",
      "in.first.t": "First launch",
      "in.first": "The models, about 500 MB, download automatically.",
      "dl.install": "Installation guide (in Chinese)",
      "dl.releases": "All versions and release notes",
      "ft.report": "Report a problem",
      "ft.contrib": "Contributing",
      "ft.thanks": "Acknowledgments",
      "ft.p1": "The code is MIT licensed. The weights of the GAME transcription model are non-commercial (CC BY-NC-SA 4.0), so use of the whole app is bound by those terms.",
      "ft.p2": "Intro film demo song: 多帕 Topa, 冬天．我們不說再見. Feature clips demo song: Josh Woodward, Swansong (CC BY)."
  },
  ja: {
      "meta.title": "Karaoke Battle｜ワンクリックで最適化するスマートカラオケシステム",
      "meta.desc": "手元の PC で動くカラオケ採点システム。YouTube のリンクを貼るか動画・音声ファイルをドロップすると、ボーカルを分離して音符を書き起こし、歌いながら音程が見え、歌い終わると点数が出ます。macOS と Windows、無料・オープンソース。",
      "meta.ogdesc": "手元の PC で動くカラオケ採点システム。macOS と Windows、無料・オープンソース。",
      "skip": "本文へスキップ",
      "a.home": "Karaoke Battle ホーム",
      "a.nav": "メインメニュー",
      "a.lang": "言語",
      "a.footnav": "フッターのリンク",
      "nav.how": "使い方",
      "nav.features": "機能",
      "nav.scoring": "採点",
      "nav.tech": "技術",
      "nav.download": "ダウンロード",
      "star": "スターをください",
      "star.short": "スター",
      "hero.eyebrow": "リンクを貼れば歌える、歌えば点数が出る",
      "hero.h1": "ワンクリックで最適化する<br />スマートカラオケシステム",
      "hero.lead": "YouTube のリンクを貼るか、動画・音声ファイルをドロップ。アプリが手元の PC でボーカルを分離し、伴奏を作り、メロディの音符を書き起こします。歌いながら自分の音程が見え、歌い終わると 0〜100 点の点数が出ます。",
      "dl.mac": "macOS 版をダウンロード",
      "dl.win": "Windows 版をダウンロード",
      "dl.winsub": "10／11 x64",
      "hero.fine": "無料・オープンソース（MIT）。初回起動時にモデル（約 500 MB）を自動でダウンロードします。",
      "film.fallback": "お使いのブラウザでは動画を再生できません。<a href=\"assets/promo.mp4\">ダウンロード</a>してご覧ください。",
      "film.cap": "紹介動画（32 秒・音声あり。画面の文字は中国語）。デモ曲：多帕 Topa「冬天．我們不說再見」",
      "how.h2": "3 ステップで採点",
      "how.1.t": "リンクを貼る",
      "how.1.p": "YouTube のリンクを貼るか、動画・音声ファイルをドロップ。複数の曲をまとめて準備できます。",
      "how.2.t": "歌う",
      "how.2.p": "準備が終わったら「プレビュー」を押し、ヘッドホンを着けて「録音開始」。先にガイドボーカルや伴奏を聞くこともできます。",
      "how.3.t": "点数を見る",
      "how.3.p": "歌い終わるとすぐ、総合得点、D〜SSS のランク、6 項目のサブスコアが出ます。",
      "a.add": "YouTube のリンクを貼ると、バックグラウンドで曲を準備する",
      "a.sing": "歌唱画面：ピアノロール、リアルタイムのピッチ曲線、判定、歌詞",
      "a.results": "結果画面：シェアカード、総合得点、サブスコア",
      "a.range": "音域キーボード：自分の音域を測り、ワンクリック移調",
      "a.key": "キー変更、ボーカルリターン、ホールリバーブの設定",
      "a.replay": "リプレイで判定が表示され、リバーブと音量を調整する",
      "a.lyrics": "貼り付けた歌詞が自動で同期され、1 文字ずつ色が付く",
      "a.notes": "音符をドラッグして音程を直す",
      "feat.h2": "機能",
      "feat.lead": "以下の画面はすべて実際のアプリを操作して録画したものです。音声はありません。画面は中国語表示ですが、アプリは日本語と英語にも対応しています。",
      "f1.t": "どの音を外したかがすぐわかる",
      "f1.p1": "スクロールするピアノロールに原曲の音符がすべて表示され、自分の音程がリアルタイムに線で描かれます。緑は正確、黄色は惜しい、赤は外れ。",
      "f1.p2": "歌った音ごとに、音ゲーのような PERFECT／GREAT／GOOD／MISS の判定が表示されます。",
      "f2.t": "音域キーボードとワンクリック移調",
      "f2.p1": "ピアノ鍵盤に曲の音域がそのまま塗られ、男性・女性の歌いやすい音域と並べて、このキーが誰向きかを教えてくれます。",
      "f2.p2": "マイクに向かって何音か歌えば、自分の音域が測れます。「ワンクリック移調」で男性・女性・自分の音域を選ぶと、伴奏・音符・鍵盤がまとめて合うキーに移ります。",
      "f3.t": "キー変更、ボーカルリターン、リバーブ",
      "f3.p1": "キーを変えると伴奏と基準の音符が一緒に移調されます。ボーカルリターンで自分の声を音楽と一緒にヘッドホンへ返せ、ホールリバーブも掛けられます。",
      "f4.t": "スコア、シェアカード、歌唱動画",
      "f4.p1": "音程とリズムが合っていれば 80 点前後。S（91 点以上）には音程もリズムも安定した歌唱が必要です。歌詞を間違えても忘れても減点されません。",
      "f4.p2": "ワンクリックでシェア用カードにでき、1080p の歌唱動画も書き出せます。歌唱はすべてライブラリに残り、最高得点がひと目で分かります。",
      "f5.t": "リプレイにも判定表示",
      "f5.p1": "リプレイではタイミングと音程の両方を見て、FAST／LATE に加えて HIGH／LOW も付くので、早い・遅い・高い・低いがひと目で分かります。",
      "f5.p2": "リプレイは zip に書き出して友だちに送れます。相手は読み込むだけであなたの歌唱を見られます。",
      "f6.t": "歌詞：字幕、貼り付けて同期、AI 作成",
      "f6.p1": "YouTube の動画に字幕があればそのまま歌詞になります。なければ、SRT・VTT・LRC を読み込む、1 曲分を貼り付けて自動で同期する、Whisper 音声認識で作成する、から選べます。",
      "f6.p2": "文字と時間を 1 行ずつ直して、SRT・LRC に書き出すこともできます。",
      "f7.t": "音符を手で直せる",
      "f7.p1": "自動採譜の音符が違う？「音符を編集」を押して上下にドラッグすれば直せます。ドラッグ中は音で音程を試聴できます。いつでも元に戻せます。",
      "f8.t": "人気曲",
      "f8.p1": "何を歌うか迷ったら「人気曲」。ホリデイKTV・銭櫃（キャッシュボックス）・JOYSOUND・DAM の週間ランキングと、KKBOX の週間シングルランキングを表示します。どの曲にも「YouTube で検索」ボタンがあります。",
      "sc.h2": "点数の仕組み",
      "sc.lead": "歌い終わると、録音した音程の曲線を原曲と合わせて比べ、6 項目のサブスコアを出します。重み付けして 0〜100 点に換算します。",
      "sc.pitch": "音程",
      "sc.rhythm": "リズム",
      "sc.stab": "安定感",
      "sc.vib": "ビブラート",
      "sc.expr": "抑揚",
      "sc.long": "ロングトーン",
      "sc.w40": "配点 40%",
      "sc.w20": "配点 20%",
      "sc.w10": "配点 10%",
      "sc.pitch.d": "歌った音がメロディに乗っているか",
      "sc.rhythm.d": "音ごとに PERFECT〜MISS を判定。判定の幅は曲のテンポに合わせます",
      "sc.stab.d": "ロングトーンの音程がどれだけ安定しているか",
      "sc.vib.d": "ロングトーンのビブラート。原曲がビブラートを多用する曲だけ採点します",
      "sc.expr.d": "声の強弱が原曲に沿っているか",
      "sc.long.d": "ロングトーンを最後まで、音程を保って伸ばせたか",
      "pt1.t": "1 オクターブ上でも下でも正解",
      "pt1.p": "オクターブ違いは同じ音として扱います。",
      "pt2.t": "キーを変えて歌っても大丈夫",
      "pt2.p": "曲全体で 1 つの半音シフト量を使い、アプリが自動で推定します。",
      "pt3.t": "歌詞を間違えても減点なし",
      "pt3.p": "採点は歌詞を見ません。忘れたところはハミングでも構いません。",
      "sc.more": "採点方法と数式の詳細",
      "te.h2": "技術的な特徴",
      "te1": "<b>ローカル処理でデータは外に出ない</b>変換エンジンは手元の PC で動き、データを外部に送りません。オフラインでも使えます（初回のみモデルのダウンロードが必要）。",
      "te2": "<b>ネイティブ C++ エンジン</b>Python のインストールは不要。インストーラーは約 60 MB。",
      "te3": "<b>macOS と Windows の 2 プラットフォーム</b>Mac は Universal（Apple Silicon + Intel）。Windows は CUDA・DirectML・CPU に対応。",
      "te4": "<b>2 系統のピッチ検出</b>DSP（アルゴリズム）と SwiftF0（モデル）を並行して使い、速さと正確さを両立しています。",
      "te5": "<b>自動補正とワンクリック移調</b>遅延と音域を全自動で測定します。",
      "te6": "<b>歌詞の自動同期</b>GAME と Whisper の 2 つのモデルで、歌詞のタイミングを合わせます。",
      "te7": "<b>厳密な採点アルゴリズム</b>多くの歌勢や配信者による実測データと意見をもとに設計しています。",
      "te8": "<b>モデルは自動ダウンロード</b>初回起動時に Hugging Face から取得し、SHA-256 で検証します。",
      "te9": "<b>先進の採譜モデルとアルゴリズム</b>ノイズに強い GAME モデルに、ボーカル分離モデルとノイズ除去アルゴリズムを組み合わせ、誤検出をできるだけ減らします。",
      "te.more": "技術の詳細（中国語）",
      "dl.h2": "Karaoke Battle をダウンロード",
      "dl.lead": "無料・オープンソース（MIT）。",
      "in.mac": "DMG を開いてアプリを「アプリケーション」へドラッグ。初回はアプリを右クリック →「開く」。",
      "in.win": "解凍して <code>karaoke_battle.exe</code> を実行。SmartScreen が出たら「実行」を選びます。",
      "in.first.t": "初回起動",
      "in.first": "モデル（約 500 MB）を自動でダウンロードします。",
      "dl.install": "インストール手順（中国語）",
      "dl.releases": "すべてのバージョンと更新履歴",
      "ft.report": "問題を報告",
      "ft.contrib": "協力する",
      "ft.thanks": "謝辞",
      "ft.p1": "コードは MIT ライセンスです。採譜モデル GAME の重みは非商用ライセンス（CC BY-NC-SA 4.0）のため、アプリ全体の利用もその条件に従います。",
      "ft.p2": "紹介動画のデモ曲：多帕 Topa「冬天．我們不說再見」。機能画面のデモ曲：Josh Woodward「Swansong」（CC BY）。"
  }
};

(function () {
  var dict = window.KB_I18N, root = document.documentElement;
  var zh = { "meta.title": document.title };
  var metaDesc = document.querySelector('meta[name="description"]');
  var ogTitle = document.querySelector('meta[property="og:title"]');
  var ogDesc = document.querySelector('meta[property="og:description"]');
  zh["meta.desc"] = metaDesc.content;
  zh["meta.ogdesc"] = ogDesc.content;
  var texts = Array.prototype.slice.call(document.querySelectorAll("[data-i18n]"));
  var arias = Array.prototype.slice.call(document.querySelectorAll("[data-i18n-aria]"));
  var links = Array.prototype.slice.call(document.querySelectorAll("[data-href-en], [data-href-ja]"));
  texts.forEach(function (el) { zh[el.getAttribute("data-i18n")] = el.innerHTML; });
  arias.forEach(function (el) { zh[el.getAttribute("data-i18n-aria")] = el.getAttribute("aria-label"); });
  links.forEach(function (el) { el.setAttribute("data-href-zh", el.getAttribute("href")); });

  function apply(lang) {
    var d = lang === "zh" ? zh : dict[lang];
    function s(key) { return d[key] != null ? d[key] : zh[key]; }
    texts.forEach(function (el) { el.innerHTML = s(el.getAttribute("data-i18n")); });
    arias.forEach(function (el) { el.setAttribute("aria-label", s(el.getAttribute("data-i18n-aria"))); });
    links.forEach(function (el) { el.setAttribute("href", el.getAttribute("data-href-" + lang) || el.getAttribute("data-href-zh")); });
    document.title = s("meta.title");
    metaDesc.content = s("meta.desc");
    ogTitle.content = s("meta.title");
    ogDesc.content = s("meta.ogdesc");
    root.lang = lang === "zh" ? "zh-Hant" : lang;
    root.setAttribute("data-lang", lang);
    Array.prototype.forEach.call(document.querySelectorAll("[data-set-lang]"), function (b) {
      b.setAttribute("aria-pressed", b.getAttribute("data-set-lang") === lang ? "true" : "false");
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll("[data-set-lang]"), function (b) {
    b.addEventListener("click", function () {
      var lang = b.getAttribute("data-set-lang");
      apply(lang);
      try { localStorage.setItem("kb-lang", lang); } catch (e) {}
      // Keep the choice in the address so the page can be shared in that language.
      try {
        var u = new URL(location.href);
        u.searchParams.set("lang", lang);
        history.replaceState(null, "", u.pathname + u.search + u.hash);
      } catch (e) {}
    });
  });

  apply(root.getAttribute("data-lang") || "zh");
})();
