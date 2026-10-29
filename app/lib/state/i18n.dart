// Tiny string table: zh-TW, English and Japanese. No ARB generation.
//
// The current language lives in [I18n.notifier]; `app.dart` keys the whole
// shell on it so every screen is rebuilt when it changes, and
// [I18n.onChanged] persists the choice (wired in app_services.dart).
import 'package:flutter/foundation.dart';

class I18n {
  I18n._();

  /// Supported UI languages in display order.
  static const supported = ['zh', 'en', 'ja'];

  /// Native names shown in the language selector.
  static const nativeNames = {'zh': '繁體中文', 'en': 'English', 'ja': '日本語'};

  static final ValueNotifier<String> notifier = ValueNotifier('zh');
  static void Function(String lang)? onChanged;

  static String get lang => notifier.value;
  static set lang(String v) {
    if (!supported.contains(v) || v == notifier.value) return;
    notifier.value = v;
    onChanged?.call(v);
  }

  /// Picks the best supported language for a system locale.
  static String fromLocale(String? localeTag) {
    final t = (localeTag ?? '').toLowerCase();
    if (t.startsWith('ja')) return 'ja';
    if (t.startsWith('en')) return 'en';
    return 'zh';
  }
}

/// Looks up [key] in the table for the current language (zh-TW is the
/// fallback when a translation is empty) and substitutes `{name}` arguments.
String tr(String key, [Map<String, Object?>? args]) {
  final e = _table[key];
  String s;
  if (e == null) {
    s = key;
  } else {
    s = switch (I18n.lang) {
      'en' => e.$2,
      'ja' => e.$3.isEmpty ? e.$2 : e.$3,
      _ => e.$1,
    };
  }
  if (args != null) {
    args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  }
  return s;
}

