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
  'sing.note': ('目前音', 'Note', '現在の音'),
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
    '會播放一串短促聲響並用麥克風錄下，請將音量調到可聽見。',
    'Plays a short click burst and records it with the microphone; make sure the output is audible.',
    '短いクリック音を再生してマイクで録音します。音量を聞こえる大きさにしてください。',
  ),
  'settings.notCalibrated': ('尚未量測', 'Not calibrated', '未測定'),
  'settings.livePitch': ('即時音高來源', 'Live pitch source', 'リアルタイムピッチの方式'),
  'settings.livePitch.dsp': ('DSP（低延遲）', 'DSP (low latency)', 'DSP（低遅延）'),
  'settings.livePitch.swiftf0': ('SwiftF0（精準）', 'SwiftF0 (accurate)', 'SwiftF0（高精度）'),
  'settings.livePitch.both': ('兩者', 'Both', '両方'),
  'settings.separation': ('分離品質', 'Separation quality', '分離品質'),
  'settings.separation.fast': ('快速（單模型）', 'Fast (single model)', '高速（1 モデル）'),
  'settings.separation.best': ('最佳（雙模型）', 'Best (two models)', '最高品質（2 モデル）'),
  'settings.defaultLanguage': ('預設歌詞語言', 'Default lyrics language', '既定の歌詞言語'),
  'settings.octaveInvariant': ('八度不敏感評分', 'Octave-invariant scoring', 'オクターブを区別しない採点'),
  'settings.octaveInvariantHint': (
    '允許在不同八度演唱並自動偵測移調',
    'Allow singing in another octave; transposition is detected automatically',
    '別のオクターブで歌っても正解とし、移調は自動で検出します',
  ),
  'settings.dataFolder': ('資料夾', 'Data folder', 'データフォルダ'),
  'settings.reload': ('重新整理', 'Refresh', '更新'),
  'settings.detect': ('重新偵測', 'Re-detect', '再検出'),
  'settings.restartNote': ('變更於下次處理／演唱時生效', 'Applies to the next prep/sing session', '次回の処理／歌唱から適用されます'),
  // about
  'about.title': ('關於', 'About', 'このアプリについて'),
  'about.licenses': ('授權', 'Licenses', 'ライセンス'),
  'about.nonCommercial': ('非商業使用', 'non-commercial', '非商用'),
  'about.appLicense': ('本程式以 MIT 授權釋出。', 'This app is released under the MIT license.', 'このアプリは MIT ライセンスで公開されています。'),
  'about.engineVersion': ('引擎版本', 'Engine version', 'エンジンのバージョン'),
  'about.citations': ('引用與致謝（docs/CITATIONS.md）', 'Citations and acknowledgements (docs/CITATIONS.md)', '引用と謝辞（docs/CITATIONS.md）'),
};
