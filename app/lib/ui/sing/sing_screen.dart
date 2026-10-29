// The sing screen: video + HUD, scrolling piano roll, transport/record controls.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/beat_grid.dart';
import '../../state/lyrics.dart';
import '../../state/note_edits.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../results/results_screen.dart';
import 'piano_roll.dart';
import 'lyrics_overlay.dart';
import 'tempo_dialog.dart';
import 'video_pane.dart';
import '../widgets/calibration.dart';
import '../widgets/metronome_icon.dart';
import '../widgets/voice_fx.dart';

class SingScreen extends StatefulWidget {
  const SingScreen({super.key, required this.song});
  final Song song;

  @override
  State<SingScreen> createState() => _SingScreenState();
}

class _SingScreenState extends State<SingScreen>
    with SingleTickerProviderStateMixin {
  SingSession? _session;
  Ticker? _ticker;
  String? _loadError;
  bool _busy = false;
  Lyrics? _lyrics;

  /// Width / height of the song's video (16:9 until the player reports it).
  double _videoAspect = 16 / 9;

  // ---- tempo ----
  DetectedBeats? _detected;
  TempoOverride _tempo = const TempoOverride();

  Future<void> _loadBeats(SingSession s) async {
    _detected = await DetectedBeats.load(s.files.beatsJson);
    _tempo = await TempoOverride.load(s.files.tempoJson);
    s.setBeatGrid(BeatGrid.build(_detected, _tempo, duration: s.duration));
    s.applyMetronome();
    if (mounted) setState(() {});
  }

  Future<void> _openTempo() async {
    final s = _session;
    if (s == null) return;
    // Beats may have been detected meanwhile (older songs are done lazily).
    _detected ??= await DetectedBeats.load(s.files.beatsJson);
    if (!mounted) return;
    final r = await showTempoDialog(
      context,
      session: s,
      detected: _detected,
      current: _tempo,
    );
    if (r == null) return;
    _tempo = r;
    await r.save(s.files.tempoJson);
    s.setBeatGrid(BeatGrid.build(_detected, _tempo, duration: s.duration));
    s.applyMetronome();
    if (mounted) setState(() {});
  }

  // ---- note editing ----
  bool _editing = false;
  int? _selected;
  NoteEditor? _editor;
  bool _hasEdits = false;
  int _revision = 0;

  /// The reference curve as loaded, before deleted-note spans are masked.
  Float64List? _refOrig;
  NoteList? _dragBase; // notes when a drag started (preview is not undoable)

  final _keys = FocusNode(debugLabel: 'sing-keys');

  NoteEditor _ensureEditor() {
    final s = _session!;
    return _editor ??= NoteEditor(s.notes, _loadedSpans);
  }

  List<TimeSpan> _loadedSpans = const [];

  void _applyMask(List<TimeSpan> spans) {
    final s = _session!;
    final orig = _refOrig;
    if (orig != null) s.refF0.midi.setAll(0, orig);
    maskCurve(s.refF0, spans);
    _revision++;
  }

  Future<void> _commit() async {
    final s = _session!;
    final e = _editor!;
    s.replaceNotes(e.notes);
    _applyMask(e.excluded);
    final path = s.files.notesJson;
    await saveNoteEdits(path, e.notes, e.excluded);
    _hasEdits = true;
    if (mounted) setState(() {});
  }

  void _toggleEdit() {
    final s = _session;
    if (s == null || s.recording) return;
    setState(() {
      _editing = !_editing;
      _selected = null;
      if (_editing) _ensureEditor();
    });
  }

  void _nudge(int semis) {
    final i = _selected;
    if (i == null) return;
    final e = _ensureEditor();
    e.setPitch(i, e.notes.pitch[i] + semis);
    _commit();
  }

  void _deleteSelected() {
    final i = _selected;
    if (i == null) return;
    _ensureEditor().delete(i);
    _selected = null;
    _commit();
  }

  void _undo() {
    final e = _editor;
    if (e == null || !e.undo()) return;
    _selected = null;
    _commit();
  }

  Future<void> _restoreOriginal() async {
    final s = _session!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('edit.restoreTitle')),
        content: Text(tr('edit.restoreBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('edit.restore')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await restoreOriginalNotes(s.files.notesJson);
    final notes = await NoteList.load(s.files.notesJson);
    _editor = NoteEditor(notes);
    _loadedSpans = const [];
    _selected = null;
    _hasEdits = false;
    s.replaceNotes(notes);
    _applyMask(const []);
    if (mounted) setState(() {});
  }

  void _onSelectNote(int? i) => setState(() => _selected = i);

  /// Live preview while dragging a note vertically; committed on release.
  void _onDragNote(int i, int semis, bool done) {
    final s = _session!;
    final e = _ensureEditor();
    _dragBase ??= e.notes;
    final base = _dragBase!;
    if (i >= base.length) return;
    final pitch = base.pitch[i] + semis;
    if (done) {
      _dragBase = null;
      s.replaceNotes(e.notes); // drop the preview
      if (semis != 0) {
        e.setPitch(i, pitch);
        _commit();
      }
      return;
    }
    s.replaceNotes(noteWithPitch(base, i, pitch));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent ev) {
    if (ev is! KeyDownEvent && ev is! KeyRepeatEvent)
      return KeyEventResult.ignored;
    final s = _session;
    if (s == null || !s.ready || _busy) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    final hw = HardwareKeyboard.instance;
    final cmd = hw.isMetaPressed || hw.isControlPressed;
    // Play / pause (space, K like YouTube).
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      if (ev is KeyDownEvent) s.togglePlay();
      return KeyEventResult.handled;
    }
    // Seek: arrows 5 s, J / L 10 s (not while recording).
    final seek = switch (k) {
      LogicalKeyboardKey.arrowLeft => -5.0,
      LogicalKeyboardKey.arrowRight => 5.0,
      LogicalKeyboardKey.keyJ => -10.0,
      LogicalKeyboardKey.keyL => 10.0,
      _ => 0.0,
    };
    if (seek != 0) {
      if (!s.recording)
        s.seek(
          (s.position.value + seek).clamp(
            0.0,
            math.max(0.0, s.duration - 0.05),
          ),
        );
      return KeyEventResult.handled;
    }
    if (_editing) {
      if (cmd && k == LogicalKeyboardKey.keyZ) {
        _undo();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        if (_selected != null) {
          setState(() => _selected = null);
        } else {
          _toggleEdit();
        }
        return KeyEventResult.handled;
      }
      if (_selected != null) {
        if (k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown) {
          _nudge(k == LogicalKeyboardKey.arrowUp ? 1 : -1);
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.delete ||
            k == LogicalKeyboardKey.backspace) {
          _deleteSelected();
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _loadLyrics(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final l = Lyrics.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      );
      if (mounted && !l.isEmpty) setState(() => _lyrics = l);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      // First use without a latency measurement: offer it before the session
      // opens its own audio device (calibration needs the device to itself).
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await showCalibrationPromptIfNeeded(context, services);
      if (!mounted) return;
      final files = services.library.files(widget.song);
      _loadLyrics(files.lyricsJson);
      final notes = await NoteList.load(files.notesJson);
      final refF0 = await F0Curve.load(
        files.refF0Json,
        confidenceThreshold: 0.5,
      );
      // Deleted (ghost) notes from earlier edits also hide their span of the
      // reference curve; keep the unmasked curve for undo / restore.
      try {
        final nj = jsonDecode(
          await File(files.notesJson).readAsString(),
        ) as Map<String, dynamic>;
        _loadedSpans = excludedSpansFromJson(nj);
      } catch (_) {}
      _refOrig = Float64List.fromList(refF0.midi);
      maskCurve(refF0, _loadedSpans);
      _hasEdits = await hasNoteEdits(files.notesJson);
      final s = SingSession(
        services: services,
        song: widget.song,
        notes: notes,
        refF0: refF0,
      );
      await s.init();
      if (!mounted) {
        s.dispose();
        return;
      }
      _session = s;
      _ticker = createTicker((_) => s.tick())..start();
      _loadBeats(s);
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  @override
  void dispose() {
    _keys.dispose();
    _ticker?.dispose();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _stopAndScore() async {
    final s = _session!;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final take = await s.stopRecording();
      if (take == null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('sing.tooShort'))));
        }
        return;
      }
      final score = await s.processTake(take);
      if (!mounted) return;
      // New personal best for this song? (compare with the other scored takes)
      double? previousBest;
      try {
        for (final t in await context.read<AppServices>().library.takes(
          widget.song,
        )) {
          if (t.id == take.id || t.total == null) continue;
          if (previousBest == null || t.total! > previousBest) {
            previousBest = t.total;
          }
        }
      } catch (_) {}
      final newRecord = previousBest == null || score.total > previousBest;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ResultsScreen(
            song: widget.song,
            take: take,
            score: score,
            newRecord: newRecord,
            previousBest: previousBest,
          ),
        ),
      );
    } catch (e) {
      s.processing.value = null;
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text(tr('error')),
            content: SelectableText('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr('ok')),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keyboard shortcuts live on this node; after any click (buttons,
    // sliders) focus comes back here so arrows never move a slider too.
    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Listener(
        onPointerUp: (_) {
          if (!_keys.hasPrimaryFocus) _keys.requestFocus();
        },
        child: _buildScaffold(context),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    // Keep the engine's metronome level in sync with the settings.
    context.watch<AppSettings>();
    _session?.applyMetronome();
    _session?.applyVoiceFx();
    // Recording started while editing: leave edit mode.
    if (_editing && (_session?.recording ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _editing = false;
            _selected = null;
          });
        }
      });
    }
    final s = _session;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.song.title}${widget.song.artist.isNotEmpty ? ' — ${widget.song.artist}' : ''}',
        ),
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText('${tr('error')}: $_loadError'),
              ),
            )
          : s == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: s,
              builder: (context, _) => Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Column(
                      children: [
                        if (s.initError != null)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: cs.errorContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SelectableText(
                              '${tr('sing.audioInitFailed')}: ${s.initError}',
                              style: TextStyle(color: cs.onErrorContainer),
                            ),
                          ),
                        // Stage: video at the bottom, the piano roll over it, lyrics on
                        // top; the meter panel slides in from the left.
                        Expanded(
                          child: _RollArea(
                            session: s,
                            editing: _editing,
                            selectedNote: _selected,
                            revision: _revision,
                            onSelectNote: _onSelectNote,
                            onDragNote: _onDragNote,
                            aspectRatio: widget.song.hasVideo
                                ? _videoAspect
                                : null,
                            below: [
                              if (widget.song.hasVideo)
                                Positioned.fill(
                                  child: VideoPane(
                                    session: s,
                                    path: s.files.videoMp4,
                                    fit: BoxFit.contain,
                                    background: true,
                                    onAspectRatio: (a) {
                                      if (mounted &&
                                          (a - _videoAspect).abs() > 0.01) {
                                        setState(() => _videoAspect = a);
                                      }
                                    },
                                  ),
                                ),
                            ],
                            above: [
                              if (_lyrics != null &&
                                  context.watch<AppSettings>().showLyrics)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: IgnorePointer(
                                    child: LyricsOverlay(
                                      lyrics: _lyrics!,
                                      position: s.position,
                                      noteOnsets: s.notes.onset,
                                      noteOffsets: s.notes.offset,
                                      showRomaji: context
                                          .watch<AppSettings>()
                                          .showRomaji,
                                    ),
                                  ),
                                ),
                              _HudDrawer(session: s),
                              if (_editing)
                                Positioned(
                                  top: 8,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: _EditBar(
                                      canUndo: _editor?.canUndo ?? false,
                                      hasEdits: _hasEdits,
                                      onUndo: _undo,
                                      onRestore: _restoreOriginal,
                                      onDone: _toggleEdit,
                                    ),
                                  ),
                                ),
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _TempoChip(
                                      grid: s.beatGrid,
                                      metronomeOn: context
                                          .watch<AppSettings>()
                                          .metronomeOn,
                                      onOpen: _openTempo,
                                      onToggleMetronome: () {
                                        final st = context.read<AppSettings>();
                                        st
                                            .setMetronomeOn(!st.metronomeOn)
                                            .then((_) => s.applyMetronome());
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                    const _StageButton(child: VocalReturnButton()),
                                    const SizedBox(width: 6),
                                    _StageButton(
                                      child: ReverbButton(
                                        onPreview: (on, mix) {
                                          try {
                                            s.live?.setReverb(on, mix);
                                          } catch (_) {}
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    if (_lyrics != null)
                                      _StageButton(
                                        child: LyricsMenu(
                                          lyrics: _lyrics!,
                                          lyricsPath: s.files.lyricsJson,
                                          onChanged: () => setState(() {}),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _Controls(
                          session: s,
                          busy: _busy,
                          onStop: _stopAndScore,
                          editing: _editing,
                          onToggleEdit: _toggleEdit,
                        ),
                      ],
                    ),
                  ),
                  ValueListenableBuilder<TakeProcessing?>(
                    valueListenable: s.processing,
                    builder: (context, p, _) => p == null
                        ? const SizedBox.shrink()
                        : Positioned.fill(
                            child: Container(
                              color: Colors.black54,
                              alignment: Alignment.center,
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        tr(p.stage),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 16),
                                      SizedBox(
                                        width: 280,
                                        child: LinearProgressIndicator(
                                          value: p.fraction > 0
                                              ? p.fraction
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Scrolling piano roll with a vertical zoom slider on its left. When zoomed
/// in, the visible pitch range smoothly follows the upcoming notes.
class _RollArea extends StatefulWidget {
  const _RollArea({
    required this.session,
    this.below = const [],
    this.above = const [],
    this.aspectRatio,
    this.editing = false,
    this.selectedNote,
    this.revision = 0,
    this.onSelectNote,
    this.onDragNote,
  });
  final SingSession session;

  /// Note editing: clicks select notes (instead of seeking) and a vertical
  /// drag on a note changes its pitch by whole semitones.
  final bool editing;
  final int? selectedNote;
  final int revision;
  final ValueChanged<int?>? onSelectNote;
  final void Function(int index, int semitones, bool done)? onDragNote;

  /// When set (a video is shown), the stage keeps this width / height so the
  /// whole video fills it without bars; spare space goes around the stage.
  final double? aspectRatio;

  /// Stack layers under the roll (the video) and over it (lyrics, panels).
  final List<Widget> below;
  final List<Widget> above;

  @override
  State<_RollArea> createState() => _RollAreaState();
}

class _RollAreaState extends State<_RollArea> {
  final _range = ValueNotifier<({double min, double max})>((min: 48, max: 72));
  double? _center;

  SingSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.position.addListener(_follow);
    _follow();
  }

  @override
  void didUpdateWidget(_RollArea old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.position.removeListener(_follow);
      s.position.addListener(_follow);
    }
    _follow();
  }

  @override
  void dispose() {
    s.position.removeListener(_follow);
    _range.dispose();
    super.dispose();
  }

  double? _span;

  int? _dragIndex;
  double _dragDy = 0;
  int _dragSemis = 0;

  int? _hit(BoxConstraints c, Offset p) => hitTestNote(
    s.notes,
    Size(c.maxWidth, c.maxHeight),
    p,
    minMidi: _range.value.min,
    maxMidi: _range.value.max,
    position: s.position.value,
    windowSeconds: s.windowSeconds,
    pitchShift: s.pitchShift,
  );

  /// Keeps the notes around the playhead and the pitch just sung on screen.
  /// The slider sets the preferred zoom; when the nearby notes or the voice
  /// span more than that, the view widens (quickly) to fit them and narrows
  /// back (slowly) once it can, while the centre follows them smoothly.
  void _follow() {
    if (!mounted) return;
    final full = pitchRangeFor(s.notes, s.pitchShift);
    final zoom = context.read<AppSettings>().rollZoom;
    final fullSpan = full.max - full.min;
    final preferred =
        fullSpan - zoom * math.max(0, fullSpan - AppSettings.rollMinSemitones);
    if (preferred >= fullSpan - 1e-6) {
      _center = null;
      _span = null;
      if (_range.value != full) _range.value = full;
      return;
    }
    final pos = s.position.value;
    // Pitches sung in the last 0.6 s (display values, octave-aligned).
    final recent = <double>[];
    final tr = s.trace;
    for (var i = tr.length - 1; i >= 0 && tr.timeAt(i) >= pos - 0.6; i--) {
      if (tr.timeAt(i) <= pos + 0.1) recent.add(tr.displayAt(i));
    }
    final ess = essentialPitchRange(
      s.notes,
      s.pitchShift,
      pos - 0.6,
      pos + 2.5,
      recent,
    );
    // A voice far off the melody may leave the song's range: extend it.
    final bounds = ess == null
        ? full
        : (
            min: math.min(full.min, ess.lo - 1.5),
            max: math.max(full.max, ess.hi + 1.5),
          );
    final target = followTarget(ess, preferred, bounds.max - bounds.min);
    final tSpan = target?.span ?? preferred;
    final tCenter = target?.center ?? _center ?? (full.min + full.max) / 2;
    final c = _center, sp = _span;
    if (c == null || sp == null || (tCenter - c).abs() > sp) {
      // First frame or a seek: jump.
      _center = tCenter;
      _span = tSpan;
    } else {
      _span = sp + (tSpan - sp) * (tSpan > sp ? 0.35 : 0.04);
      _center = c + (tCenter - c) * 0.12;
    }
    final r = zoomedRange(bounds, _center!, _span!);
    // Avoid rebuilding for sub-pixel moves.
    if ((r.min - _range.value.min).abs() > 0.02 ||
        (r.max - _range.value.max).abs() > 0.02) {
      _range.value = r;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Vertical zoom slider: up = taller note bars.
        SizedBox(
          width: 34,
          child: Tooltip(
            message: tr('sing.rollZoom'),
            waitDuration: const Duration(milliseconds: 500),
            child: Column(
              children: [
                Icon(
                  Icons.zoom_in,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                      ),
                      child: Slider(
                        value: settings.rollZoom,
                        onChanged: (v) {
                          settings.setRollZoom(v);
                          _follow();
                        },
                      ),
                    ),
                  ),
                ),
                Icon(
                  Icons.zoom_out,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final stage = Listener(
                onPointerSignal: (e) {
                  if (e is PointerScrollEvent) {
                    s.setWindowSeconds(
                      s.windowSeconds + (e.scrollDelta.dy > 0 ? 1 : -1),
                    );
                  }
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.below.isNotEmpty)
                        const ColoredBox(color: Colors.black),
                      ...widget.below,
                      // Only the roll layer seeks on click; panels and buttons
                      // above it take their own clicks first.
                      LayoutBuilder(
                        builder: (context, c) => MouseRegion(
                          cursor: widget.editing
                              ? SystemMouseCursors.click
                              : MouseCursor.defer,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) {
                              if (widget.editing) {
                                widget.onSelectNote?.call(
                                  _hit(c, d.localPosition),
                                );
                                return;
                              }
                              // Click seeks relative to the playhead at 30 % of the plot.
                              final frac =
                                  (d.localPosition.dx - 46) / (c.maxWidth - 46);
                              final t =
                                  s.position.value +
                                  (frac - 0.3) * s.windowSeconds;
                              if (!s.recording) s.seek(t);
                            },
                            onVerticalDragStart: widget.editing
                                ? (d) {
                                    _dragIndex = _hit(c, d.localPosition);
                                    _dragDy = 0;
                                    _dragSemis = 0;
                                    if (_dragIndex != null)
                                      widget.onSelectNote?.call(_dragIndex);
                                  }
                                : null,
                            onVerticalDragUpdate: widget.editing
                                ? (d) {
                                    final i = _dragIndex;
                                    if (i == null) return;
                                    _dragDy += d.delta.dy;
                                    final rowH = rollRowHeight(
                                      c.maxHeight,
                                      _range.value.min,
                                      _range.value.max,
                                    );
                                    final semis = (-_dragDy / rowH).round();
                                    if (semis != _dragSemis) {
                                      _dragSemis = semis;
                                      widget.onDragNote?.call(i, semis, false);
                                    }
                                  }
                                : null,
                            onVerticalDragEnd: widget.editing
                                ? (_) {
                                    final i = _dragIndex;
                                    if (i != null)
                                      widget.onDragNote?.call(
                                        i,
                                        _dragSemis,
                                        true,
                                      );
                                    _dragIndex = null;
                                  }
                                : null,
                            child:
                                ValueListenableBuilder<
                                  ({double min, double max})
                                >(
                                  valueListenable: _range,
                                  builder: (context, range, _) => PianoRollView(
                                    notes: s.notes,
                                    refF0: s.refF0,
                                    trace: s.trace,
                                    minMidi: range.min,
                                    maxMidi: range.max,
                                    position: s.position,
                                    windowSeconds: s.windowSeconds,
                                    pitchShift: s.pitchShift,
                                    overlay: widget.below.isNotEmpty,
                                    selectedNote: widget.editing
                                        ? widget.selectedNote
                                        : null,
                                    revision: widget.revision,
                                    beatTimes: s.beatGrid.times,
                                    beatAccents: s.beatGrid.accents,
                                  ),
                                ),
                          ),
                        ),
                      ),
                      ...widget.above,
                    ],
                  ),
                ),
              );
              final a = widget.aspectRatio;
              if (a == null) return stage;
              // Largest a:1 box inside the available area, top-centred.
              var w = c.maxWidth, h = w / a;
              if (h > c.maxHeight) {
                h = c.maxHeight;
                w = h * a;
              }
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(width: w, height: h, child: stage),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The meter panel, slid in from the left edge of the stage (over the keys
/// and the already-sung part, so upcoming notes on the right stay visible).
/// A tab on the left edge shows / hides it; the state is saved.
class _HudDrawer extends StatelessWidget {
  const _HudDrawer({required this.session});
  final SingSession session;

  static const _width = 280.0;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final shown = settings.hudVisible;
    final cs = Theme.of(context).colorScheme;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: shown ? 8 : -_width,
      top: 8,
      width: _width + 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _width,
            child: _HudPanel(session: session),
          ),
          // Pull tab
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Material(
              color: cs.surface.withValues(alpha: 0.88),
              elevation: 4,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(10),
              ),
              child: InkWell(
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(10),
                ),
                onTap: () => settings.setHudVisible(!shown),
                child: Tooltip(
                  message: shown ? tr('sing.hudHide') : tr('sing.hudShow'),
                  child: SizedBox(
                    width: 26,
                    height: 56,
                    child: Icon(
                      shown ? Icons.chevron_left : Icons.speed,
                      size: 20,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Toolbar shown over the stage while editing notes.
class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.canUndo,
    required this.hasEdits,
    required this.onUndo,
    required this.onRestore,
    required this.onDone,
  });
  final bool canUndo;
  final bool hasEdits;
  final VoidCallback onUndo;
  final VoidCallback onRestore;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final undoKey = Platform.isMacOS ? '⌘Z' : 'Ctrl+Z';
    return Material(
      color: cs.surface.withValues(alpha: 0.92),
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note, color: cs.primary),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Text(
                tr('edit.hint'),
                style: theme.textTheme.bodySmall,
                maxLines: 2,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '${tr('edit.undo')} ($undoKey)',
              onPressed: canUndo ? onUndo : null,
              icon: const Icon(Icons.undo),
            ),
            TextButton(
              onPressed: hasEdits ? onRestore : null,
              child: Text(tr('edit.restore')),
            ),
            const SizedBox(width: 4),
            FilledButton(onPressed: onDone, child: Text(tr('edit.done'))),
          ],
        ),
      ),
    );
  }
}

/// "♩ 123 · 4/4" over the stage (opens the tempo dialog) with a metronome
/// toggle next to it.
class _TempoChip extends StatelessWidget {
  const _TempoChip({
    required this.grid,
    required this.metronomeOn,
    required this.onOpen,
    required this.onToggleMetronome,
  });
  final BeatGrid grid;
  final bool metronomeOn;
  final VoidCallback onOpen;
  final VoidCallback onToggleMetronome;

  @override
  Widget build(BuildContext context) {
    final bpm = grid.bpm;
    final label = bpm == null
        ? tr('tempo.chipNone')
        : '♩ ${bpm.toStringAsFixed(bpm == bpm.roundToDouble() ? 0 : 1)} · ${grid.beatsPerBar}/4';
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x66000000),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: tr('tempo.chipTooltip'),
            child: InkWell(
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          Tooltip(
            message: metronomeOn
                ? tr('tempo.metronomeOff')
                : tr('tempo.metronomeOn'),
            child: IconButton(
              onPressed: grid.isEmpty ? null : onToggleMetronome,
              icon: MetronomeIcon(
                color: metronomeOn ? const Color(0xFFFFD60A) : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round translucent backing for icon buttons drawn over the stage.
class _StageButton extends StatelessWidget {
  const _StageButton({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Color(0x66000000),
      shape: BoxShape.circle,
    ),
    child: child,
  );
}

class _HudPanel extends StatelessWidget {
  const _HudPanel({required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: cs.surface.withValues(alpha: 0.88),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ValueListenableBuilder<SingHud>(
          valueListenable: session.hud,
          builder: (context, hud, _) {
            final cents = hud.cents;
            final hasCents = !cents.isNaN;
            final color = !hasCents
                ? cs.onSurface.withValues(alpha: 0.5)
                : (cents.abs() <= 50
                      ? const Color(0xFF4CD964)
                      : (cents.abs() <= 100
                            ? const Color(0xFFFFCC00)
                            : const Color(0xFFFF3B30)));
            final level = ((hud.levelDb + 60) / 60).clamp(0.0, 1.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: tr('sing.note'),
                        value: hud.voiced ? hud.noteName : '—',
                        big: true,
                        color: color,
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: tr('results.refPitch'),
                        value: hud.refNoteName,
                        big: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(tr('sing.cents'), style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                _CentsMeter(cents: hasCents ? cents : null, color: color),
                const SizedBox(height: 4),
                Text(
                  hasCents
                      ? '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(0)} ¢'
                      : '—',
                  style: theme.textTheme.titleMedium?.copyWith(color: color),
                ),
                const SizedBox(height: 12),
                Text(tr('sing.mic'), style: theme.textTheme.labelSmall),
                const SizedBox(height: 4),
                _GatedLevelMeter(level: level, levelDb: hud.levelDb),
                const SizedBox(height: 8),
                Text(
                  '${tr('sing.latency')}: ${(session.latencyCompensation * 1000).toStringAsFixed(0)} ms',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Microphone level meter (PPM) whose noise-gate threshold is set by
/// clicking or dragging on the meter itself (far left = off). The gate is a
/// global setting: it is saved when changed and used for every song.
class _GatedLevelMeter extends StatelessWidget {
  const _GatedLevelMeter({required this.level, required this.levelDb});
  final double level; // 0..1 over -60..0 dBFS
  final double levelDb;

  static double _frac(double db) => ((db + 60) / 60).clamp(0.0, 1.0);

  void _setFromX(AppSettings settings, double x, double width) {
    final frac = (x / width).clamp(0.0, 1.0);
    final db = (-60 + 60 * frac).roundToDouble().clamp(
      AppSettings.noiseGateOff,
      AppSettings.noiseGateMax,
    );
    if (db != settings.noiseGateDb) settings.setNoiseGateDb(db);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final gateOn = settings.noiseGateEnabled;
    final gateDb = settings.noiseGateDb;
    final gateFrac = _frac(gateDb);
    final open = !gateOn || levelDb >= gateDb;
    const gold = Color(0xFFFFC107);
    return Tooltip(
      message: tr('sing.gateHint'),
      waitDuration: const Duration(milliseconds: 600),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 22,
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final gx = w * gateFrac;
                return MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) =>
                        _setFromX(settings, d.localPosition.dx, w),
                    onHorizontalDragStart: (d) =>
                        _setFromX(settings, d.localPosition.dx, w),
                    onHorizontalDragUpdate: (d) =>
                        _setFromX(settings, d.localPosition.dx, w),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // track
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 4,
                          bottom: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        // gated (ignored) zone
                        if (gateOn)
                          Positioned(
                            left: 0,
                            top: 4,
                            bottom: 4,
                            width: gx,
                            child: Container(
                              decoration: BoxDecoration(
                                color: cs.onSurface.withValues(alpha: 0.14),
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        // level
                        Positioned(
                          left: 0,
                          top: 7,
                          bottom: 7,
                          width: w * level,
                          child: Container(
                            decoration: BoxDecoration(
                              color: level > 0.95
                                  ? cs.error
                                  : (open
                                        ? cs.primary
                                        : cs.onSurface.withValues(alpha: 0.35)),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        // threshold handle: line + triangles top and bottom
                        Positioned(
                          left: (gx - 6).clamp(-6.0, w - 6),
                          top: 0,
                          bottom: 0,
                          width: 12,
                          child: CustomPaint(
                            painter: _GateHandlePainter(
                              color: gateOn
                                  ? gold
                                  : cs.onSurfaceVariant.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                '${levelDb.toStringAsFixed(0)} dBFS',
                style: theme.textTheme.labelSmall,
              ),
              const Spacer(),
              Icon(
                Icons.filter_alt_outlined,
                size: 12,
                color: gateOn ? gold : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 2),
              Text(
                '${tr('sing.gate')} ${gateOn ? '${gateDb.round()} dB' : tr('sing.gateOff')}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: gateOn ? gold : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GateHandlePainter extends CustomPainter {
  _GateHandlePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final paint = Paint()..color = color;
    canvas.drawRect(Rect.fromLTWH(cx - 1, 3, 2, size.height - 6), paint);
    canvas.drawPath(
      Path()
        ..moveTo(cx - 5, 0)
        ..lineTo(cx + 5, 0)
        ..lineTo(cx, 5)
        ..close(),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 5, size.height)
        ..lineTo(cx + 5, size.height)
        ..lineTo(cx, size.height - 5)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GateHandlePainter old) => old.color != color;
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.big = false,
    this.color,
  });
  final String label;
  final String value;
  final bool big;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        Text(
          value,
          style:
              (big
                      ? theme.textTheme.headlineMedium
                      : theme.textTheme.titleMedium)
                  ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _CentsMeter extends StatelessWidget {
  const _CentsMeter({required this.cents, required this.color});
  final double? cents;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 14,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final x = cents == null
              ? w / 2
              : (w / 2 + (cents!.clamp(-100, 100) / 100) * (w / 2 - 4));
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Positioned(
                left: w / 2 - w / 4,
                width: w / 2,
                top: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xFF4CD964).withValues(alpha: 0.15),
                ),
              ),
              Positioned(
                left: w / 2 - 1,
                width: 2,
                top: 0,
                bottom: 0,
                child: Container(color: cs.onSurface.withValues(alpha: 0.4)),
              ),
              if (cents != null)
                Positioned(
                  left: x - 4,
                  width: 8,
                  top: 1,
                  bottom: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.session,
    required this.busy,
    required this.onStop,
    required this.editing,
    required this.onToggleEdit,
  });
  final bool editing;
  final VoidCallback onToggleEdit;
  final SingSession session;
  final bool busy;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final cs = Theme.of(context).colorScheme;
    final enabled = s.ready && !busy;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: s.position,
                  builder: (context, pos, _) => SizedBox(
                    width: 100,
                    child: Text(
                      '${formatDuration(pos)} / ${formatDuration(s.duration)}',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<double>(
                    valueListenable: s.position,
                    builder: (context, pos, _) => Slider(
                      value: s.duration > 0 ? pos.clamp(0, s.duration) : 0,
                      max: s.duration > 0 ? s.duration : 1,
                      onChanged: enabled && !s.recording
                          ? (v) => s.seek(v)
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: s.playing ? tr('sing.pause') : tr('sing.play'),
                  onPressed: enabled ? s.togglePlay : null,
                  icon: Icon(s.playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: tr('sing.restart'),
                  onPressed: enabled && !s.recording ? s.restart : null,
                  icon: const Icon(Icons.replay),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: tr('edit.tooltip'),
                  child: editing
                      ? FilledButton.icon(
                          onPressed: onToggleEdit,
                          icon: const Icon(Icons.edit_note),
                          label: Text(tr('edit.button')),
                        )
                      : OutlinedButton.icon(
                          onPressed: enabled && !s.recording
                              ? onToggleEdit
                              : null,
                          icon: const Icon(Icons.edit_note),
                          label: Text(tr('edit.button')),
                        ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<TrackKind>(
                  segments: [
                    ButtonSegment(
                      value: TrackKind.inst,
                      label: Text(tr('sing.inst')),
                      enabled: s.hasInst,
                    ),
                    ButtonSegment(
                      value: TrackKind.mix,
                      label: Text(tr('sing.original')),
                      enabled: s.hasMix,
                    ),
                  ],
                  selected: {s.track},
                  showSelectedIcon: false,
                  onSelectionChanged: enabled
                      ? (v) => s.setTrack(v.first)
                      : null,
                ),
                const SizedBox(width: 16),
                Text(tr('sing.pitchShift')),
                IconButton(
                  onPressed: enabled
                      ? () => s.setPitchShift(s.pitchShift - 1)
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                SizedBox(
                  width: 28,
                  child: Text(
                    '${s.pitchShift >= 0 ? '+' : ''}${s.pitchShift.toInt()}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  onPressed: enabled
                      ? () => s.setPitchShift(s.pitchShift + 1)
                      : null,
                  icon: const Icon(Icons.add),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.volume_up, size: 18),
                SizedBox(
                  width: 120,
                  child: Slider(
                    value: s.volume,
                    max: 1.5,
                    onChanged: enabled ? s.setVolume : null,
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: tr('sing.octaveAlign'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.swap_vert, size: 18),
                      Switch(value: s.octaveAlign, onChanged: s.setOctaveAlign),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '${tr('sing.window')}: ${s.windowSeconds.toInt()} s',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.zoom_in, size: 18),
                      SizedBox(
                        width: 100,
                        child: Slider(
                          value: s.windowSeconds,
                          min: 4,
                          max: 16,
                          divisions: 12,
                          onChanged: s.setWindowSeconds,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (s.recording)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fiber_manual_record,
                          color: cs.error,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(tr('sing.recording')),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  style: s.recording
                      ? FilledButton.styleFrom(
                          backgroundColor: cs.error,
                          foregroundColor: cs.onError,
                        )
                      : null,
                  onPressed: enabled
                      ? (s.recording ? onStop : s.startRecording)
                      : null,
                  icon: Icon(s.recording ? Icons.stop : Icons.mic),
                  label: Text(
                    s.recording ? tr('sing.stop') : tr('sing.record'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