// (zh-TW, English, 日本語)
const Map<String, (String, String, String)> _table = {
  // navigation
  'app.title': ('Karaoke Battle', 'Karaoke Battle', 'Karaoke Battle'),
  'nav.library': ('曲庫', 'Library', '曲ライブラリ'),
  'nav.rules': ('計分規則', 'Scoring', '採点ルール'),
  'nav.settings': ('設定', 'Settings', '設定'),
  'nav.about': ('關於', 'About', 'このアプリについて'),
  // generic
  'ok': ('確定', 'OK', 'OK'),
  'cancel': ('取消', 'Cancel', 'キャンセル'),
  'close': ('關閉', 'Close', '閉じる'),
  'later': ('稍後再說', 'Later', '後で'),
  'retry': ('重試', 'Retry', '再試行'),
  'delete': ('刪除', 'Delete', '削除'),
  'install': ('安裝', 'Install', 'インストール'),
  'installed': ('已安裝', 'Installed', 'インストール済み'),
  'notInstalled': ('未安裝', 'Not installed', '未インストール'),
  'download': ('下載', 'Download', 'ダウンロード'),
  'remove': ('移除', 'Remove', '削除'),
  'update': ('更新', 'Update', '更新'),
  'open': ('開啟', 'Open', '開く'),
  'error': ('錯誤', 'Error', 'エラー'),
  'done': ('完成', 'Done', '完了'),
  'processing': ('處理中', 'Processing', '処理中'),
  'notAvailable': ('無法使用', 'Unavailable', '利用不可'),
  'unknown': ('未知', 'Unknown', '不明'),
  // engine error page
  'engine.loadFailed': ('無法載入原生引擎', 'Native engine failed to load', 'ネイティブエンジンを読み込めません'),
  'engine.triedPath': ('嘗試載入的路徑：', 'Attempted library path:', '読み込みを試みたパス：'),
  'engine.hint': (
    '請先建置 engine/（scripts/build_engine.sh）或確認 .app 內含 libkaraoke_engine，然後重新啟動。',
    'Build engine/ first (scripts/build_engine.sh) or make sure the bundle ships libkaraoke_engine, then restart.',
    '先に engine/ をビルド（scripts/build_engine.sh）するか、.app に libkaraoke_engine が含まれているか確認してから再起動してください。',
  ),
  'startup.failed': ('啟動失敗', 'Startup failed', '起動に失敗しました'),
  // backend dialogs
  'backend.title': ('運算後端', 'Compute backend', '計算バックエンド'),
  'backend.driverOld.title': ('NVIDIA 驅動程式太舊', 'NVIDIA driver too old', 'NVIDIA ドライバーが古すぎます'),
  'backend.driverOld.body': (
    '偵測到 NVIDIA 顯示卡，但驅動程式版本不支援 CUDA 12（需 527.41 以上）。更新驅動後可啟用 CUDA 加速；在此之前將使用 DirectML。',
    'An NVIDIA GPU was found but the driver does not support CUDA 12 (527.41 or newer required). Update the driver to enable CUDA; DirectML will be used meanwhile.',
    'NVIDIA GPU を検出しましたが、ドライバーが CUDA 12 に対応していません（527.41 以降が必要）。ドライバーを更新すると CUDA が使えます。それまでは DirectML を使用します。',
  ),
  'backend.driverOld.link': ('前往 NVIDIA 下載驅動', 'Open NVIDIA driver download', 'NVIDIA ドライバーのダウンロードを開く'),
  'backend.useDirectml': ('先用 DirectML', 'Use DirectML for now', 'とりあえず DirectML を使う'),
  'backend.cudaMissing.title': ('啟用 CUDA 加速？', 'Enable CUDA acceleration?', 'CUDA アクセラレーションを有効にしますか？'),
  'backend.cudaMissing.body': (
    '偵測到 NVIDIA 顯示卡 {gpu}。下載 CUDA 套件（約 {size}）後，人聲分離與轉譜速度可大幅提升。',
    'NVIDIA GPU {gpu} detected. Downloading the CUDA pack (about {size}) makes separation and transcription much faster.',
    'NVIDIA GPU {gpu} を検出しました。CUDA パック（約 {size}）をダウンロードすると、ボーカル分離と採譜が大幅に速くなります。',
  ),
  'backend.cudaMissing.download': ('下載並啟用', 'Download and enable', 'ダウンロードして有効化'),
  'backend.selftestFailed.title': ('CUDA 自我測試失敗', 'CUDA self-test failed', 'CUDA セルフテストに失敗'),
  'backend.selftestFailed.body': (
    'CUDA 套件無法正常執行，已改用 DirectML。你可以重新下載套件再試一次。',
    'The CUDA pack did not pass the self-test; DirectML is used instead. You can re-download the pack and try again.',
    'CUDA パックが正常に動作しないため DirectML に切り替えました。パックを再ダウンロードしてもう一度お試しください。',
  ),
  'backend.redownload': ('重新下載', 'Re-download', '再ダウンロード'),
  'backend.noGpu.title': ('未偵測到可用 GPU', 'No usable GPU detected', '利用できる GPU が見つかりません'),
  'backend.noGpu.body': (
    '將以 CPU 執行所有模型。曲目準備（人聲分離、轉譜）會比較慢，但功能完整。',
    'All models will run on the CPU. Song preparation (separation, transcription) will be slower but fully functional.',
    'すべてのモデルを CPU で実行します。曲の準備（分離・採譜）は遅くなりますが、機能に制限はありません。',
  ),
  'backend.directml.title': ('使用 DirectML', 'Using DirectML', 'DirectML を使用'),
  'backend.directml.body': (
    '將透過 DirectML 使用 {gpu}。相較 CUDA：速度較慢、記憶體用量較高、部分模型可能退回 CPU。',
    'Running on {gpu} via DirectML. Compared with CUDA: slower, higher memory use, and some models may fall back to the CPU.',
    '{gpu} を DirectML 経由で使用します。CUDA に比べて速度が遅く、メモリ使用量が多く、一部のモデルは CPU にフォールバックすることがあります。',
  ),
  'backend.dontShowAgain': ('不再顯示', "Don't show again", '今後表示しない'),
  'backend.installing': ('正在下載 CUDA 套件…', 'Downloading CUDA pack…', 'CUDA パックをダウンロード中…'),
  // first run
  'firstRun.title': ('首次設定：下載模型', 'First run: download models', '初期設定：モデルのダウンロード'),
  'firstRun.body': (
    '以下模型為曲目準備與評分所需，將從 Hugging Face 下載並驗證 sha256。',
    'The following models are required and will be downloaded from Hugging Face and verified (sha256).',
    '以下のモデルは曲の準備と採点に必要です。Hugging Face からダウンロードし、sha256 で検証します。',
  ),
  'firstRun.total': ('總大小', 'Total size', '合計サイズ'),
  'firstRun.downloadAll': ('全部下載', 'Download all', 'すべてダウンロード'),
  'firstRun.sidecars': ('外部工具', 'External tools', '外部ツール'),
  'firstRun.ffmpegHint': (
    'ffmpeg 沒有內建下載來源：請用 Homebrew（brew install ffmpeg）或 winget（winget install Gyan.FFmpeg）安裝，或指定一個 ffmpeg 執行檔。',
    'There is no download source for ffmpeg: install it with Homebrew (brew install ffmpeg) or winget (winget install Gyan.FFmpeg), or point the app at an ffmpeg executable.',
    'ffmpeg のダウンロード元がありません。Homebrew（brew install ffmpeg）または winget（winget install Gyan.FFmpeg）でインストールするか、ffmpeg の実行ファイルを指定してください。',
  ),
  'firstRun.pickFfmpeg': ('指定 ffmpeg 路徑', 'Choose ffmpeg…', 'ffmpeg のパスを指定'),
  // library
  'library.title': ('曲庫', 'Library', '曲ライブラリ'),
  'library.empty': (
    '還沒有歌曲。貼上 YouTube 連結或拖入音訊／影片檔案。',
    'No songs yet. Paste a YouTube link or drop an audio/video file.',
    'まだ曲がありません。YouTube のリンクを貼り付けるか、音声／動画ファイルをドロップしてください。',
  ),
  'library.add': ('新增歌曲', 'Add song', '曲を追加'),
  'library.dropHere': ('放開以匯入檔案', 'Drop to import', 'ドロップして読み込む'),
  'library.sing': ('預覽', 'Preview', 'プレビュー'),
  'library.reprocess': ('重新處理', 'Reprocess', '再処理'),
  'library.showFolder': ('顯示資料夾', 'Show folder', 'フォルダを表示'),
  'library.takes': ('演唱紀錄', 'Takes', '歌唱履歴'),
  'library.noTakes': ('尚無演唱紀錄', 'No takes yet', '歌唱履歴はまだありません'),
  'library.viewResult': ('查看結果', 'View result', '結果を見る'),
  'library.fileSection': ('從本機檔案新增', 'Add a local file', 'ローカルファイルから追加'),
  'library.dropZone': ('將影音檔拖放到這裡，或點擊選擇檔案', 'Drop a media file here, or click to choose one', 'ここにメディアファイルをドロップ、またはクリックして選択'),
  'library.supported': ('支援 mp4、mkv、webm、mov、mp3、m4a、wav、flac、ogg、aac', 'Supports mp4, mkv, webm, mov, mp3, m4a, wav, flac, ogg, aac', '対応形式: mp4, mkv, webm, mov, mp3, m4a, wav, flac, ogg, aac'),
  'library.or': ('或', 'or', 'または'),
  'library.urlSection': ('從 YouTube 連結新增', 'Add from a YouTube link', 'YouTube リンクから追加'),
  'library.paste': ('貼上', 'Paste', '貼り付け'),
  'library.lyrics': ('字幕', 'Lyrics', '字幕'),
  'library.bestScore': ('最高分', 'Best score', '最高得点'),
  'library.bestTake': ('最高分', 'Best', 'ベスト'),
  'library.notScored': ('未評分', 'Not scored', '未採点'),
  'library.cancelPrep': ('取消處理', 'Cancel', '処理を中止'),
  'library.deleteConfirm': (
    '確定刪除「{title}」與所有演唱紀錄？',
    'Delete "{title}" and all of its takes?',
    '「{title}」とすべての歌唱履歴を削除しますか？',
  ),
  'library.url': ('YouTube／網址', 'YouTube / URL', 'YouTube／URL'),
  'library.urlHint': (
    '貼上 YouTube 連結或其他 yt-dlp 支援的網址',
    'Paste a YouTube link or any yt-dlp supported URL',
    'YouTube のリンク、または yt-dlp が対応する URL を貼り付け',
  ),
  'library.pickFile': ('選擇檔案', 'Choose file', 'ファイルを選択'),
  'library.language': ('歌詞語言', 'Lyrics language', '歌詞の言語'),
  'library.addUrl': ('加入網址', 'Add URL', 'URL を追加'),
  'library.orDrop': ('或將檔案拖到視窗中', 'or drop a file onto the window', 'またはウィンドウにファイルをドロップ'),
  'lang.zh': ('中文', 'Mandarin', '中国語'),
  'lang.ja': ('日文', 'Japanese', '日本語'),
  'lang.yue': ('粵語', 'Cantonese', '広東語'),
  'lang.en': ('英文', 'English', '英語'),
  'source.youtube': ('YouTube', 'YouTube', 'YouTube'),
  'source.file': ('檔案', 'File', 'ファイル'),
  // stages
  'stage.pending': ('排隊中', 'Queued', '待機中'),
  'stage.acquire': ('下載來源', 'Downloading', 'ダウンロード中'),
  'stage.decode': ('轉檔', 'Decoding', '変換中'),
  'stage.video': ('擷取影片', 'Extracting video', '動画を抽出中'),
  'stage.separateVocals': ('分離人聲', 'Separating vocals', 'ボーカルを分離中'),
  'stage.separateInstrumental': ('分離伴奏', 'Separating accompaniment', '伴奏を分離中'),
  'stage.transcribe': ('轉譜', 'Transcribing', '採譜中'),
  'stage.referenceF0': ('參考音高', 'Reference pitch', '基準ピッチを抽出中'),
  'stage.done': ('可演唱', 'Ready', '準備完了'),
  'stage.failed': ('失敗', 'Failed', '失敗'),
  'prep.downloadModel': ('下載模型', 'Downloading model', 'モデルをダウンロード中'),
  // sing
  'sing.original': ('原曲', 'Original', '原曲'),
  'sing.inst': ('伴奏', 'Accompaniment', '伴奏'),
  'sing.pitchShift': ('升降 Key', 'Key', 'キー'),
  'sing.volume': ('音量', 'Volume', '音量'),
  'sing.play': ('播放', 'Play', '再生'),
  'sing.pause': ('暫停', 'Pause', '一時停止'),
  'sing.restart': ('從頭', 'Restart', '最初から'),
  'sing.record': ('開始錄製', 'Start recording', '録音開始'),
  'sing.stop': ('停止並評分', 'Stop and score', '停止して採点'),
  'sing.recording': ('錄製中', 'Recording', '録音中'),
  'sing.mic': ('麥克風', 'Mic', 'マイク'),
  'sing.gate': ('噪音門檻', 'Noise gate', 'ノイズゲート'),
  'sing.lyrics': ('歌詞', 'Lyrics', '歌詞'),
  'sing.lyricsShow': ('顯示歌詞', 'Show lyrics', '歌詞を表示'),
  'sing.lyricsMain': ('歌詞字幕', 'Lyrics track', '歌詞の字幕'),
  'sing.lyricsTranslation': ('翻譯', 'Translation', '翻訳'),
  'sing.lyricsNone': ('無', 'None', 'なし'),
  'sing.lyricsAuto': ('自動產生', 'auto-generated', '自動生成'),
  'sing.noLyrics': ('這首歌沒有可用的字幕', 'No subtitles available for this song', 'この曲には利用できる字幕がありません'),
  'sing.gateOff': ('關閉', 'Off', 'オフ'),
  'sing.gateHint': (
    '低於門檻（灰色區）的聲音不偵測音高、也不計分。不唱時把門檻拉到環境噪音的音量條之上即可；設定會保存並套用到所有歌曲。',
    'Sound below the gate (grey zone) is ignored for pitch and scoring. While silent, drag the gate just above the room noise level; it is saved and used for every song.',
    'ゲート未満（グレーの範囲）の音は音程検出と採点で無視されます。歌っていないときの環境ノイズのレベルより少し上にゲートを合わせてください。設定は保存され、すべての曲に適用されます。',
  ),
  'sing.note': ('目前音', 'Note', '現在の音'),
  'sing.refNote': ('參考音', 'Ref', '基準音'),
  'sing.cents': ('偏差', 'Cents', 'ずれ'),
  'sing.latency': ('延遲補償', 'Latency', '遅延補正'),
  'sing.octaveAlign': ('八度對齊顯示', 'Octave-aligned display', 'オクターブを揃えて表示'),
  'sing.window': ('時間範圍', 'Window', '表示範囲'),
  'sing.noVideo': ('無影片', 'No video', '動画なし'),
  'sing.extractingF0': ('分析音高…', 'Extracting pitch…', 'ピッチを解析中…'),
  'sing.scoring': ('評分中…', 'Scoring…', '採点中…'),
  'sing.saving': ('儲存錄音…', 'Saving take…', '録音を保存中…'),
  'sing.tooShort': ('錄音太短，未評分。', 'Take too short, not scored.', '録音が短すぎるため採点しませんでした。'),
  'sing.audioInitFailed': ('音訊裝置初始化失敗', 'Audio device initialisation failed', 'オーディオデバイスの初期化に失敗しました'),
  'sing.back': ('返回', 'Back', '戻る'),
  // results
  'results.title': ('演唱結果', 'Results', '採点結果'),
  'results.total': ('總分', 'Total', '総合得点'),
  'results.pitch': ('音準', 'Pitch', '音程'),
  'results.rhythm': ('節奏', 'Rhythm', 'リズム'),
  'results.stability': ('穩定度', 'Stability', '安定感'),
  'results.vibrato': ('顫音', 'Vibrato', 'ビブラート'),
  'results.expression': ('表現力', 'Expression', '抑揚'),
  'results.longTone': ('長音', 'Long tone', 'ロングトーン'),
  'results.singAgain': ('再唱一次', 'Sing again', 'もう一度歌う'),
  'results.backToLibrary': ('回曲庫', 'Back to library', 'ライブラリへ戻る'),
  'results.notes': ('逐音分析', 'Note analysis', '音符ごとの分析'),
  'results.onset': ('起點', 'Onset', '開始'),
  'results.refPitch': ('參考音', 'Ref', '基準音'),
  'results.sungDev': ('偏差 (cents)', 'Deviation (cents)', 'ずれ (cents)'),
  'results.matched': ('命中', 'Matched', '一致'),
  'results.overview': ('全曲總覽', 'Song overview', '全体表示'),
  'results.shift': ('移調', 'Shift', '移調'),
  'results.placeholder': ('（暫用簡易評分器）', '(placeholder scorer)', '（簡易採点器を使用中）'),
  'results.notAvailable': ('—', '—', '—'),
  // settings
  'settings.title': ('設定', 'Settings', '設定'),
  'settings.uiLanguage': ('介面語言', 'UI language', '表示言語'),
  'settings.backend': ('運算後端', 'Compute backend', '計算バックエンド'),
  'settings.backend.auto': ('自動', 'Auto', '自動'),
  'settings.backend.active': ('目前使用', 'Active', '使用中'),
  'settings.gpu': ('顯示卡', 'GPU', 'GPU'),
  'settings.driver': ('驅動', 'Driver', 'ドライバー'),
  'settings.vram': ('VRAM', 'VRAM', 'VRAM'),
  'settings.cudaPack': ('CUDA 套件', 'CUDA pack', 'CUDA パック'),
  'settings.benchmark': ('跑效能測試', 'Run benchmark', 'ベンチマークを実行'),
  'settings.benchmarkRunning': ('測試中…', 'Benchmarking…', '測定中…'),
  'settings.benchmarkNeedsModel': ('需先安裝 SwiftF0 模型', 'Install the SwiftF0 model first', '先に SwiftF0 モデルをインストールしてください'),
  'settings.models': ('模型', 'Models', 'モデル'),
  'settings.gameModel': ('轉譜模型', 'Transcription model', '採譜モデル'),
  'settings.gameLargeInfo': (
    '約 1 億參數，下載約 394 MB。音符切分與音高最準，建議預設使用。備歌較慢：有 NVIDIA 顯示卡（CUDA）或 Apple Silicon 時一首約十幾秒到一分鐘，只用 CPU 時會更久。',
    'About 100M parameters, a 394 MB download. The most accurate note splitting and pitch; recommended as the default. Slower to prepare: roughly ten seconds to a minute per song with an NVIDIA GPU (CUDA) or Apple Silicon, longer on CPU only.',
    '約 1 億パラメータ、ダウンロード約 394 MB。音符の区切りと音程が最も正確で、標準の推奨です。準備に時間がかかり、NVIDIA GPU（CUDA）や Apple Silicon では 1 曲あたり十数秒〜1 分ほど、CPU のみではさらにかかります。',
  ),
  'settings.gameSmallInfo': (
    '約 1200 萬參數，下載約 51 MB。速度約快數倍，適合沒有獨立顯示卡或較舊的電腦。快歌或裝飾音多的段落，音符可能切得較粗，長音判定與節奏分會受一點影響；音準分以原唱音高曲線為主，影響較小。換模型只影響之後新增或重新處理的歌曲。',
    'About 12M parameters, a 51 MB download. Several times faster; suits computers without a dedicated GPU or older machines. On fast or heavily ornamented passages notes may be split more coarsely, which slightly affects long-tone and rhythm scores; the pitch score follows the original vocal curve and is barely affected. Switching only affects songs added or reprocessed afterwards.',
    '約 1200 万パラメータ、ダウンロード約 51 MB。数倍速く、専用 GPU のない PC や古い PC に向いています。速い曲や装飾の多い部分では音符の区切りが粗くなることがあり、ロングトーンとリズムの点数に少し影響します。音程の点数は原曲の音高カーブが基準なので影響は小さめです。切り替えはこれ以降に追加・再処理する曲にのみ適用されます。',
  ),
  'settings.sidecars': ('外部工具', 'External tools', '外部ツール'),
  'settings.updateYtDlp': ('更新 yt-dlp', 'Update yt-dlp', 'yt-dlp を更新'),
  'settings.audio': ('音訊裝置', 'Audio devices', 'オーディオデバイス'),
  'settings.captureDevice': ('麥克風', 'Input', '入力（マイク）'),
  'settings.playbackDevice': ('輸出', 'Output', '出力'),
  'settings.systemDefault': ('系統預設', 'System default', 'システム既定'),
  'settings.sampleRate': ('取樣率', 'Sample rate', 'サンプルレート'),
  'settings.calibrate': ('量測延遲', 'Calibrate latency', '遅延を測定'),
  'settings.calibrating': ('量測中（約 2 秒）…', 'Measuring (about 2 s)…', '測定中（約 2 秒）…'),
  'settings.calibrateHint': (
    '請用喇叭外放（不要戴耳機），讓麥克風能聽到播放的聲響，才能量出延遲。量測時會播放一串短促的咔嗒聲，請把音量調到聽得清楚。',
    'Use your speakers (not headphones) so the microphone can hear the playback; otherwise the latency cannot be measured. A short burst of clicks will play, so turn the volume up enough to hear it clearly.',
    'ヘッドホンではなくスピーカーで再生し、マイクが再生音を拾えるようにしてください。そうしないと遅延を測定できません。測定中に短いクリック音が流れるので、はっきり聞こえる音量にしてください。',
  ),
  'calibPrompt.title': ('先量測一次延遲', 'Measure latency first', '最初に遅延を測定しましょう'),
  'calibPrompt.body': (
    '還沒有量測過這台電腦的音訊延遲。量測一次（約 2 秒）可以讓即時音高線和伴奏對齊，評分也更準；結果會保存，之後不用再量。換了麥克風或喇叭時，可以到「設定」重新量測。',
    'The audio latency of this computer has not been measured yet. Measuring once (about 2 s) lines the live pitch line up with the backing track and makes scoring more accurate; the result is saved, so you only need to do it once. If you change microphone or speakers, measure again in Settings.',
    'このパソコンの音声遅延はまだ測定されていません。一度測定する（約 2 秒）と、リアルタイムの音程線が伴奏と揃い、採点もより正確になります。結果は保存されるので一度だけで大丈夫です。マイクやスピーカーを変えたときは「設定」から測り直せます。',
  ),
  'calibPrompt.measure': ('開始量測', 'Measure now', '測定する'),
  'calibPrompt.retry': ('再量一次', 'Try again', 'もう一度測定'),
  'calibPrompt.skip': ('略過', 'Skip', 'スキップ'),
  'calibPrompt.dontAsk': ('不再提醒（之後可在「設定」量測）', "Don't ask again (you can measure later in Settings)", '今後表示しない（あとで「設定」から測定できます）'),
  'calibPrompt.doneTitle': ('量測完成', 'Latency measured', '測定完了'),
  'calibPrompt.done': ('延遲為 {ms} ms，已保存並套用到所有歌曲。', 'Latency is {ms} ms; it has been saved and applies to every song.', '遅延は {ms} ms です。保存され、すべての曲に適用されます。'),
  'calibPrompt.continue': ('開始預覽', 'Continue to preview', 'プレビューへ'),
  'settings.calibFail.title': ('量測失敗', 'Calibration failed', '測定に失敗しました'),
  'settings.calibFail.noClick': (
    '麥克風沒有聽到播放的咔嗒聲。請拿掉耳機改用喇叭外放、把系統音量調大，並確認「設定」中選的輸入裝置是你正在用的麥克風，然後再量一次。',
    'The microphone did not hear the clicks. Take off your headphones and use speakers, turn the system volume up, check that the input device selected in Settings is the microphone you are using, then try again.',
    'マイクがクリック音を拾えませんでした。ヘッドホンを外してスピーカーで再生し、システムの音量を上げ、設定で選んだ入力デバイスが使用中のマイクか確認してから、もう一度測定してください。',
  ),
  'settings.calibFail.device': (
    '無法開啟音訊裝置。請確認麥克風與喇叭已連接、沒有被其他程式獨占，並已允許本 App 使用麥克風（macOS：系統設定 > 隱私權與安全性 > 麥克風；Windows：設定 > 隱私權與安全性 > 麥克風）。也可以試著把取樣率改成 44100 Hz 或改選其他裝置。',
    'The audio device could not be opened. Check that the microphone and speakers are connected, not held exclusively by another app, and that this app may use the microphone (macOS: System Settings > Privacy & Security > Microphone; Windows: Settings > Privacy & security > Microphone). You can also try a 44100 Hz sample rate or another device.',
    'オーディオデバイスを開けませんでした。マイクとスピーカーが接続され、他のアプリに占有されていないこと、このアプリにマイクの使用を許可していることを確認してください（macOS：システム設定 > プライバシーとセキュリティ > マイク、Windows：設定 > プライバシーとセキュリティ > マイク）。サンプルレートを 44100 Hz にするか、別のデバイスを選ぶ方法もあります。',
  ),
  'settings.calibFail.timeout': (
    '音訊裝置沒有回應。請確認選的輸入與輸出裝置都已連接，必要時改選其他裝置或重新插拔後再試。',
    'The audio device did not respond. Check that the selected input and output devices are connected; pick other devices or reconnect them, then try again.',
    'オーディオデバイスが応答しません。選択した入力・出力デバイスが接続されているか確認し、必要に応じて別のデバイスを選ぶか接続し直してから、もう一度お試しください。',
  ),
  'settings.calibFail.busy': (
    '目前正在播放或錄音，無法量測。請先關閉預覽或演唱畫面再試。',
    'Audio is playing or recording right now. Close the preview or sing screen, then try again.',
    '再生中または録音中のため測定できません。プレビューや歌唱画面を閉じてから、もう一度お試しください。',
  ),
  'settings.calibFail.other': (
    '發生未預期的錯誤。請重新啟動 App 後再試；若仍失敗，請把下方的技術細節回報到 GitHub Issues。',
    'An unexpected error occurred. Restart the app and try again; if it still fails, report the technical details below on GitHub Issues.',
    '予期しないエラーが発生しました。アプリを再起動してもう一度お試しください。それでも失敗する場合は、下の技術的な詳細を GitHub Issues に報告してください。',
  ),
  'settings.calibFail.details': ('技術細節', 'Technical details', '技術的な詳細'),
  'settings.notCalibrated': ('尚未量測', 'Not calibrated', '未測定'),
  'settings.livePitch': ('即時音高來源', 'Live pitch source', 'リアルタイムピッチの方式'),
  'settings.livePitch.dsp': ('DSP（低延遲）', 'DSP (low latency)', 'DSP（低遅延）'),
  'settings.livePitch.swiftf0': ('SwiftF0（精準）', 'SwiftF0 (accurate)', 'SwiftF0（高精度）'),
  'settings.livePitch.both': ('兩者', 'Both', '両方'),
  'settings.separation': ('分離品質', 'Separation quality', '分離品質'),
  'settings.separation.fast': ('快速（單模型）', 'Fast (single model)', '高速（1 モデル）'),
  'settings.separation.best': ('最佳（雙模型）', 'Best (two models)', '最高品質（2 モデル）'),
  'settings.defaultLanguage': ('預設歌詞語言', 'Default lyrics language', '既定の歌詞言語'),
  'settings.noiseGate': ('麥克風噪音門檻', 'Microphone noise gate', 'マイクのノイズゲート'),
  'settings.octaveInvariant': ('允許八度音演唱', 'Allow singing in another octave', 'オクターブ違いの歌唱を許可'),
  'settings.octaveInvariantHint': (
    '唱高八度或低八度都算正確，並自動偵測整首移調',
    'Singing an octave higher or lower counts as correct; whole-song transposition is detected automatically',
    '1 オクターブ上や下で歌っても正解とし、曲全体の移調は自動で検出します',
  ),
  'settings.dataFolder': ('資料夾', 'Data folder', 'データフォルダ'),
  'settings.reload': ('重新整理', 'Refresh', '更新'),
  'settings.detect': ('重新偵測', 'Re-detect', '再検出'),
  'settings.restartNote': ('變更於下次處理／演唱時生效', 'Applies to the next prep/sing session', '次回の処理／歌唱から適用されます'),
  // about
  // rules
  'rules.title': ('計分規則', 'Scoring rules', '採点ルール'),
  'rules.intro': (
    '唱完後，App 會把你的歌聲和原唱比對，從六個面向給分，加總成 0 到 100 分。下面用最簡單的方式說明每一項怎麼拿分。',
    'After a take the app compares your singing with the original and scores six aspects, adding up to 0–100. Here is how to earn each one in plain words.',
    '歌い終わると、アプリがあなたの歌声を原曲と比べて 6 つの観点で採点し、合計 0〜100 点になります。それぞれの点の取り方をやさしく説明します。',
  ),
  'rules.howToScore': ('六個項目怎麼拿分', 'How to earn each score', '各項目の点の取り方'),
  'rules.pitch': (
    '跟著原唱的旋律唱，每個音只要在半個半音以內就算準。分數最重，先顧好這一項。',
    'Follow the original melody; a note counts as in tune within half a semitone. This is the biggest score, so get it right first.',
    '原曲のメロディに合わせて歌いましょう。半音の半分以内なら正解です。配点が最も大きいので、まずここを押さえましょう。',
  ),
  'rules.rhythm': (
    '每個音要和原唱同時開始、同時結束。不要搶拍、拖拍，也不要提早收音。',
    'Start and end each note when the original does. Do not rush, drag, or cut notes short.',
    '各音を原曲と同じタイミングで始め、同じタイミングで終えましょう。走ったり、もたれたり、早く切ったりしないこと。',
  ),
  'rules.stability': (
    '長音（0.4 秒以上）要唱得穩，音高不要飄來飄去。',
    'Hold long notes (0.4 s or more) steady without the pitch wandering.',
    'ロングトーン（0.4 秒以上）は音程を揺らさず安定して伸ばしましょう。',
  ),
  'rules.vibrato': (
    '原唱有顫音的歌，長音加上自然的顫音（每秒約 4 到 8 次）會加分；原唱沒用顫音的歌不計這項。',
    'Where the original uses vibrato, adding a natural vibrato (about 4–8 per second) on long notes earns points; songs without vibrato skip this item.',
    '原曲にビブラートがある曲では、ロングトーンに自然なビブラート（毎秒 4〜8 回）をかけると加点されます。原曲にビブラートがない曲ではこの項目は採点されません。',
  ),
  'rules.expression': (
    '強弱起伏跟著原唱走：該大聲的地方大聲，該輕的地方輕。',
    'Follow the original dynamics: sing loud where it is loud and soft where it is soft.',
    '原曲の強弱に合わせましょう。大きく歌うところは大きく、小さく歌うところは小さく。',
  ),
  'rules.longTone': (
    '長音要唱滿原唱的長度，不要提早斷掉。',
    'Sustain long notes for their full length; do not stop early.',
    'ロングトーンは原曲の長さいっぱいまで伸ばし、途中で切らないようにしましょう。',
  ),
  'rules.forgivingTitle': ('不會被扣分的事', 'What you are not penalised for', '減点されないこと'),
  'rules.octave': ('唱高八度或低八度都算對，男女生都能唱同一首。', 'Singing an octave higher or lower counts as correct, so anyone can sing any song.', '1 オクターブ上や下で歌っても正解です。誰でも同じ曲を歌えます。'),
  'rules.transpose': ('整首歌移調沒關係，App 會自動對齊；但要整首一致，不要中途換 key。', 'Transposing the whole song is fine, the app aligns it automatically; just keep the same key all the way through.', '曲全体の移調は問題ありません。アプリが自動で合わせます。ただし途中でキーを変えないこと。'),
  'rules.slides': ('原唱的滑音可以跟著滑，也可以把音唱直，兩種都算對。', 'You may follow the original\'s slides and scoops or sing the plain note; both count.', '原曲のしゃくりやポルタメントは、真似しても、まっすぐ歌っても正解です。'),
  'rules.ranks': ('等級', 'Ranks', 'ランク'),
  'rules.tips': ('小技巧', 'Tips', 'コツ'),
  'rules.tipHeadphones': ('戴耳機，避免伴奏被麥克風收進去影響偵測。', 'Wear headphones so the accompaniment does not leak into the microphone.', 'ヘッドホンを着けて、伴奏がマイクに入らないようにしましょう。'),
  'rules.tipMic': ('麥克風靠近嘴巴，聲音太小的片段會被當成沒唱。', 'Keep the microphone close; passages that are too quiet count as not sung.', 'マイクは口の近くに。声が小さすぎる部分は歌っていないと判定されます。'),
  'rules.tipPreview': ('先用「預覽」聽幾次、看鋼琴卷軸熟悉旋律，再按「開始錄製」。', 'Use Preview to listen a few times and learn the melody on the piano roll before you press Start recording.', '「プレビュー」で何度か聴き、ピアノロールでメロディを覚えてから「録音開始」を押しましょう。'),
  'rules.tipSilence': ('該唱的地方不要沒聲音，換氣太長會被算成漏唱。', 'Do not go silent where the original sings; a long breath counts as a missed note.', '原曲が歌っているところで無音にならないように。長い息継ぎは歌い逃しと判定されます。'),
  'rules.tipKey': ('唱不上去就用「升降 Key」調整，不影響分數。', 'If the key is too high, use the key shift; it does not affect the score.', 'キーが高すぎるときは「キー」で調整しましょう。点数には影響しません。'),
  'rules.fullDoc': ('完整計分演算法', 'Full scoring algorithm', '採点アルゴリズムの詳細'),
  'rules.fullDocHint': ('想知道對齊方法、指標定義與公式的人請看這份文件（GitHub）。', 'Alignment, metric definitions and formulas are in this document (GitHub).', 'アライメント手法、指標の定義、計算式はこちらの文書（GitHub）にあります。'),
  'about.title': ('關於', 'About', 'このアプリについて'),
  'about.licenses': ('授權', 'Licenses', 'ライセンス'),
  'about.nonCommercial': ('非商業使用', 'non-commercial', '非商用'),
  'about.appLicense': ('本程式以 MIT 授權釋出。', 'This app is released under the MIT license.', 'このアプリは MIT ライセンスで公開されています。'),
  'about.engineVersion': ('引擎版本', 'Engine version', 'エンジンのバージョン'),
  'about.version': ('版本', 'Version', 'バージョン'),
  'about.author': ('作者', 'Author', '作者'),
  'about.download': ('下載（GitHub Releases）', 'Download (GitHub Releases)', 'ダウンロード（GitHub Releases）'),
  'about.repo': ('原始碼', 'Source code', 'ソースコード'),
  'about.checkUpdate': ('檢查更新', 'Check for updates', 'アップデートを確認'),
  'about.checking': ('檢查中…', 'Checking…', '確認中…'),
  'about.upToDate': ('已是最新版本（{version}）', 'Up to date ({version})', '最新バージョンです（{version}）'),
  'about.newVersion': ('有新版本 {version}', 'New version {version} available', '新しいバージョン {version} があります'),
  'about.downloadVersion': ('下載 {version}', 'Download {version}', '{version} をダウンロード'),
  'about.checkFailed': ('無法檢查更新', 'Update check failed', 'アップデートを確認できません'),
  'about.citations': ('引用與致謝（docs/CITATIONS.md）', 'Citations and acknowledgements (docs/CITATIONS.md)', '引用と謝辞（docs/CITATIONS.md）'),
};
