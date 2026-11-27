// Controller of one sing session: owns the engine's LiveAudio (the master
// clock), the live pitch trace, recording and take post-processing.
//
// Per-frame data goes through ValueNotifiers (position, hud) so the widget
// tree is not rebuilt per frame; coarse state uses ChangeNotifier.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../scoring/rhythm.dart';
import '../services/app_log.dart';
import '../services/items.dart';
import '../services/model_registry.dart';
import '../services/song_library.dart';
import '../services/settings.dart';
import 'app_services.dart';
import 'beat_grid.dart';
import 'duet_parts.dart';
import 'lyrics.dart';
import 'ghost_notes.dart';
import 'playback_clock.dart';
import 'live_judge.dart';
import 'range_finder.dart';
import 'live_trace.dart';
import 'loudness.dart';
import 'sing_settings.dart';
import 'tuning_wand.dart';
import 'scoring_bridge.dart';
import 'song_data.dart';
import 'track_timeline.dart';
import 'voice_range.dart';

/// What plays under the singer: the accompaniment, the original mix (guide
/// vocal), or the accompaniment with the melody on a synth (MIDI guide).
enum TrackKind { inst, mix, midi }

class SingHud {
  const SingHud({
    this.noteName = '—',
    this.cents = double.nan,
    this.levelDb = -90,
    this.voiced = false,
    this.refNoteName = '—',
    this.midi = double.nan,
    this.rawMidi = double.nan,
  });
  final String noteName;

  /// The sung pitch in its real octave; NaN while unvoiced.
  final double rawMidi;

  /// The sung pitch as drawn on the roll (folded to the reference's octave
  /// when octave align is on); NaN while unvoiced.
  final double midi;
  final double cents;
  final double levelDb;
  final bool voiced;
  final String refNoteName;
}

class TakeProcessing {
  const TakeProcessing(this.stage, this.fraction);
  final String stage; // i18n key
  final double fraction;
}

class SingSession extends ChangeNotifier implements PlaybackClock {
  SingSession({required this.services, required this.song, required this.notes, required this.refF0})
      : files = services.library.files(song),
        octaveAlign = true,
        _octaveInvariant = services.settings.octaveInvariant;

  final AppServices services;
  final Song song;
  final SongFiles files;
  NoteList notes;

  /// Beat grid (detected and/or user tempo) used for the roll and metronome.
  BeatGrid beatGrid = BeatGrid.empty;

  void setBeatGrid(BeatGrid g) {
    beatGrid = g;
    try {
      _live?.setClicks(g.times, g.accents);
    } catch (_) {}
    notifyListeners();
  }

  /// Metronome of this song (from its sing settings; the global setting
  /// until it is changed for the song).
  late bool metronomeOn = services.settings.metronomeOn;
  late double metronomeGain = services.settings.metronomeGain;

  /// Applies the metronome on/off and level to the audio engine.
  void applyMetronome() {
    try {
      _live?.clickGain = metronomeOn && !beatGrid.isEmpty ? metronomeGain : 0;
    } catch (_) {}
  }

  void setMetronomeOn(bool v) {
    metronomeOn = v;
    _metronomeSet = true;
    applyMetronome();
    _saveSoon();
    notifyListeners();
  }

  void setMetronomeGain(double v) {
    metronomeGain = v.clamp(0.0, 1.5).toDouble();
    _metronomeSet = true;
    applyMetronome();
    _saveSoon();
    notifyListeners();
  }

  // ---- per-song sing settings --------------------------------------------------

  bool _metronomeSet = false;
  bool _trackSet = false;
  Timer? _saveTimer;

  SongSingSettings get singSettings => SongSingSettings(
        track: _trackSet ? track.name : null,
        pitchShift: pitchShift,
        volume: volumeAuto ? null : volume,
        octaveAlign: octaveAlign,
        windowSeconds: windowSeconds,
        metronomeOn: _metronomeSet ? metronomeOn : null,
        metronomeGain: _metronomeSet ? metronomeGain : null,
      );

  void _applySaved(SongSingSettings v) {
    if (v.track != null) {
      _trackSet = true;
      track = TrackKind.values.asNameMap()[v.track] ?? TrackKind.inst;
    }
    // A key saved while the range was widened is brought back into the
    // current range.
    pitchShift = v.pitchShift.clamp(-keyRange, keyRange).toDouble();
    if (v.volume != null) {
      volume = v.volume!;
      volumeAuto = false;
    }
    octaveAlign = v.octaveAlign;
    windowSeconds = v.windowSeconds;
    if (v.metronomeOn != null || v.metronomeGain != null) {
      _metronomeSet = true;
      metronomeOn = v.metronomeOn ?? metronomeOn;
      metronomeGain = v.metronomeGain ?? metronomeGain;
    }
  }

  /// The volume follows the track's measured loudness until the singer moves
  /// the slider.
  bool volumeAuto = true;

  /// Measured loudness of the song's tracks (null until known).
  SongLoudness? loudness;

  /// Sets the automatic volume for the current track, when it is automatic.
  void _applyAutoVolume() {
    if (!volumeAuto) return;
    volume = loudness?.autoGain(_loudKey, target: services.settings.targetLufs) ?? 1.0;
    _live?.volume = volume;
  }

