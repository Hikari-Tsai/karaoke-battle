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

  /// Round-trip latency measured by calibration (seconds); null = not calibrated.
  double? get latencySeconds => _prefs.getDouble('latency_seconds');
  Future<void> setLatencySeconds(double s) => _set('latency_seconds', s);

  /// Live pitch source: 0 = DSP, 1 = SwiftF0, 2 = both.
  /// 0 = DSP, 1 = SwiftF0 (default). The former 2 ("both") displayed SwiftF0
  /// only, so saved 2s read as 1.
  int get livePitchMode => _get('live_pitch_mode', 1) == 0 ? 0 : 1;
  Future<void> setLivePitchMode(int m) => _set('live_pitch_mode', m == 0 ? 0 : 1);

  bool get dismissedBackendDialog => _get('dismissed_backend_dialog', false);
  Future<void> setDismissedBackendDialog(bool v) => _set('dismissed_backend_dialog', v);

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

  /// The user ticked "don't ask again" on the first-use calibration prompt.
  bool get calibrationPromptDismissed => _get('calib_prompt_dismissed', false);
  Future<void> setCalibrationPromptDismissed(bool v) => _set('calib_prompt_dismissed', v);

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

  /// Name written into exported replay files.
  String get playerName => _prefs.getString('player_name') ?? '';
  Future<void> setPlayerName(String v) => _set('player_name', v.trim());

  int get overlayPort => _get('overlay_port', 0);
  Future<void> setOverlayPort(int port) => _set('overlay_port', port);
}
