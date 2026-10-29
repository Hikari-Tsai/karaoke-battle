import 'dart:math' as math;
// Controller of one sing session: owns the engine's LiveAudio (the master
// clock), the live pitch trace, recording and take post-processing.
//
// Per-frame data goes through ValueNotifiers (position, hud) so the widget
// tree is not rebuilt per frame; coarse state uses ChangeNotifier.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../engine/engine.dart';
import '../services/song_library.dart';
import 'app_services.dart';
import 'beat_grid.dart';
import 'playback_clock.dart';
import 'live_trace.dart';
import 'scoring_bridge.dart';
import 'song_data.dart';

enum TrackKind { inst, mix }

class SingHud {
  const SingHud({this.noteName = '—', this.cents = double.nan, this.levelDb = -90, this.voiced = false, this.refNoteName = '—'});
  final String noteName;
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

  /// Applies the metronome on/off and level settings to the audio engine.
  void applyMetronome() {
    final st = services.settings;
    try {
      _live?.clickGain = st.metronomeOn && !beatGrid.isEmpty ? st.metronomeGain : 0;
    } catch (_) {}
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
    notifyListeners();
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
  bool get hasInst => File(files.instWav).existsSync();
  bool get hasMix => File(files.mixWav).existsSync();

  String get _trackPath => track == TrackKind.inst ? files.instWav : files.mixWav;

  Future<void> init() async {
    final s = services.settings;
    try {
      final l = LiveAudio.create(
        services.engine,
        captureDevice: s.captureDeviceId,
        playbackDevice: s.playbackDeviceId,
        sampleRate: s.sampleRate,
      );
      _live = l;
      if (!hasInst && hasMix) track = TrackKind.mix;
      l.loadTrack(_trackPath);
      duration = l.trackDuration;
      l.volume = volume;
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
    notifyListeners();
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

  void pause() {
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

  void setTrack(TrackKind t) {
    final l = _live;
    if (t == track || l == null) return;
    final pos = l.position;
    final wasPlaying = l.isPlaying;
    try {
      if (wasPlaying) l.pause();
      track = t;
      l.loadTrack(_trackPath);
      duration = l.trackDuration;
      l.seek(pos.clamp(0, duration));
      l.volume = volume;
      l.pitchShift = pitchShift;
      if (wasPlaying) l.play();
    } catch (e) {
      initError = '$e';
    }
    notifyListeners();
  }

  void setPitchShift(double semitones) {
    pitchShift = semitones.clamp(-6, 6).roundToDouble();
    _live?.pitchShift = pitchShift;
    notifyListeners();
  }

  void setVolume(double v) {
    volume = v.clamp(0, 1.5);
    _live?.volume = volume;
    notifyListeners();
  }

  void setOctaveAlign(bool v) {
    octaveAlign = v;
    notifyListeners();
  }

  void setWindowSeconds(double s) {
    windowSeconds = s.clamp(4, 16);
    notifyListeners();
  }

  // ---- per-frame tick (called from a Ticker) -------------------------------------

  void tick() {
    final l = _live;
    if (l == null) return;
    final pos = l.position;
    playing = l.isPlaying;
    if (recording) _drainFrames(l, pos);
    position.value = pos;
    // Throttled HUD update (~15 Hz).
    final now = DateTime.now();
    if (now.difference(_lastHud).inMilliseconds >= 66) {
      _lastHud = now;
      final level = l.inputLevelDb;
      final h = _pendingHud;
      hud.value = SingHud(noteName: h.noteName, cents: h.cents, levelDb: level, voiced: h.voiced, refNoteName: h.refNoteName);
      _hudDirty = false;
    }
    if (playing && duration > 0 && pos >= duration - 0.02 && recording) {
      // Track finished: stop playback; the caller decides whether to score.
      l.pause();
      playing = false;
      notifyListeners();
    }
  }

  void _drainFrames(LiveAudio l, double pos) {
    final frames = l.readFrames();
    if (frames.isEmpty) return;
    final settings = services.settings;
    final gateOn = settings.noiseGateEnabled;
    final gateDb = settings.noiseGateDb;
    for (final f in frames) {
      if (f.source != _wantedSource) continue;
      final voiced = f.f0 > 0 && (f.source == 0 || f.confidence >= 0.5) && (!gateOn || f.rmsDb >= gateDb);
      if (!voiced) {
        _pendingHud = SingHud(noteName: '—', cents: double.nan, voiced: false, refNoteName: _pendingHud.refNoteName);
        _hudDirty = true;
        continue;
      }
      final midi = hzToMidi(f.f0);
      final refRaw = notes.pitchAt(f.time);
      final ref = refRaw.isNaN ? double.nan : refRaw + pitchShift;
      double display = midi;
      double cents = double.nan;
      var cat = PitchCategory.none;
      if (!ref.isNaN) {
        final folded = foldToOctaveOf(midi, ref);
        if (octaveAlign) display = folded;
        cents = ((octaveAlign || _octaveInvariant) ? (folded - ref) : (midi - ref)) * 100.0;
        final a = cents.abs();
        cat = a <= 50 ? PitchCategory.good : (a <= 100 ? PitchCategory.near : PitchCategory.off);
      }
      trace.add(f.time, midi, display, cents, cat);
      _pendingHud = SingHud(noteName: noteName(midi), cents: cents, voiced: true, refNoteName: ref.isNaN ? '—' : noteName(ref));
      _hudDirty = true;
    }
    if (!_hudDirty) {
      final refRaw = notes.pitchAt(pos);
      _pendingHud = SingHud(noteName: _pendingHud.noteName, cents: _pendingHud.cents, voiced: _pendingHud.voiced, refNoteName: refRaw.isNaN ? '—' : noteName(refRaw + pitchShift));
    }
  }

  // ---- recording -----------------------------------------------------------------

  Future<void> startRecording() async {
    final l = _live;
    if (l == null || recording) return;
    final settings = services.settings;
    EngineRuntime? rt;
    String? model;
    var mode = settings.livePitchMode;
    try {
      if (mode != 0 && await File(services.swiftF0ModelPath).exists()) {
        rt = await services.backend.runtime();
        model = services.swiftF0ModelPath;
      } else {
        mode = 0;
      }
    } catch (_) {
      mode = 0;
    }
    _wantedSource = mode == 0 ? 0 : 1;
    try {
      if (l.isPlaying) l.pause();
      l.seek(0);
      trace.clear();
      l.startCapture(runtime: rt, swiftF0ModelPath: model, mode: mode);
      recording = true;
      recordStartedAt = DateTime.now();
      l.play();
    } catch (e) {
      initError = '$e';
      recording = false;
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
    if (elapsed < 3) return null;
    processing.value = const TakeProcessing('sing.saving', 0);
    final take = await services.library.newTake(song);
    l.saveCapture(take.wav);
    await File(take.infoJson).writeAsString(const JsonEncoder.withIndent('  ').convert({
      'song_id': song.id,
      'pitch_shift': pitchShift,
      'latency': latencyCompensation,
      'started_at': (recordStartedAt ?? DateTime.now()).toIso8601String(),
      'track': track.name,
      'duration': elapsed,
    }));
    return take;
  }

  /// Extracts F0 from the take and scores it. Throws on failure.
  Future<ScoreData> processTake(TakeInfo take) async {
    processing.value = const TakeProcessing('sing.extractingF0', 0);
    final rt = await services.backend.runtime();
    final job = rt.f0Extract(modelPath: services.swiftF0ModelPath, inputWav: take.wav, f0Out: take.f0Json);
    final sub = job.progress.listen((p) => processing.value = TakeProcessing('sing.extractingF0', p.fraction));
    try {
      await job.done;
    } finally {
      await sub.cancel();
    }
    processing.value = const TakeProcessing('sing.scoring', 0);
    final result = await ScoringBridge.scoreAndSave(
      notesJsonPath: files.notesJson,
      refF0JsonPath: files.refF0Json,
      takeF0JsonPath: take.f0Json,
      scoreJsonPath: take.scoreJson,
      octaveInvariant: _octaveInvariant,
      takeTimeOffset: await takeTimeOffset(take),
      takeWavPath: take.wav,
      referenceWavPath: files.vocalsWav,
      noiseGateDb: services.settings.noiseGateEnabled ? services.settings.noiseGateDb : null,
      // Rhythm windows follow the song tempo (manual BPM first, else detected).
      tempoBpm: (await TempoOverride.load(files.tempoJson)).bpm ?? (await DetectedBeats.load(files.beatsJson))?.bpm,
      calibratedTiming: services.settings.latencySeconds != null,
    );
    processing.value = null;
    return result;
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
    final l = _live;
    _live = null;
    if (l != null) {
      try {
        if (l.isCapturing) l.stopCapture();
        if (l.isPlaying) l.pause();
      } catch (_) {}
      l.dispose();
    }
    position.dispose();
    hud.dispose();
    processing.dispose();
    super.dispose();
  }
}