  /// Returns the volume to automatic (the track's target loudness).
  void setVolumeAuto() {
    if (volumeAuto) return;
    volumeAuto = true;
    _applyAutoVolume();
    _saveSoon();
    notifyListeners();
  }

  /// Puts every setting of this song back to how it was first opened: the
  /// instrumental, original key, automatic volume, global metronome, default
  /// roll window and octave folding. The song then remembers that.
  void resetToOriginal() {
    final st = services.settings;
    _saveTimer?.cancel();
    _saveTimer = null;
    _trackSet = false;
    _metronomeSet = false;
    volumeAuto = true;
    final want = hasInst ? TrackKind.inst : TrackKind.mix;
    if (want != track) {
      setTrack(want);
      _trackSet = false;
    }
    setPitchShift(0);
    _applyAutoVolume();
    octaveAlign = true;
    windowSeconds = 8;
    metronomeOn = st.metronomeOn;
    metronomeGain = st.metronomeGain;
    applyMetronome();
    _saveTimer?.cancel();
    _saveTimer = null;
    File(files.singSettingsJson).delete().catchError((Object _) => File(files.singSettingsJson));
    notifyListeners();
  }

  /// Saves the song's sing settings shortly after the last change.
  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    singSettings.save(files.singSettingsJson).catchError((Object _) {});
  }

  /// Sounds a sine at MIDI pitch [midi] as heard (the key shift is added),
  /// or stops it when null. Used while a note is held in the editor.
  void previewTone(double? midi) {
    try {
      if (midi == null) {
        _live?.setTone(0);
      } else {
        _live?.setTone(440.0 * math.pow(2, (midi + pitchShift - 69) / 12));
      }
    } catch (_) {}
  }

  /// Applies the vocal return and reverb settings to the audio engine.
  void applyVoiceFx() {
    final st = services.settings;
    try {
      _live?.vocalReturn = st.vocalReturn;
      _live?.setReverb(st.reverbOn, st.reverbMix);
    } catch (_) {}
  }

  /// Replaces the reference notes after a user edit (pitch / delete).
  void replaceNotes(NoteList n) {
    notes = n;
    _songRange = null;
    _duetNotes = null;
    _syncGuideSoon();
    notifyListeners();
  }

  /// The melody's range in the original key (see voice_range.dart).
  SongRange get songRange => _songRange ??= SongRange.of(notes);
  SongRange? _songRange;

  /// "一鍵移調": the key change that fits the melody into [voice]'s range.
  /// The singer's own range from the keys held so far (null until it spans
  /// [VoiceZone.minOwnSpan] semitones).
  VoiceZone? get ownRange => VoiceZone.ofReached(reachedKeys.value);

  /// AI key change into a male or female range, or the singer's own.
  void autoTranspose(VoiceType voice) {
    final zone = voice == VoiceType.you ? ownRange : VoiceZone.of(voice);
    if (zone != null) setPitchShift(songRange.bestShift(zone, maxShift: keyRange).toDouble());
  }
  final F0Curve refF0;

  LiveAudio? _live;
  LiveAudio? get live => _live;
  String? initError;

  @override
  final ValueNotifier<double> position = ValueNotifier(0);
  final ValueNotifier<SingHud> hud = ValueNotifier(const SingHud());
  final ValueNotifier<TakeProcessing?> processing = ValueNotifier(null);
  final LiveTrace trace = LiveTrace();

  /// Real-time judgement pop-ups of the current recording (null before the
  /// first one); shown when the live judgements setting is on.
  LiveJudge? judge;

  TrackKind track = TrackKind.inst;
  double pitchShift = 0;
  double volume = 1.0;
  bool octaveAlign;
  double windowSeconds = 8;
  bool recording = false;
  @override
  bool playing = false;
  double duration = 0;
  double latencyCompensation = 0;
  DateTime? recordStartedAt;
  final bool _octaveInvariant;

  int _wantedSource = 1;
  DateTime _lastHud = DateTime.fromMillisecondsSinceEpoch(0);
  SingHud _pendingHud = const SingHud();
  bool _hudDirty = false;

  bool get ready => _live != null && initError == null;
  /// An accompaniment: the separated one, or one the user imported.
  bool get hasInst => File(files.backingWav).existsSync();
  bool get hasMix => File(files.mixWav).existsSync();

  String _pathOf(TrackKind t) => t == TrackKind.inst ? files.backingWav : files.mixWav;

  /// Both stems are loaded at once (see [init]): the accompaniment as the
  /// engine's main stem when it exists, the original mix as its alt stem.
  TrackKind _mainKind = TrackKind.inst;
  bool _hasAlt = false;
  int _stemIndex(TrackKind t) => (t == TrackKind.midi ? TrackKind.inst : t) == _mainKind ? 0 : 1;

  /// What played under the singer during the current take: the track at the
  /// start (time 0) and every switch, on the song timeline. Saved with the
  /// take (`track_timeline`) so a replay could reproduce it one day; replays
  /// use the accompaniment for now.
  List<TrackSwitch> _trackLog = const [];
  static double _round3(double v) => (v * 1000).roundToDouble() / 1000;

  /// The MIDI guide plays over the accompaniment, so it needs one (and notes).
  bool get canMidiGuide => hasInst && !notes.isEmpty;

  /// Loudness entry for the volume: the MIDI guide uses the accompaniment's.
  String get _loudKey => track == TrackKind.midi ? TrackKind.inst.name : track.name;

  bool _canPlay(TrackKind t) => switch (t) {
        TrackKind.midi => _mainKind == TrackKind.inst,
        _ => t == _mainKind || _hasAlt,
      };

  /// Renders the notes into the engine's MIDI guide (debounced: note edits
  /// call this on every drag step).
  Timer? _guideTimer;

  /// The audio device has not called back for a while (issue #8): the
  /// microphone delivers nothing, so playback and capture are both stopped.
  bool deviceStalled = false;
  static const stallSeconds = 2.0;
  Timer? _stallTimer;

  void _watchDevice() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final l = _live;
      if (l == null) return;
      final silent = l.silentSeconds;
      final stalled = silent > stallSeconds;
      if (stalled == deviceStalled) return;
      deviceStalled = stalled;
      if (stalled) {
        AppLog.warn('audio device stalled: no callback for ${silent.toStringAsFixed(1)} s (the microphone delivers nothing)');
      } else {
        AppLog.info('audio device running again');
      }
      notifyListeners();
    });
  }
  void _syncGuideSoon() {
    _guideTimer?.cancel();
    _guideTimer = Timer(const Duration(milliseconds: 250), _syncGuide);
  }

  void _syncGuide() {
    _guideTimer?.cancel();
    _guideTimer = null;
    final l = _live;
    if (l == null) return;
    try {
      l.setGuideNotes(notes.onset, notes.offset, notes.pitch);
    } catch (e) {
      debugPrint('MIDI guide: $e');
    }
  }

  Future<void> init() async {
    final s = services.settings;
    _applySaved(await SongSingSettings.load(files.singSettingsJson));
    loudness = await SongLoudness.load(files.loudnessJson);
    if (volumeAuto) volume = loudness?.autoGain(_loudKey, target: services.settings.targetLufs) ?? 1.0;
    try {
      final l = LiveAudio.create(
        services.engine,
        captureDevice: s.captureDeviceId,
        playbackDevice: s.playbackDeviceId,
        sampleRate: s.sampleRate,
      );
      _live = l;
      if (track == TrackKind.inst && !hasInst && hasMix) track = TrackKind.mix;
      if (track == TrackKind.mix && !hasMix && hasInst) track = TrackKind.inst;
      // Both stems up front (decoded and resampled on a worker isolate), so
      // switching between them later is instant.
      _mainKind = hasInst ? TrackKind.inst : TrackKind.mix;
      final alt = _mainKind == TrackKind.inst ? TrackKind.mix : TrackKind.inst;
      _hasAlt = alt == TrackKind.mix ? hasMix : hasInst;
      if (!_canPlay(track)) track = _mainKind;
      l.selectTrack(_stemIndex(track));
      await l.loadTracks(_pathOf(_mainKind), alt: _hasAlt ? _pathOf(alt) : null);
      duration = l.trackDuration;
      _syncGuide();
      l.guide = track == TrackKind.midi;
      l.volume = volume;
      l.pitchShift = pitchShift;
      applyVoiceFx();
      final lat = s.latencySeconds;
      if (lat != null) {
        l.latencyCompensation = lat;
        latencyCompensation = lat;
      } else {
        latencyCompensation = l.latency().output;
      }
      _wantedSource = s.livePitchMode == 0 ? 0 : 1;
    } catch (e) {
      initError = '$e';
    }
    _startMonitor();
    if (_live != null) _watchDevice();
    notifyListeners();
    // Songs prepared before loudness was measured: measure now (a second or
    // two with ffmpeg) and apply it if the volume is still automatic.
    if (loudness?.inst == null || loudness?.mix == null) {
      services.pipeline.ensureLoudness(song).then((l) {
        if (l == null || _live == null) return;
        loudness = l;
        _applyAutoVolume();
        notifyListeners();
      });
    }
  }

  // ---- transport -------------------------------------------------------------

  void play() {
    final l = _live;
    if (l == null) return;
    try {
      l.play();
    } catch (e) {
      initError = '$e';
    }
    notifyListeners();
  }

  /// Not while recording: the capture keeps running through a pause, and a
  /// take is aligned to the track with one offset, so everything sung after
  /// it would be scored and replayed late. Stop the take instead.
  void pause() {
    if (recording) return;
    _live?.pause();
    notifyListeners();
  }

  void togglePlay() => (_live?.isPlaying ?? false) ? pause() : play();

  void seek(double seconds) {
    final l = _live;
    if (l == null) return;
    l.seek(seconds.clamp(0, duration));
    position.value = l.position;
    if (!recording) trace.clear();
  }

  void restart() => seek(0);

  /// Both stems are already in the engine: this is a short crossfade at the
  /// playing position, with no gap, so it is allowed while recording too.
  void setTrack(TrackKind t) {
    // In a duet with the original singing the other part, this is the
    // track under the singer's own lines.
    if (duetPart != null && duetVoice) _duetBase = t;
    _selectTrack(t);
  }

  void _selectTrack(TrackKind t, {bool auto = false}) {
    final l = _live;
    if (t == track || l == null || !_canPlay(t)) return;
    try {
      if (recording) _trackLog.add(TrackSwitch(_round3(l.position), t.name));
      track = t;
      if (!auto) {
        _trackSet = true;
        _saveSoon();
      }
      l.selectTrack(_stemIndex(t));
      l.guide = t == TrackKind.midi;
      if (volumeAuto) volume = loudness?.autoGain(_loudKey, target: services.settings.targetLufs) ?? 1.0;
      l.volume = volume;
    } catch (e) {
      initError = '$e';
    }
    notifyListeners();
  }

  /// The key is fixed for a take: scoring assumes one key per take and the
  /// replay is rendered in the key saved with it.
  bool get canChangeKey => ready && !recording;

  /// ±6 semitones, or ±12 when widened in Settings.
  int get keyRange => services.settings.keyRange;

  void setPitchShift(double semitones) {
    if (recording) return;
    pitchShift = semitones.clamp(-keyRange, keyRange).roundToDouble();
    _live?.pitchShift = pitchShift;
    judge?.pitchShift = pitchShift;
    _saveSoon();
    notifyListeners();
  }

  void setVolume(double v) {
    volume = v.clamp(0, SongLoudness.maxGain);
    volumeAuto = false;
    _live?.volume = volume;
    _saveSoon();
    notifyListeners();
  }

  void setOctaveAlign(bool v) {
    octaveAlign = v;
    judge?.foldOctave = v || _octaveInvariant;
    _saveSoon();
    notifyListeners();
  }

  void setWindowSeconds(double s) {
    windowSeconds = s.clamp(4, 16);
    _saveSoon();
    notifyListeners();
  }

  // ---- per-frame tick (called from a Ticker) -------------------------------------

  void tick() {
    final l = _live;
    if (l == null) return;
    final pos = l.position;
    playing = l.isPlaying;
    if (recording) {
      _drainFrames(l, pos);
      judge?.update(pos);
    } else if (_monitoring) {
      _drainFrames(l, pos);
    }
    position.value = pos;
    _followDuet(pos);
    // Throttled HUD update (~15 Hz).
    final now = DateTime.now();
    if (now.difference(_lastHud).inMilliseconds >= 66) {
      _lastHud = now;
      final level = l.inputLevelDb;
      final h = _pendingHud;
      hud.value = SingHud(noteName: h.noteName, cents: h.cents, levelDb: level, voiced: h.voiced, refNoteName: h.refNoteName, midi: h.midi, rawMidi: h.rawMidi);
      sungMidi.value = h.voiced ? h.midi : double.nan;
      _hudDirty = false;
    }
    // Track finished while recording. The engine stops playback by itself at
    // the end, so this checks the position and not the playing flag.
    if (recording && !_endReported && duration > 0 && pos >= duration - 0.05) {
      _endReported = true;
      if (playing) l.pause();
      playing = false;
      notifyListeners();
      onTrackEnded?.call();
    }
  }

  /// Called once per take when the track plays to its end while recording;
  /// the sing screen stops, scores and shows the results.
  VoidCallback? onTrackEnded;
  bool _endReported = false;

  void _drainFrames(LiveAudio l, double pos) {
    final frames = l.readFrames();
    if (frames.isEmpty) return;
    final settings = services.settings;
    final gateOn = settings.noiseGateEnabled;
    final gateDb = settings.noiseGateDb;
    for (final f in frames) {
      // Live judgements use the engine's onset frames (source 2) only; their
      // confidence is the level the speakers played (to ignore leakage).
      if (f.source == 2) {
        if (recording && playing) judge?.addFrame(f.time, onset: f.f0 > 0.5, levelDb: f.rmsDb, playbackDb: f.confidence);
        continue;
      }
      if (f.source != _wantedSource) continue;
      final voiced = f.f0 > 0 && (f.source == 0 || f.confidence >= 0.5) && (!gateOn || f.rmsDb >= gateDb);
      // Legato notes (no new syllable) are judged from the pitch.
      if (recording && playing) judge?.addPitch(f.time, voiced ? hzToMidi(f.f0) : double.nan);
      if (!voiced) {
        _pendingHud = SingHud(noteName: '—', cents: double.nan, voiced: false, refNoteName: _pendingHud.refNoteName);
        _hudDirty = true;
        continue;
      }
      final midi = hzToMidi(f.f0);
      // Paused (preview or a take), frame times are capture time, not track
      // time: compare with the note at the playhead instead.
      final refRaw = notes.pitchAt(playing ? f.time : pos);
      final ref = refRaw.isNaN ? double.nan : refRaw + pitchShift;
      double display = midi;
      double cents = double.nan;
      var cat = PitchCategory.none;
      if (!ref.isNaN) {
        final folded = foldToOctaveOf(midi, ref);
        if (octaveAlign) display = folded;
        cents = ((octaveAlign || _octaveInvariant) ? (folded - ref) : (midi - ref)) * 100.0;
        cat = PitchCategory.of(cents, lenience: lenience);
      }
      // The pitch line, while the track plays (recording or preview): frame
      // times are on the track clock then. Paused, they are capture time and
      // the line would run on ahead of the stopped playhead.
      if (playing) trace.add(f.time, midi, display, cents, cat);
      _pendingHud = SingHud(noteName: noteName(midi), cents: cents, voiced: true, refNoteName: ref.isNaN ? '—' : noteName(ref), midi: display, rawMidi: midi);
      if (!recording) _noteReached(midi, f.time);
      _hudDirty = true;
    }
    if (!_hudDirty) {
      final refRaw = notes.pitchAt(pos);
      _pendingHud = SingHud(noteName: _pendingHud.noteName, cents: _pendingHud.cents, voiced: _pendingHud.voiced, refNoteName: refRaw.isNaN ? '—' : noteName(refRaw + pitchShift), midi: _pendingHud.midi, rawMidi: _pendingHud.rawMidi);
    }
  }

  // ---- pitch monitor (before recording) -------------------------------------------
  //
  // Outside a take the microphone is still analysed (DSP pitch only, the
  // audio is not kept), so the dashboard shows the note being sung and
  // collects the notes the singer reaches: their range, next to the song's.

  bool _monitoring = false;

  /// Bumped by every monitor start and stop, so a start still loading the
  /// model gives up when it was stopped (or restarted) meanwhile.
  int _monitorGen = 0;

  /// The live pitch source from the settings: 0 = DSP (MPM), 1 = SwiftF0 with
  /// its runtime and model, or DSP when the model is missing or fails to load.
  Future<(int, EngineRuntime?, String?)> _livePitchSource() async {
    if (services.settings.livePitchMode == 0) return (0, null, null);
    try {
      final model = services.swiftF0ModelPath;
      if (!await File(model).exists()) return (0, null, null);
      return (1, await services.backend.runtime(), model);
    } catch (_) {
      return (0, null, null);
    }
  }

  /// Pitch detection outside a take (preview), with the same source as a
  /// take so the line behaves the same: pitch frames only, no recording.
  Future<void> _startMonitor() async {
    final l = _live;
    if (l == null || recording || _monitoring) return;
    _monitoring = true;
    final gen = ++_monitorGen;
    final (mode, rt, model) = await _livePitchSource();
    if (gen != _monitorGen) return; // stopped or restarted meanwhile
    if (_live != l || recording) {
      _monitoring = false;
      return;
    }
    try {
      if (l.isCapturing) {
        _monitoring = false;
        return;
      }
      _wantedSource = mode;
      l.startCapture(runtime: rt, swiftF0ModelPath: model, mode: mode, monitor: true);
    } catch (_) {
      // The model failed to start: fall back to DSP.
      try {
        _wantedSource = 0;
        l.startCapture(mode: 0, monitor: true);
      } catch (_) {
        _monitoring = false;
      }
    }
  }

  void _stopMonitor() {
    final l = _live;
    if (!_monitoring) return;
    _monitoring = false;
    _monitorGen++;
    try {
      if (l != null && l.isCapturing) l.stopCapture();
    } catch (_) {}
    _pendingHud = SingHud(refNoteName: _pendingHud.refNoteName);
    _hudDirty = true;
  }

  /// The sung pitch as drawn on the roll (NaN while silent), ~15 Hz.
  final ValueNotifier<double> sungMidi = ValueNotifier(double.nan);

  /// Keys the singer held for at least [RangeFinder.reachSeconds] outside a
  /// take, in their real octave: their range as found so far. Kept in the
  /// settings, so every song (and the check in Settings) shares it.
  late final RangeFinder _range = RangeFinder(services.settings.ownRangeKeys);
  ValueNotifier<Set<int>> get reachedKeys => _range.keys;
  bool _rangeListening = false;

  void _noteReached(double midi, double t) {
    if (!_rangeListening) {
      // Follow a reset made elsewhere (Settings) too.
      _rangeListening = true;
      services.settings.addListener(_syncRange);
    }
    if (_range.add(midi, t)) services.settings.setOwnRangeKeys(_range.keys.value);
  }

  void _syncRange() {
    final saved = services.settings.ownRangeKeys;
    if (!setEquals(saved, _range.keys.value)) _range.reset(saved);
  }

  void clearReachedKeys() {
    _range.reset();
    services.settings.setOwnRangeKeys(const {});
  }

  // ---- latency ------------------------------------------------------------------

  /// A latency measurement is running (on this session's own device).
  bool calibrating = false;
  Future<void>? _calibration;

  /// Measures the latency again on the open device (pauses playback, plays
  /// a burst of clicks), then uses and saves it. Throws on failure.
  Future<double> recalibrateLatency() async {
    final l = _live;
    if (l == null || recording || calibrating) throw StateError('busy');
    if (l.isPlaying) pause();
    _stopMonitor();
    calibrating = true;
    notifyListeners();
    final run = l.calibrateOnThisDevice();
    _calibration = run.then((_) {}, onError: (_) {});
    try {
      final sec = await run;
      if (_live != l) return sec;
      l.latencyCompensation = sec;
      latencyCompensation = sec;
      await services.settings.setLatencySeconds(sec);
      return sec;
    } finally {
      calibrating = false;
      _calibration = null;
      if (_live == l) {
        _startMonitor();
        notifyListeners();
      }
    }
  }

  /// Sets the latency by hand (the sing screen's -/+ buttons): applied at
  /// once to the live pitch line and saved like a measured one.
  Future<void> setLatencyManually(double seconds) async {
    if (recording || calibrating) return;
    final sec = (seconds * 1000).roundToDouble().clamp(0.0, AppSettings.maxLatencySeconds * 1000) / 1000;
    _live?.latencyCompensation = sec;
    latencyCompensation = sec;
    notifyListeners();
    await services.settings.setLatencySeconds(sec);
  }

  // ---- the Resonance Field ---------------------------------------------------------

  /// Cast before recording: the next saved take is judged twice as
  /// leniently, and one Resonance Field is used up when it is saved.
  bool fieldArmed = false;

  /// Casts or lifts the field before recording ([redeem]: buy one first when
  /// none is held). False when there is none to cast.
  Future<bool> setFieldArmed(bool on, {bool redeem = false}) async {
    if (recording || on == fieldArmed) return on == fieldArmed;
    if (on && services.items.ownedOf(ItemKind.resonanceField) <= 0) {
      if (!redeem || !await services.items.redeem(ItemKind.resonanceField)) return false;
    }
    fieldArmed = on;
    notifyListeners();
    return true;
  }

  double get _lenience => fieldArmed ? TakeField.lenience : 1;

  /// How much wider the judging is (2 with the Resonance Field armed): the
  /// pitch line's and the HUD's colour bands widen with it.
  double get lenience => _lenience;

  // ---- duet ----------------------------------------------------------------------

  /// Singing one part of a duet (null: the whole song). The lyrics are
  /// split by [duetPlan] over [duetLines] (the shown primary lines).
  DuetPart? duetPart;
  DuetPlan? duetPlan;
  List<LyricLine> duetLines = const [];

  /// The parts over time, for the roll.
  List<DuetSpan> duetSpans = const [];

  /// The original singer (the song's mix) sings the other part and the
  /// lines sung together; the singer's own lines play over [_duetBase].
  bool duetVoice = true;
  TrackKind? _duetBase;
  NoteList? _duetNotes;

  /// Sings [part] of [plan] (null part: back to the whole song).
  void setDuet(DuetPart? part, {DuetPlan? plan, List<LyricLine>? lines}) {
    if (recording) return;
    final wasVoiced = duetPart != null && duetVoice;
    duetPart = part;
    if (plan != null) duetPlan = plan;
    if (lines != null) duetLines = lines;
    final p = duetPlan;
    duetSpans = part == null || p == null ? const [] : p.spans(duetLines);
    _duetNotes = null;
    if (part != null && duetVoice && !wasVoiced) _duetBase = track == TrackKind.mix ? (_canPlay(TrackKind.inst) ? TrackKind.inst : track) : track;
    if (part == null && wasVoiced && _duetBase != null) {
      _selectTrack(_duetBase!, auto: true);
      _duetBase = null;
    }
    judge = null;
    notifyListeners();
  }

  void setDuetVoice(bool on) {
    if (on == duetVoice || recording) return;
    duetVoice = on;
    if (duetPart == null) return;
    if (on) {
      _duetBase = track;
    } else if (_duetBase != null) {
      _selectTrack(_duetBase!, auto: true);
      _duetBase = null;
    }
    notifyListeners();
  }

  /// The notes the singer is judged on: in a duet, without the other part's.
  NoteList get judgedNotes {
    final part = duetPart, plan = duetPlan;
    if (part == null || plan == null) return notes;
    return _duetNotes ??= () {
      final drop = partnerNotes(notes, duetLines, plan, part);
      final keep = [for (var i = 0; i < notes.length; i++) if (!drop.contains(i)) i];
      return NoteList(
        Float64List.fromList([for (final i in keep) notes.onset[i]]),
        Float64List.fromList([for (final i in keep) notes.offset[i]]),
        Float64List.fromList([for (final i in keep) notes.pitch[i]]),
      );
    }();
  }

  /// Whether the original sings at [t]: a line of the other part or one
  /// sung together (a little early, so the switch is done as it starts).
  bool _originalSingsAt(double t) {
    final mine = duetPart;
    if (mine == null) return false;
    for (final s in duetSpans) {
      if (s.start - 0.15 > t) break;
      if (t <= s.end + 0.1) return s.part != mine;
    }
    return false;
  }

  void _followDuet(double pos) {
    final base = _duetBase;
    if (duetPart == null || !duetVoice || base == null || !_canPlay(TrackKind.mix)) return;
    final want = _originalSingsAt(pos) ? TrackKind.mix : base;
    if (want != track) _selectTrack(want, auto: true);
  }

  // ---- recording -----------------------------------------------------------------

  Future<void> startRecording() async {
    final l = _live;
    if (l == null || recording) return;
    final settings = services.settings;
    final (mode, rt, model) = await _livePitchSource();
    _stopMonitor();
    _wantedSource = mode == 0 ? 0 : 1;
    try {
      if (l.isPlaying) l.pause();
      l.seek(0);
      _endReported = false;
      trace.clear();
      judge = LiveJudge(
        notes: judgedNotes,
        windows: RhythmWindows.forTempo(beatGrid.bpm).widened(_lenience),
        lenience: _lenience,
        pitchShift: pitchShift,
        levelFloorDb: settings.noiseGateEnabled ? settings.noiseGateDb : -50,
        judgePitch: settings.liveJudgePitch,
        foldOctave: octaveAlign || _octaveInvariant,
      );
      // The engine's onset frames (source 2) come with every capture mode.
      l.startCapture(runtime: rt, swiftF0ModelPath: model, mode: mode == 0 ? 0 : 1);
      recording = true;
      recordStartedAt = DateTime.now();
      _trackLog = [TrackSwitch(0, track.name)];
      l.play();
    } catch (e) {
      initError = '$e';
      recording = false;
      _startMonitor();
    }
    notifyListeners();
  }

  /// Stops capture and playback, saves the take; returns null when nothing was
  /// recorded. The caller then runs [processTake].
  Future<TakeInfo?> stopRecording() async {
    final l = _live;
    if (l == null || !recording) return null;
    recording = false;
    try {
      l.pause();
    } catch (_) {}
    final elapsed = l.captureElapsed;
    l.stopCapture();
    notifyListeners();
    if (elapsed < 3) {
      _startMonitor();
      return null;
    }
    processing.value = const TakeProcessing('sing.saving', 0);
    final take = await services.library.newTake(song);
    l.saveCapture(take.wav);
    _startMonitor();
    await File(take.infoJson).writeAsString(const JsonEncoder.withIndent('  ').convert({
      'song_id': song.id,
      'pitch_shift': pitchShift,
      'latency': latencyCompensation,
      'started_at': (recordStartedAt ?? DateTime.now()).toIso8601String(),
      'track': track.name,
      'track_timeline': [for (final e in _trackLog) e.toJson()],
      'duration': elapsed,
      if (duetPart != null) 'duet': duetPart!.name,
    }));
    // A duet part is judged on its own lines and those sung together: the
    // take keeps the song's notes without the other part's.
    final part = duetPart, plan = duetPlan;
    if (part != null && plan != null) {
      try {
        final songNotes = jsonDecode(await File(files.notesJson).readAsString()) as Map<String, dynamic>;
        await File(take.notesJson).writeAsString(jsonEncode(duetNotesJson(songNotes, duetLines, plan, part)));
      } catch (e) {
        AppLog.warn('duet notes: $e');
      }
    }
    if (fieldArmed) {
      // The take keeps the field (its scoring reads it); one is used up.
      await TakeField.mark(take.dir, DateTime.now());
      await services.items.consume(ItemKind.resonanceField);
      fieldArmed = false;
      notifyListeners();
    }
    return take;
  }

  /// Extracts F0 from the take and scores it. Throws on failure.
  Future<ScoreData> processTake(TakeInfo take) async {
    try {
      return await scoreTake(
        services: services,
        files: files,
        take: take,
        octaveInvariant: _octaveInvariant,
        onProgress: (p) => processing.value = p,
      );
    } finally {
      processing.value = null;
    }
  }

  /// Scores a saved take: extracts its F0 with SwiftF0 (downloading the
  /// model first when it is missing) and writes score.json. Also used to
  /// score a take whose scoring failed earlier.
  static Future<ScoreData> scoreTake({
    required AppServices services,
    required SongFiles files,
    required TakeInfo take,
    required bool octaveInvariant,
    void Function(TakeProcessing)? onProgress,
    bool reuseF0 = false,
    bool keepGate = false,
  }) async {
    // Re-scoring with newer rules: the take's pitch file is already there.
    if (reuseF0 && await File(take.f0Json).exists()) return _scoreSaved(services, files, take, octaveInvariant, keepGate: keepGate);
    final model = ModelRegistry.swiftF0;
    if (!await services.models.isInstalled(model)) {
      onProgress?.call(const TakeProcessing('sing.downloadingModel', 0));
      await services.models.install(
        model,
        onProgress: (_, _, done, total) => onProgress?.call(TakeProcessing('sing.downloadingModel', total > 0 ? done / total : 0)),
      );
    }
    onProgress?.call(const TakeProcessing('sing.extractingF0', 0));
    final rt = await services.backend.runtime();
    final job = rt.f0Extract(modelPath: services.swiftF0ModelPath, inputWav: take.wav, f0Out: take.f0Json);
    final sub = job.progress.listen((p) => onProgress?.call(TakeProcessing('sing.extractingF0', p.fraction)));
    try {
      await job.done;
    } finally {
      await sub.cancel();
    }
    onProgress?.call(const TakeProcessing('sing.scoring', 0));
    return _scoreSaved(services, files, take, octaveInvariant);
  }

  /// [keepGate]: the noise gate the take was scored with, not the current
  /// one (so only what changed on purpose moves the score).
  /// The score [take] would get with the Tuning Wand also used on the notes
  /// [spans] (onset, offset; scored as it was, nothing saved).
  static Future<ScoreData> previewWand(AppServices services, SongFiles files, TakeInfo take, bool octaveInvariant, List<(double, double)> spans) =>
      _scoreSaved(services, files, take, octaveInvariant, keepGate: true, previewSpans: spans);

  /// What the Tuning Wand is worth on each note of [take] (see
  /// [WandWeights]): read from the take folder, else worked out a batch of
  /// notes at a time ([onProgress] 0..1) and kept there.
  static Future<WandWeights> wandWeights(AppServices services, SongFiles files, TakeInfo take, {void Function(double done)? onProgress}) async {
    final notesPath = await take.notesFor(files.notesJson);
    final gate = ((await ScoringBridge.load(take.scoreJson))?.raw['noise_gate_db'] as num?)?.toDouble();
    final tempo = (await TempoOverride.load(files.tempoJson)).bpm ?? (await DetectedBeats.load(files.beatsJson))?.bpm;
    final calibrated = services.settings.latencySeconds != null;
    final field = await TakeField.isOn(take.dir);
    Future<String> stamp(String path) async {
      final f = File(path);
      if (!await f.exists()) return '-';
      final st = await f.stat();
      return '${st.size}@${st.modified.millisecondsSinceEpoch}';
    }

    final key = 'v${WandWeights.version}|${await stamp(take.f0Json)}|${await stamp(notesPath)}|${await stamp(files.refF0Json)}|$gate|$tempo|$calibrated|$field';
    final cached = await WandWeights.load(take.dir, key);
    if (cached != null) return cached;
    final notes = await NoteList.load(notesPath);
    final offset = await takeTimeOffset(take);
    var base = 0.0;
    final raw = <int, double>{};
    const batch = 20;
    for (var k = 0; k < notes.length; k += batch) {
      final idx = [for (var i = k; i < math.min(k + batch, notes.length); i++) i];
      final (b, gains) = await ScoringBridge.wandGains(
        notesJsonPath: notesPath,
        refF0JsonPath: files.refF0Json,
        takeF0JsonPath: take.f0Json,
        scoreJsonPath: take.scoreJson,
        candidates: [for (final i in idx) (notes.onset[i], notes.offset[i])],
        takeTimeOffset: offset,
        takeWavPath: take.wav,
        referenceWavPath: files.vocalsWav,
        noiseGateDb: gate,
        tempoBpm: tempo,
        calibratedTiming: calibrated,
      );
      base = b;
      for (var j = 0; j < idx.length; j++) {
        raw[WandWeights.onsetKey(notes.onset[idx[j]])] = gains[j];
      }
      onProgress?.call(math.min(1, (k + batch) / notes.length));
    }
    final w = WandWeights(key: key, base: base, raw: raw);
    try {
      await w.save(take.dir);
    } catch (_) {}
    return w;
  }

  static Future<ScoreData> _scoreSaved(AppServices services, SongFiles files, TakeInfo take, bool octaveInvariant, {bool keepGate = false, List<(double, double)> previewSpans = const []}) async {
    final settings = services.settings;
    final preview = previewSpans.isNotEmpty;
    double? gate = settings.noiseGateEnabled ? settings.noiseGateDb : null;
    if (keepGate) gate = ((await ScoringBridge.load(take.scoreJson))?.raw['noise_gate_db'] as num?)?.toDouble();
    // The take keeps the notes it is scored against, so later edits or
    // cleaning of the song's notes do not shift its results and replay.
    if (!preview) await snapshotTakeNotes(files.notesJson, [take.dir]);
    // With wands, the total comes from what each tuned note is worth.
    final weights = preview || (await TakeWand.load(take.dir)).uses.isNotEmpty ? await wandWeights(services, files, take) : null;
    final score = await ScoringBridge.scoreAndSave(
      notesJsonPath: await take.notesFor(files.notesJson),
      refF0JsonPath: files.refF0Json,
      takeF0JsonPath: take.f0Json,
      scoreJsonPath: take.scoreJson,
      octaveInvariant: octaveInvariant,
      takeTimeOffset: await takeTimeOffset(take),
      takeWavPath: take.wav,
      referenceWavPath: files.vocalsWav,
      noiseGateDb: gate,
      // Rhythm windows follow the song tempo (manual BPM first, else detected).
      tempoBpm: (await TempoOverride.load(files.tempoJson)).bpm ?? (await DetectedBeats.load(files.beatsJson))?.bpm,
      calibratedTiming: settings.latencySeconds != null,
      previewSpans: previewSpans,
      weights: weights,
    );
    if (!preview) services.library.markTakesChanged(files);
    return score;
  }

  /// Offset to add to take-file time to get track time (from the capture sidecar).
  static Future<double> takeTimeOffset(TakeInfo take) async {
    try {
      final side = File('${take.wav}.json');
      if (!await side.exists()) return 0;
      final j = jsonDecode(await side.readAsString()) as Map<String, dynamic>;
      final start = (j['track_start_offset'] as num?)?.toDouble() ?? 0;
      final lat = (j['latency'] as num?)?.toDouble() ?? 0;
      return start - lat;
    } catch (_) {
      return 0;
    }
  }

  @override
  void dispose() {
    _guideTimer?.cancel();
    _stallTimer?.cancel();
    if (_saveTimer != null) _saveNow();
    final l = _live;
    _live = null;
    if (l != null) {
      try {
        if (l.isCapturing) l.stopCapture();
        if (l.isPlaying) l.pause();
      } catch (_) {}
      // A measurement still running uses the device: close it afterwards.
      final c = _calibration;
      if (c != null) {
        c.whenComplete(l.dispose);
      } else {
        l.dispose();
      }
    }
    position.dispose();
    hud.dispose();
    processing.dispose();
    if (_rangeListening) services.settings.removeListener(_syncRange);
    _range.dispose();
    sungMidi.dispose();
    super.dispose();
  }
}
