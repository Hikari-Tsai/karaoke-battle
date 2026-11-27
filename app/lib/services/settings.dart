// Persisted user settings (SharedPreferences).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BackendChoice { auto, cuda, directml, coreml, cpu }

enum SeparationQuality {
  /// Kim_Vocal_2 only: vocals = primary, accompaniment = mixture - vocals.
  fast,

  /// Kim_Vocal_2 for vocals + Inst_HQ_4 for the accompaniment (two passes).
  best,
}

class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);
  final SharedPreferences _prefs;

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  T _get<T>(String key, T def) => (_prefs.get(key) as T?) ?? def;

  Future<void> _set(String key, Object value) async {
    switch (value) {
      case String v:
        await _prefs.setString(key, v);
      case int v:
        await _prefs.setInt(key, v);
      case double v:
        await _prefs.setDouble(key, v);
      case bool v:
        await _prefs.setBool(key, v);
      default:
        throw ArgumentError('unsupported type');
    }
    notifyListeners();
  }

  /// UI language: 'zh', 'en' or 'ja'; null until the user picks one (then the
  /// system locale decides).
  String? get uiLanguage => _prefs.getString('ui_language');
  Future<void> setUiLanguage(String code) => _set('ui_language', code);

  BackendChoice get backend => BackendChoice.values.byName(_get('backend', 'auto'));
  Future<void> setBackend(BackendChoice b) => _set('backend', b.name);

  /// 'game-large' or 'game-small'
  String get gameModelId => _get('game_model', 'game-large');
  Future<void> setGameModelId(String id) => _set('game_model', id);

  SeparationQuality get separationQuality => SeparationQuality.values.byName(_get('sep_quality', 'best'));
  Future<void> setSeparationQuality(SeparationQuality q) => _set('sep_quality', q.name);

  /// Default transcription language code: zh, ja, yue, en or '' (auto/unknown).
  String get defaultLanguage => _get('language', 'zh');
  Future<void> setDefaultLanguage(String code) => _set('language', code);

  String? get captureDeviceId => _prefs.getString('capture_device');
  Future<void> setCaptureDeviceId(String? id) async {
    if (id == null) {
      await _prefs.remove('capture_device');
      notifyListeners();
    } else {
      await _set('capture_device', id);
    }
  }

  String? get playbackDeviceId => _prefs.getString('playback_device');
  Future<void> setPlaybackDeviceId(String? id) async {
    if (id == null) {
      await _prefs.remove('playback_device');
      notifyListeners();
    } else {
      await _set('playback_device', id);
    }
  }

  int get sampleRate => _get('sample_rate', 48000);
  Future<void> setSampleRate(int sr) => _set('sample_rate', sr);

  /// Highest latency the manual controls allow (Bluetooth speakers reach 300 ms).
  static const maxLatencySeconds = 0.6;

  /// Round-trip latency measured by calibration or set by hand (seconds);
  /// null = not calibrated.
  double? get latencySeconds => _prefs.getDouble('latency_seconds');
  Future<void> setLatencySeconds(double s) => _set('latency_seconds', s);

  /// Live pitch source (preview and singing): 0 = DSP (default), 1 = SwiftF0.
  /// The former 2 ("both") displayed SwiftF0 only, so saved 2s read as 1.
  /// Scoring re-analyses the take with SwiftF0 whatever this is.
  int get livePitchMode {
    final v = _get('live_pitch_mode', 0);
    return v == 1 || v == 2 ? 1 : 0;
  }

  Future<void> setLivePitchMode(int m) => _set('live_pitch_mode', m == 0 ? 0 : 1);

  bool get dismissedBackendDialog => _get('dismissed_backend_dialog', false);
  Future<void> setDismissedBackendDialog(bool v) => _set('dismissed_backend_dialog', v);

  /// "Don't remind me" on the dialog about using a yt-dlp from PATH.
  bool get dismissedYtDlpPathOnly => _get('dismissed_ytdlp_path_only', false);
  Future<void> setDismissedYtDlpPathOnly(bool v) => _set('dismissed_ytdlp_path_only', v);

  /// Octave-invariant + transposition-tolerant scoring (project default).
  bool get octaveInvariant => _get('octave_invariant', true);
  Future<void> setOctaveInvariant(bool v) => _set('octave_invariant', v);

  /// Microphone noise gate in dBFS: pitch frames quieter than this are treated
  /// as silence, live and when scoring. [noiseGateOff] (the minimum) disables it.
  static const double noiseGateOff = -60;
  static const double noiseGateMax = -20;
  double get noiseGateDb => (_prefs.getDouble('noise_gate_db') ?? noiseGateOff).clamp(noiseGateOff, noiseGateMax);
  Future<void> setNoiseGateDb(double db) => _set('noise_gate_db', db.clamp(noiseGateOff, noiseGateMax).toDouble());
  bool get noiseGateEnabled => noiseGateDb > noiseGateOff;

  /// Loudness (LUFS) the automatic volume brings each song's track to.
  static const double targetLufsDefault = -16, targetLufsMin = -24, targetLufsMax = -8;
  double get targetLufs => (_prefs.getDouble('target_lufs') ?? targetLufsDefault).clamp(targetLufsMin, targetLufsMax).toDouble();
  Future<void> setTargetLufs(double v) => _set('target_lufs', ((v * 2).round() / 2).clamp(targetLufsMin, targetLufsMax).toDouble());

  /// The user ticked "don't ask again" on the first-use calibration prompt.
  bool get calibrationPromptDismissed => _get('calib_prompt_dismissed', false);
  Future<void> setCalibrationPromptDismissed(bool v) => _set('calib_prompt_dismissed', v);

  /// The user ticked "don't ask again" on the first-use range check.
  bool get rangePromptDismissed => _get('range_prompt_dismissed', false);
  Future<void> setRangePromptDismissed(bool v) => _set('range_prompt_dismissed', v);

  /// Show romaji under Japanese lyrics.
  bool get showRomaji => _get('show_romaji', true);
  Future<void> setShowRomaji(bool v) => _set('show_romaji', v);

  /// Show synced lyrics (YouTube subtitles) on the sing screen.
  bool get showLyrics => _get('show_lyrics', true);
  Future<void> setShowLyrics(bool v) => _set('show_lyrics', v);

  /// Piano-roll vertical zoom: 0 = whole song range, 1 = tightest
  /// ([rollMinSemitones] visible, taller note bars).
  static const double rollMinSemitones = 8;
  double get rollZoom => (_prefs.getDouble('roll_zoom') ?? 0).clamp(0.0, 1.0);
  Future<void> setRollZoom(double z) => _set('roll_zoom', z.clamp(0.0, 1.0).toDouble());

  /// Sing screen: a piano keyboard in the roll's pitch column.
  bool get rollKeyboard => _get('roll_keyboard', true);
  Future<void> setRollKeyboard(bool v) => _set('roll_keyboard', v);

  /// Sing history: its start point. The stats and the list count takes from
  /// this moment on; null counts all of them. Nothing is deleted.
  DateTime? get historyClearedAt => DateTime.tryParse(_prefs.getString('history_cleared_at') ?? '');
  Future<void> setHistoryClearedAt(DateTime? t) async {
    if (t == null) {
      await _prefs.remove('history_cleared_at');
      notifyListeners();
    } else {
      await _set('history_cleared_at', t.toIso8601String());
    }
  }

  /// Sing history: single takes removed from the list (and the setlist
  /// log), as `historyKey`s. The recordings stay unless deleted too.
  Set<String> get historyHidden => {...?_prefs.getStringList('history_hidden')};
  Future<void> setHistoryHidden(Set<String> keys) async {
    await _prefs.setStringList('history_hidden', keys.toList()..sort());
    notifyListeners();
  }

  /// Debug builds: the sidebar's 開發模式 switch (see dev_mode.dart). Has
  /// no effect in a release build.
  bool get devMode => _get('dev_mode', true);
  Future<void> setDevMode(bool v) => _set('dev_mode', v);

  /// YouTube songs whose artist, year and language were already asked for
  /// (ids).
  /// (`yt_meta_checked2`: asked again once, when the year became music
  /// tracks only.)
  Set<String> get ytMetaChecked => {...?_prefs.getStringList('yt_meta_checked2')};
  Future<void> addYtMetaChecked(String id) async {
    final ids = ytMetaChecked..add(id);
    await _prefs.setStringList('yt_meta_checked2', ids.toList()..sort());
  }

  /// Library: songs hidden from the list (ids), until restored from the
  /// hidden songs. Their files, takes and history stay as they are.
  Set<String> get hiddenSongs => {...?_prefs.getStringList('hidden_songs')};
  Future<void> setSongHidden(String id, bool hidden) async {
    final ids = hiddenSongs;
    hidden ? ids.add(id) : ids.remove(id);
    await _prefs.setStringList('hidden_songs', ids.toList()..sort());
    notifyListeners();
  }

  /// Scoring rules page: the SSS demo replays already downloaded, demo key ->
  /// id of the imported replay (deleting that replay offers the download again).
  Map<String, String> get demoReplays => {
        for (final e in _prefs.getStringList('demo_replays') ?? const <String>[])
          if (e.contains('=')) e.substring(0, e.indexOf('=')): e.substring(e.indexOf('=') + 1),
      };
  Future<void> setDemoReplay(String key, String replayId) async {
    final m = demoReplays..[key] = replayId;
    await _prefs.setStringList('demo_replays', [for (final e in m.entries) '${e.key}=${e.value}']..sort());
    notifyListeners();
  }

  /// Setlists (copied text and the setlist log) show each song's score.
  bool get setlistScores => _get('setlist_scores', true);
  Future<void> setSetlistScores(bool v) => _set('setlist_scores', v);

  /// Results: the rolling-score ticks and the new-record cheer.
  bool get resultSounds => _get('result_sounds', true);

  /// Sound effect volume, 0..1 (half the full level by default).
  double get sfxVolume => _get('sfx_volume', 0.5).clamp(0.0, 1.0).toDouble();
  Future<void> setSfxVolume(double v) => _set('sfx_volume', v.clamp(0.0, 1.0).toDouble());
  Future<void> setResultSounds(bool v) => _set('result_sounds', v);

  /// Sing screen: the meter panel is slid in.
  bool get hudVisible => _get('hud_visible', true);
  Future<void> setHudVisible(bool v) => _set('hud_visible', v);

  /// Metronome on the sing screen (clicks mixed into playback).
  bool get metronomeOn => _get('metronome_on', false);
  Future<void> setMetronomeOn(bool v) => _set('metronome_on', v);
  double get metronomeGain => _get('metronome_gain', 0.6);
  Future<void> setMetronomeGain(double v) => _set('metronome_gain', v.clamp(0.0, 1.5).toDouble());

  /// Vocal return: hear the microphone through the app's output.
  bool get vocalReturn => _get('vocal_return', false);
  Future<void> setVocalReturn(bool v) => _set('vocal_return', v);
  bool get vocalReturnWarned => _get('vocal_return_warned', false);
  Future<void> setVocalReturnWarned(bool v) => _set('vocal_return_warned', v);

  /// Hall reverb on the voice (vocal return and replays); mix 0..1.
  bool get reverbOn => _get('reverb_on', false);
  Future<void> setReverbOn(bool v) => _set('reverb_on', v);
  double get reverbMix => _get('reverb_mix', 0.25);
  Future<void> setReverbMix(double v) => _set('reverb_mix', v.clamp(0.0, 1.0).toDouble());

  /// Replay balance between the music (-1) and the voice (+1); 0 = as mixed.
  double get replayBalance => _get('replay_balance', 0.0);
  Future<void> setReplayBalance(double v) => _set('replay_balance', v.clamp(-1.0, 1.0).toDouble());

  /// Replay master volume (linear gain, 0 to 2 = +6 dB); 1 = as recorded.
  double get replayVolume => _get('replay_volume', 1.0);
  Future<void> setReplayVolume(double v) => _set('replay_volume', v.clamp(0.0, 2.0).toDouble());

  /// Key change range: ±6 semitones by default, ±12 (an octave) when widened.
  bool get wideKeyRange => _get('wide_key_range', false);
  Future<void> setWideKeyRange(bool v) => _set('wide_key_range', v);
  int get keyRange => wideKeyRange ? 12 : 6;

  /// Rhythm-game judgement pop-ups while recording.
  /// Sing screen: the song's video (MV) behind the piano roll. Off, the roll
  /// has the whole stage, as for a song without video.
  bool get showVideo => _get('show_video', true);
  Future<void> setShowVideo(bool v) => _set('show_video', v);

  bool get liveJudgements => _get('live_judgements', true);
  Future<void> setLiveJudgements(bool v) => _set('live_judgements', v);

  /// The singer's range: the keys (MIDI) they have held on the microphone,
  /// found on the sing screen or by the check in Settings; shared by every
  /// song. Empty until found.
  Set<int> get ownRangeKeys {
    final v = _prefs.getString('own_range_keys');
    if (v == null || v.isEmpty) return const {};
    return {for (final p in v.split(',')) ?int.tryParse(p)};
  }

  Future<void> setOwnRangeKeys(Set<int> keys) async {
    if (keys.isEmpty) {
      await _prefs.remove('own_range_keys');
      notifyListeners();
      return;
    }
    await _set('own_range_keys', (keys.toList()..sort()).join(','));
  }

  /// Live judgements also judge the pitch (HIGH / LOW), ~0.15 s later. Display
  /// only: the score is computed after the take either way.
  bool get liveJudgePitch => _get('live_judge_pitch', false);
  Future<void> setLiveJudgePitch(bool v) => _set('live_judge_pitch', v);

  /// Name written into exported replay files.
  /// AI service asked for singing advice: 'claude' or 'openai'. The API
  /// keys are not here (see AiKeyStore).
  String get aiProvider => _get('ai_provider', 'claude') == 'openai' ? 'openai' : 'claude';
  Future<void> setAiProvider(String p) => _set('ai_provider', p);

  static const aiDefaultModels = {'claude': 'claude-opus-5-5', 'openai': 'gpt-6.1-sol'};

  /// Model id used with [provider].
  String aiModel(String provider) {
    final v = _prefs.getString('ai_model_$provider')?.trim() ?? '';
    return v.isEmpty ? aiDefaultModels[provider]! : v;
  }

  Future<void> setAiModel(String provider, String model) => _set('ai_model_$provider', model.trim());

  /// The models last listed for [provider] (JSON, see AiModelInfo), shown
  /// before the list is fetched again.
  String aiModelListJson(String provider) => _prefs.getString('ai_models_$provider') ?? '';
  Future<void> setAiModelListJson(String provider, String json) => _set('ai_models_$provider', json);

  /// Profile: the cartoon singer's look (an AvatarKind name: female, male,
  /// neutral, cat, dog, rabbit, bear).
  String get avatarKind => _get('avatar_gender', 'female');
  Future<void> setAvatarKind(String v) => _set('avatar_gender', v);

  String get playerName => _prefs.getString('player_name') ?? '';
  Future<void> setPlayerName(String v) => _set('player_name', v.trim());

  int get overlayPort => _get('overlay_port', 0);
  Future<void> setOverlayPort(int port) => _set('overlay_port', port);

  /// The duet part a battle starts on: 'a' (the default), 'b', or 'whole'
  /// (no parts). Changing the part during a battle changes it too.
  String get battlePart => switch (_prefs.getString('battle_part')) { 'b' => 'b', 'whole' => 'whole', _ => 'a' };
  Future<void> setBattlePart(String v) => _set('battle_part', v == 'b' || v == 'whole' ? v : 'a');

  /// 直播工具 › 觀眾加油: viewers' donations add points to the last song sung.
  bool get cheerEnabled => _get('cheer_enabled', false);
  Future<void> setCheerEnabled(bool v) => _set('cheer_enabled', v);

  /// 綠界's 贊助成功動畫網址 ('' = not set up). Not a secret: ECPay's public
  /// donate link carries the same ID.
  String get ecpayAlertUrl => _prefs.getString('ecpay_alert_url') ?? '';
  Future<void> setEcpayAlertUrl(String v) => _set('ecpay_alert_url', v.trim());

  /// 歐付寶's 贊助成功動畫網址 ('' = not set up).
  String get opayAlertUrl => _prefs.getString('opay_alert_url') ?? '';
  Future<void> setOpayAlertUrl(String v) => _set('opay_alert_url', v.trim());

  /// The 贊助成功動畫網址 of 'ecpay' or 'opay'.
  String alertUrlOf(String provider) => provider == 'opay' ? opayAlertUrl : ecpayAlertUrl;
  Future<void> setAlertUrlOf(String provider, String v) => provider == 'opay' ? setOpayAlertUrl(v) : setEcpayAlertUrl(v);

  /// Donations already counted, by service and id (the last 300).
  List<String> get cheerSeenIds => _prefs.getStringList('cheer_seen_ids') ?? const [];
  Future<void> setCheerSeenIds(List<String> ids) => _prefs.setStringList('cheer_seen_ids', ids.length > 300 ? ids.sublist(ids.length - 300) : ids);

  /// How many NT$ make one point of cheer: 150 by default, and no less.
  static const cheerTwdPerPointDefault = 150;
  static const cheerTwdPerPointMin = 150;
  int get cheerTwdPerPoint => _get('cheer_twd_per_point', cheerTwdPerPointDefault).clamp(cheerTwdPerPointMin, 100000).toInt();
  Future<void> setCheerTwdPerPoint(int v) => _set('cheer_twd_per_point', v.clamp(cheerTwdPerPointMin, 100000).toInt());
}
