// Scrolling / static piano roll painter.
//
// Scrolling mode: a window of [windowSeconds] around a ValueListenable
// position with the playhead at [playheadFraction]; repaints are driven by the
// listenable (no widget rebuilds). Static mode: the whole [totalDuration],
// or a zoomed part of it ([viewStart], [viewSpan]).
// Only the visible window is painted (binary searches into the flat arrays).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../state/duet_parts.dart';
import '../../state/i18n.dart';
import '../../state/live_trace.dart';
import '../../state/song_data.dart';

class PianoRollColors {
  const PianoRollColors({
    required this.background,
    required this.rowAlt,
    required this.grid,
    required this.gridOctave,
    required this.label,
    required this.noteUpcoming,
    required this.noteCurrent,
    required this.notePast,
    required this.refCurve,
    required this.playhead,
    required this.good,
    required this.near,
    required this.off,
    required this.none,
    this.noteOutline,
  });

  final Color background, rowAlt, grid, gridOctave, label;
  final Color noteUpcoming, noteCurrent, notePast, refCurve, playhead;
  final Color good, near, off, none;

  /// Thin outline around note bars (used over video for contrast).
  final Color? noteOutline;

  static PianoRollColors of(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PianoRollColors(
      background: const Color(0xFF14161C),
      rowAlt: const Color(0xFF1A1D25),
      grid: const Color(0xFF262A35),
      gridOctave: const Color(0xFF3A4050),
      label: cs.onSurface.withValues(alpha: 0.6),
      noteUpcoming: cs.primary.withValues(alpha: 0.9),
      noteCurrent: cs.primary,
      notePast: cs.primary.withValues(alpha: 0.5),
      refCurve: Colors.white.withValues(alpha: 0.28),
      playhead: cs.tertiary,
      good: const Color(0xFF4CD964),
      near: const Color(0xFFFFCC00),
      off: const Color(0xFFFF3B30),
      none: const Color(0xFF9AA0AE),
    );
  }

  /// Translucent variant drawn over a video: the background works as a dim
  /// scrim, grid and labels stay readable, notes are more opaque.
  static PianoRollColors overlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PianoRollColors(
      background: const Color(0x8C0B0D12),
      rowAlt: const Color(0x26FFFFFF),
      grid: const Color(0x33FFFFFF),
      gridOctave: const Color(0x66FFFFFF),
      label: Colors.white.withValues(alpha: 0.8),
      noteUpcoming: cs.primary,
      noteCurrent: Color.lerp(cs.primary, Colors.white, 0.25)!,
      notePast: cs.primary.withValues(alpha: 0.65),
      refCurve: Colors.white.withValues(alpha: 0.45),
      playhead: cs.tertiary,
      good: const Color(0xFF4CD964),
      near: const Color(0xFFFFCC00),
      off: const Color(0xFFFF3B30),
      none: const Color(0xFFC4C8D0),
      noteOutline: Colors.black.withValues(alpha: 0.6),
    );
  }
}

class PianoRollPainter extends CustomPainter {
  PianoRollPainter({
    required this.notes,
    required this.refF0,
    required this.trace,
    required this.colors,
    required this.minMidi,
    required this.maxMidi,
    this.position,
    this.windowSeconds = 8,
    this.playheadFraction = 0.3,
    this.pitchShift = 0,
    this.totalDuration,
    this.viewStart = 0,
    this.viewSpan,
    this.gutter = 46,
    this.selectedNote,
    this.revision = 0,
    this.beatTimes = const [],
    this.beatAccents = const [],
    this.traceUntilPlayhead = false,
    this.live = false,
    this.liveHoldSeconds = 0.45,
    this.keyboard = false,
    this.sungMidi,
    this.wandNotes = const {},
    this.fieldAura = false,
    this.selectedNotes = const {},
    this.ghost,
    this.ghostShift = 0,
    this.duetSpans = const [],
    this.duetMine,
  }) : super(repaint: Listenable.merge([position, sungMidi]));

  /// Duet: who sings when. The other part's stretches are dimmed and a
  /// coloured strip along the top names each stretch (you, partner, together)
  /// from where [duetMine] stands.
  final List<DuetSpan> duetSpans;
  final DuetPart? duetMine;

  /// Colours of the duet parts as seen by the singer.
  static const duetYou = Color(0xFFFFD60A), duetPartner = Color(0xFF6EC6FF), duetTogether = Color(0xFF3DDC97);

  static Color duetColor(DuetPart part, DuetPart mine) => part == DuetPart.both ? duetTogether : (part == mine ? duetYou : duetPartner);

  static String duetLabel(DuetPart part, DuetPart mine) => tr(part == DuetPart.both ? 'duet.together' : (part == mine ? 'duet.you' : 'duet.partner'));

  /// Shadow battle: the opponent's sung line, drawn in [ghostColor] under the
  /// singer's own and moved by [ghostShift] semitones (the singer's key minus
  /// theirs). On a scrolling roll it runs only up to the playhead, as if
  /// they were singing along.
  final LiveTrace? ghost;
  final double ghostShift;

  static const ghostColor = Color(0xFFC9A7FF);

  /// More notes framed like [selectedNote] (picked for the Tuning Wand).
  final Set<int> selectedNotes;

  /// The Resonance Field is on: each note has a wide soft halo, the room the
  /// lenient judging gives.
  final bool fieldAura;

  /// Notes fixed with the Tuning Wand: they glow, and in a replay a burst of
  /// sparkles marks the moment the playhead reaches one, the tuned pitch
  /// drawn along it as it plays.
  final Set<int> wandNotes;

  final NoteList notes;
  final F0Curve refF0;
  final LiveTrace? trace;
  final PianoRollColors colors;
  final double minMidi, maxMidi;
  final ValueListenable<double>? position;
  final double windowSeconds;
  final double playheadFraction;

  /// Note drawn with a selection highlight (note editing).
  final int? selectedNote;

  /// Bumped when data changed in place (e.g. the masked reference curve).
  final int revision;

  /// Beat grid (sorted seconds) and bar-start flags; replaces the 1 s grid
  /// on the live roll when present.
  final List<double> beatTimes;
  final List<bool> beatAccents;

  /// Replay: draw the sung line only up to the playhead, as it was sung.
  final bool traceUntilPlayhead;

  /// Live singing. The sung line stays at its true time, so it is written a
  /// little behind the playhead (audio latency plus one analysis window, as
  /// a DAW draws a recording's waveform behind its line). To keep the
  /// feedback immediate, the newest pitch also sits on the playhead as a
  /// marker, a dashed lead joins it to the end of the line, and the parts of
  /// each note that were sung in tune light up.
  final bool live;

  /// The playhead marker shows the newest pitch while it is at most this
  /// many seconds old (the latency, plus slack for the analysis window).
  final double liveHoldSeconds;
  final double pitchShift;

  /// Draws a piano keyboard in the pitch gutter instead of note names: the
  /// key the score asks for at the playhead lights blue, the key being sung
  /// ([sungMidi], NaN when silent) orange.
  final bool keyboard;
  final ValueListenable<double>? sungMidi;

  static const keyRef = Color(0xFF3D8BFF), keySung = Color(0xFFFF9F0A);

  /// When set, the painter is static and shows 0..totalDuration.
  final double? totalDuration;

  /// Static view zoomed in: [viewSpan] seconds from [viewStart] (null: the
  /// whole [totalDuration]).
  final double viewStart;
  final double? viewSpan;
  final double gutter;

  static final Map<String, TextPainter> _labelCache = {};

  TextPainter _label(String text, Color color, double fontSize) {
    final key = '$text|${color.toARGB32()}|$fontSize';
    return _labelCache.putIfAbsent(key, () {
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize, fontFeatures: const [ui.FontFeature.tabularFigures()])),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final plotW = w - gutter;
    final rows = (maxMidi - minMidi) + 1;
    final rowH = h / rows;
    final bool isStatic = totalDuration != null;
    final double t0, t1;
    if (isStatic) {
      t0 = viewStart;
      t1 = t0 + (viewSpan ?? math.max(totalDuration!, 1));
    } else {
      final pos = position?.value ?? 0;
      t0 = pos - windowSeconds * playheadFraction;
      t1 = t0 + windowSeconds;
    }
    final span = t1 - t0;
    double x(double t) => gutter + (t - t0) / span * plotW;
    double y(double midi) => h - ((midi - minMidi + 0.5) / rows) * h;

    // Background + rows.
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
    final altPaint = Paint()..color = colors.rowAlt;
    final gridPaint = Paint()
      ..color = colors.grid
      ..strokeWidth = 1;
    final octPaint = Paint()
      ..color = colors.gridOctave
      ..strokeWidth = 1;
    final labelEvery = rowH >= 11 ? 1 : (rowH >= 6 ? 12 : 12);
    for (var m = minMidi.floor(); m <= maxMidi.ceil(); m++) {
      final yy = y(m.toDouble());
      final pc = ((m % 12) + 12) % 12;
      const black = {1, 3, 6, 8, 10};
      if (black.contains(pc)) {
        canvas.drawRect(Rect.fromLTWH(gutter, yy - rowH / 2, plotW, rowH), altPaint);
      }
      canvas.drawLine(Offset(gutter, yy + rowH / 2), Offset(w, yy + rowH / 2), pc == 11 ? octPaint : gridPaint);
      if (!keyboard && (labelEvery == 1 || pc == 0)) {
        final tp = _label(noteName(m.toDouble()), pc == 0 ? colors.label.withValues(alpha: 0.95) : colors.label, rowH >= 14 ? 11 : 9);
        tp.paint(canvas, Offset(gutter - tp.width - 4, yy - tp.height / 2));
      }
    }

    if (keyboard) _paintKeyboard(canvas, h, rowH, y, isStatic ? double.nan : (position?.value ?? 0));

    // Time grid: beat / bar lines when a beat grid is known (live roll),
    // else 1 s lines with labels.
    final secPaint = Paint()
      ..color = colors.grid
      ..strokeWidth = 1;
    final useBeats = !isStatic && beatTimes.isNotEmpty;
    if (useBeats) {
      final barPaint = Paint()
        ..color = colors.gridOctave
        ..strokeWidth = 2;
      var lo = 0, hi = beatTimes.length;
      while (lo < hi) {
        final m = (lo + hi) >> 1;
        if (beatTimes[m] < t0) {
          lo = m + 1;
        } else {
          hi = m;
        }
      }
      for (var i = lo; i < beatTimes.length && beatTimes[i] <= t1; i++) {
        final xx = x(beatTimes[i]);
        if (xx < gutter) continue;
        final bar = i < beatAccents.length && beatAccents[i];
        canvas.drawLine(Offset(xx, 0), Offset(xx, h), bar ? barPaint : secPaint);
      }
    }
    final step = isStatic ? _niceStep(span, plotW) : 1.0;
    final firstSec = (t0 / step).floor() * step;
    for (var t = firstSec; !useBeats && t <= t1; t += step) {
      if (t < 0) continue;
      final xx = x(t);
      if (xx < gutter) continue;
      canvas.drawLine(Offset(xx, 0), Offset(xx, h), secPaint);
      if (plotW / (span / step) >= 36) {
        final tp = _label(_fmt(t), colors.label, 9);
        tp.paint(canvas, Offset(xx + 2, h - tp.height - 2));
      }
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(gutter, 0, plotW, h));

    // Reference notes.
    final pos = isStatic ? double.nan : (position?.value ?? 0);
    final noteH = math.max(3.0, rowH * 0.78);
    final radius = Radius.circular(math.min(4, noteH / 2));
    final upcoming = Paint()..color = colors.noteUpcoming;
    final current = Paint()..color = colors.noteCurrent;
    final past = Paint()..color = colors.notePast;
    final staticNote = Paint()..color = colors.noteUpcoming;
    final outline = colors.noteOutline == null
        ? null
        : (Paint()
            ..color = colors.noteOutline!
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    if (fieldAura) {
      // Twice the room: a semitone each way and the widened timing.
      final halo = Paint()
        ..color = _fieldCyan.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      final edge = Paint()
        ..color = _fieldCyan.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final padX = plotW / span * 0.1;
      for (var i = notes.firstVisible(t0); i < notes.length; i++) {
        final on = notes.onset[i];
        if (on > t1) break;
        final off = notes.offset[i];
        if (off < t0) continue;
        final yy = y(notes.pitch[i] + pitchShift);
        final r = RRect.fromRectAndRadius(Rect.fromLTRB(x(on) - padX, yy - rowH, math.max(x(off), x(on) + 2) + padX, yy + rowH), Radius.circular(rowH));
        canvas.drawRRect(r, halo);
        canvas.drawRRect(r, edge);
      }
    }
    for (var i = notes.firstVisible(t0); i < notes.length; i++) {
      final on = notes.onset[i];
      if (on > t1) break;
      final off = notes.offset[i];
      if (off < t0) continue;
      final yy = y(notes.pitch[i] + pitchShift);
      final rect = RRect.fromRectAndRadius(Rect.fromLTRB(x(on), yy - noteH / 2, math.max(x(off), x(on) + 2), yy + noteH / 2), radius);
      final Paint paint;
      if (isStatic) {
        paint = staticNote;
      } else if (pos >= on && pos < off) {
        paint = current;
      } else if (off <= pos) {
        paint = past;
      } else {
        paint = upcoming;
      }
      canvas.drawRRect(rect, paint);
      if (live && on < pos) _paintHits(canvas, rect, on, off, x);
      if (outline != null) canvas.drawRRect(rect, outline);
      if (i == selectedNote || selectedNotes.contains(i)) {
        // Yellow for the note being edited; purple for notes picked for the
        // wand (gold is the tuned notes' own colour).
        final c = i == selectedNote ? const Color(0xFFFFD60A) : const Color(0xFFC79BFF);
        canvas.drawRRect(
          rect.inflate(3),
          Paint()
            ..color = c.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawRRect(
          rect.inflate(1.5),
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }

    // Reference F0 (faint).
    if (!refF0.isEmpty) {
      final i0 = refF0.lowerBound(t0), i1 = refF0.lowerBound(t1);
      final stride = math.max(1, ((i1 - i0) / (plotW * 2)).floor());
      final path = Path();
      var open = false;
      var lastT = double.nan;
      for (var i = i0; i < i1; i += stride) {
        final m = refF0.midi[i];
        final t = refF0.times[i];
        if (m.isNaN || (open && t - lastT > 0.06 * stride + 0.02)) {
          open = false;
          if (m.isNaN) {
            lastT = t;
            continue;
          }
        }
        final px = x(t), py = y(m + pitchShift);
        if (!open) {
          path.moveTo(px, py);
          open = true;
        } else {
          path.lineTo(px, py);
        }
        lastT = t;
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = colors.refCurve
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round);
    }

    final gh = ghost;
    if (duetMine != null && duetSpans.isNotEmpty) _paintDuet(canvas, t0, t1, w, h, x);
    if (gh != null && !gh.isEmpty) _paintGhost(canvas, gh, t0, isStatic ? t1 : math.min(t1, pos), plotW, rowH, isStatic, x, y);

    // Live / take trace, one path per colour category.
    final tr = trace;
    if (tr != null && !tr.isEmpty) {
      final paths = List.generate(4, (_) => Path());
      final i0 = tr.lowerBound(t0), i1 = tr.lowerBound(traceUntilPlayhead && !isStatic ? math.min(t1, pos) : t1);
      final stride = math.max(1, ((i1 - i0) / (plotW * 2)).floor());
      var lastT = double.nan;
      var lastCat = -1;
      var lastX = 0.0, lastY = 0.0;
      for (var i = i0; i < i1; i += stride) {
        final t = tr.timeAt(i);
        final cat = tr.categoryAt(i);
        final px = x(t), py = y(tr.displayAt(i));
        final gap = t - lastT > 0.08 * stride + 0.02;
        if (lastCat < 0 || gap || (py - lastY).abs() > rowH * 7) {
          paths[cat].moveTo(px, py);
        } else if (cat == lastCat) {
          paths[cat].lineTo(px, py);
        } else {
          paths[cat].moveTo(lastX, lastY);
          paths[cat].lineTo(px, py);
        }
        lastT = t;
        lastCat = cat;
        lastX = px;
        lastY = py;
      }
      final catColors = [colors.none, colors.good, colors.near, colors.off];
      for (var c = 0; c < 4; c++) {
        canvas.drawPath(
            paths[c],
            Paint()
              ..color = catColors[c]
              ..style = PaintingStyle.stroke
              ..strokeWidth = isStatic ? 2 : 3.5
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round);
      }
    }

    if (wandNotes.isNotEmpty) _paintWand(canvas, t0, t1, pos, isStatic, x, y, noteH);

    // Playhead.
    if (!isStatic) {
      final px = x(pos);
      canvas.drawLine(
          Offset(px, 0),
          Offset(px, h),
          Paint()
            ..color = colors.playhead
            ..strokeWidth = 2);
      if (live) _paintLiveCursor(canvas, pos, x, y, noteH);
    }
    canvas.restore();
  }

  void _paintDuet(Canvas canvas, double t0, double t1, double w, double h, double Function(double) x) {
    final mine = duetMine!;
    final dim = Paint()..color = colors.background.withValues(alpha: 0.6);
    for (final s in duetSpans) {
      if (s.end < t0) continue;
      if (s.start > t1) break;
      final l = math.max(gutter, x(s.start)), r = math.min(w, x(s.end));
      if (r <= l) continue;
      // The other part's lines: rest (their notes dimmed).
      if (s.part != mine && s.part != DuetPart.both) canvas.drawRect(Rect.fromLTRB(l, 0, r, h), dim);
      final c = duetColor(s.part, mine);
      canvas.drawRect(Rect.fromLTRB(l, 0, r, 4), Paint()..color = c);
      if (r - l > 34) {
        final tp = _label(duetLabel(s.part, mine), c, 11);
        tp.paint(canvas, Offset(math.min(math.max(l + 4, gutter + 4), r - tp.width - 2), 6));
      }
    }
  }

  void _paintGhost(Canvas canvas, LiveTrace gh, double from, double to, double plotW, double rowH, bool isStatic, double Function(double) x, double Function(double) y) {
    if (to <= from) return;
    final path = Path();
    final i0 = gh.lowerBound(from), i1 = gh.lowerBound(to);
    final stride = math.max(1, ((i1 - i0) / (plotW * 2)).floor());
    var lastT = double.nan, lastY = 0.0;
    var started = false;
    for (var i = i0; i < i1; i += stride) {
      final t = gh.timeAt(i);
      final px = x(t), py = y(gh.displayAt(i) + ghostShift);
      final gap = t - lastT > 0.08 * stride + 0.02;
      if (!started || gap || (py - lastY).abs() > rowH * 7) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
      started = true;
      lastT = t;
      lastY = py;
    }
    canvas.drawPath(
        path,
        Paint()
          // A wide soft band: where both sing the same pitch it still shows
          // around the singer's own (thinner) line drawn over it.
          ..color = ghostColor.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isStatic ? 4 : 8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    // On the live roll, a dot where they are now.
    if (!isStatic && i1 > 0 && to - gh.timeAt(i1 - 1) < 0.15) {
      final c = Offset(x(gh.timeAt(i1 - 1)), y(gh.displayAt(i1 - 1) + ghostShift));
      canvas.drawCircle(c, 6, Paint()..color = ghostColor.withValues(alpha: 0.3));
      canvas.drawCircle(c, 3.5, Paint()..color = ghostColor);
    }
  }

  /// Lights up the stretches of a note (its [rect], from [on] to [off]) where
  /// the sung pitch was in tune, at the time it was sung.
  void _paintHits(Canvas canvas, RRect rect, double on, double off, double Function(double) x) {
    final tr = trace;
    if (tr == null || tr.isEmpty) return;
    final fill = Paint()..color = colors.good.withValues(alpha: 0.55);
    canvas.save();
    canvas.clipRRect(rect);
    double? start;
    var last = double.nan;
    void close() {
      if (start != null) canvas.drawRect(Rect.fromLTRB(x(start!), rect.top, x(math.min(last + _hitFrame, off)), rect.bottom), fill);
      start = null;
    }

    for (var j = tr.lowerBound(on); j < tr.length; j++) {
      final t = tr.timeAt(j);
      if (t >= off) break;
      if (start != null && t - last > _hitGap) close();
      if (tr.categoryAt(j) == PitchCategory.good) {
        start ??= t;
        last = t;
      } else {
        close();
      }
    }
    close();
    canvas.restore();
  }

  /// The keyboard in the gutter: one row per semitone like a DAW's piano
  /// roll (black keys 62 % of the width), C keys named, the score's key at
  /// the playhead and the sung key lit.
  void _paintKeyboard(Canvas canvas, double h, double rowH, double Function(double) y, double pos) {
    const black = {1, 3, 6, 8, 10};
    final g = gutter - 2;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, g, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, g, h), Paint()..color = const Color(0xFFE9EBF0));
    final ref = pos.isNaN ? null : notes.pitchAt(pos);
    final refKey = ref == null || ref.isNaN ? null : (ref + pitchShift).round();
    var s = sungMidi?.value;
    // Replays: the take's own pitch at the playhead (the line drawn so far).
    final tr = trace;
    if (s == null && traceUntilPlayhead && tr != null && !tr.isEmpty && !pos.isNaN) {
      final k = tr.lowerBound(pos + 1e-6) - 1;
      if (k >= 0 && pos - tr.timeAt(k) <= 0.12) s = tr.displayAt(k);
    }
    final sungKey = s == null || s.isNaN ? null : s.round();
    final line = Paint()
      ..color = const Color(0xFF9AA0AE)
      ..strokeWidth = 0.7;
    final blackW = g * 0.62;
    final lo = minMidi.floor() - 2, hi = maxMidi.ceil() + 2;
    bool isBlack(int m) => black.contains(((m % 12) + 12) % 12);
    Color? litOf(int m) => m == sungKey ? keySung : (m == refKey ? keyRef : null);
    // White keys first, like a real keyboard: one semitone row each, plus half
    // of a black key's row on either side to the right of the black keys, so
    // the black keys sit across the line between two white keys.
    for (var m = lo; m <= hi; m++) {
      if (isBlack(m)) continue;
      final top = y(m.toDouble()) - rowH / 2, bottom = top + rowH;
      final up = isBlack(m + 1) ? rowH / 2 : 0.0, down = isBlack(m - 1) ? rowH / 2 : 0.0;
      final lit = litOf(m);
      if (lit != null) {
        canvas.drawRect(Rect.fromLTRB(0, top, g, bottom), Paint()..color = lit);
        canvas.drawRect(Rect.fromLTRB(blackW, top - up, g, bottom + down), Paint()..color = lit);
      }
      // The line below this key: across the black key below (in its middle),
      // or the full width where two white keys meet (B|C, E|F).
      if (down > 0) {
        canvas.drawLine(Offset(blackW, bottom + down), Offset(g, bottom + down), line);
      } else {
        canvas.drawLine(Offset(0, bottom), Offset(g, bottom), line);
      }
    }
    for (var m = lo; m <= hi; m++) {
      if (!isBlack(m)) continue;
      final top = y(m.toDouble()) - rowH / 2;
      canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTWH(0, top + 0.5, blackW, rowH - 1),
            topRight: const Radius.circular(2), bottomRight: const Radius.circular(2)),
        Paint()..color = litOf(m) ?? const Color(0xFF1C1E24),
      );
    }
    for (var m = lo; m <= hi; m++) {
      final yy = y(m.toDouble());
      final top = yy - rowH / 2;
      final lit = litOf(m);
      if (m == refKey && m == sungKey) {
        // On the score's key: a blue edge keeps both visible.
        canvas.drawRect(
            Rect.fromLTWH(1, top + 1, (isBlack(m) ? blackW : g) - 2, rowH - 2),
            Paint()
              ..color = keyRef
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
      if (m % 12 == 0 && rowH >= 6) {
        final tp = _label(noteName(m.toDouble()), lit != null ? Colors.white : const Color(0xFF3A3F4B), rowH >= 14 ? 10 : 8);
        tp.paint(canvas, Offset(g - tp.width - 3, yy - tp.height / 2));
      }
    }
    canvas.restore();
    canvas.drawLine(Offset(g + 1, 0), Offset(g + 1, h), Paint()..color = const Color(0xFF3A3F4B)..strokeWidth = 2);
  }

  /// A hit stretch is extended by one frame, and broken by a gap longer than
  /// [_hitGap] (an unvoiced stretch; unvoiced frames are not stored).
  static const _hitFrame = 0.02, _hitGap = 0.08;

  /// The newest sung pitch as a marker on the playhead, with a dashed lead
  /// from where the line has been written so far.
  void _paintLiveCursor(Canvas canvas, double pos, double Function(double) x, double Function(double) y, double noteH) {
    final tr = trace;
    if (tr == null || tr.isEmpty) return;
    final k = tr.length - 1;
    final lt = tr.timeAt(k);
    final age = pos - lt;
    if (age < -0.05 || age > liveHoldSeconds) return;
    final fade = (liveHoldSeconds - age) < 0.12 ? ((liveHoldSeconds - age) / 0.12).clamp(0.0, 1.0) : 1.0;
    final color = [colors.none, colors.good, colors.near, colors.off][tr.categoryAt(k)];
    final px = x(pos), py = y(tr.displayAt(k));
    final lx = x(lt);
    if (px - lx > 4) {
      final dash = Paint()
        ..color = color.withValues(alpha: 0.45 * fade)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      for (var d = lx + 3; d < px - 3; d += 9) {
        canvas.drawLine(Offset(d, py), Offset(math.min(d + 4, px - 3), py), dash);
      }
    }
    final r = math.max(5.0, math.min(9.0, noteH * 0.5));
    canvas.drawCircle(
        Offset(px, py),
        r * 1.9,
        Paint()
          ..color = color.withValues(alpha: 0.35 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(Offset(px, py), r, Paint()..color = color.withValues(alpha: fade));
    canvas.drawCircle(
        Offset(px, py),
        r,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.9 * fade)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  static const _wandPurple = Color(0xFFB57CFF), _wandGold = Color(0xFFFFD66B);
  static const _fieldCyan = Color(0xFF3FC8DE);

  void _paintWand(Canvas canvas, double t0, double t1, double pos, bool isStatic, double Function(double) x, double Function(double) y, double noteH) {
    for (final i in wandNotes) {
      if (i < 0 || i >= notes.length) continue;
      final on = notes.onset[i], off = notes.offset[i];
      if (off < t0 - 1 || on > t1) continue;
      final yy = y(notes.pitch[i] + pitchShift);
      final rect = RRect.fromRectAndRadius(Rect.fromLTRB(x(on), yy - noteH / 2, math.max(x(off), x(on) + 2), yy + noteH / 2), Radius.circular(math.min(4, noteH / 2)));
      final played = isStatic || pos >= on;
      final playing = !isStatic && pos >= on && pos < off;
      // The whole note turns gold: lit once played, brightest (and pulsing)
      // while it plays, so a tuned note stands out at a glance.
      final pulse = playing ? 0.5 + 0.5 * math.sin((pos - on) * 14) : 0.0;
      canvas.drawRRect(
        rect.inflate(playing ? 6 + 2 * pulse : 4),
        Paint()
          ..color = _wandGold.withValues(alpha: playing ? 0.75 : (played ? 0.55 : 0.3))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: played ? const [Color(0xFFFFF1B8), _wandGold, Color(0xFFF0A81E)] : const [Color(0xCCFFE9A0), Color(0xCCFFC94A)],
          ).createShader(rect.outerRect),
      );
      canvas.drawRRect(
        rect.inflate(1),
        Paint()
          ..shader = LinearGradient(colors: [_wandPurple, _wandGold, _wandPurple]).createShader(rect.outerRect)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      // The tuned pitch, drawn as the note plays.
      if (played) {
        final end = isStatic ? off : math.min(pos, off);
        if (end > on) {
          canvas.drawLine(
            Offset(x(on), yy),
            Offset(x(end), yy),
            Paint()
              // Dark on the gold, so the tuned line still reads.
              ..color = const Color(0xFF5B2DB8).withValues(alpha: 0.9)
              ..strokeWidth = isStatic ? 2 : 3
              ..strokeCap = StrokeCap.round,
          );
        }
      }
      if (isStatic) {
        _star(canvas, Offset(x(on), yy - noteH / 2 - 5), 4.5, _wandGold);
        continue;
      }
      // Sparkles riding the playhead through the note.
      if (pos >= on && pos < off) {
        final px = x(pos);
        for (var k = 0; k < 3; k++) {
          final ph = (pos * 3 + k / 3) % 1.0;
          _star(canvas, Offset(px - 6 - 14 * ph, yy + (k - 1) * noteH * 0.9 * (1 - ph)), 3.5 * (1 - ph) + 1, Color.lerp(_wandGold, Colors.white, ph)!.withValues(alpha: 1 - ph));
        }
      }
      // The burst when the playhead reaches the note.
      final age = pos - on;
      const burst = 0.9;
      if (age >= 0 && age < burst) {
        final u = age / burst;
        final e = Curves.easeOutCubic.transform(u);
        final c = Offset(x(on), yy);
        canvas.drawCircle(
          c,
          6 + 46 * e,
          Paint()
            ..color = _wandPurple.withValues(alpha: 0.8 * (1 - u))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * (1 - u) + 0.5,
        );
        canvas.drawCircle(c, 10 * (1 - u) + 2, Paint()..color = Colors.white.withValues(alpha: 0.9 * (1 - u)));
        for (var k = 0; k < 8; k++) {
          final a = k * math.pi / 4 + 0.3;
          final d = 8 + 38 * e;
          _star(canvas, c + Offset(math.cos(a), math.sin(a)) * d, 5 * (1 - u) + 1.5, (k.isEven ? _wandGold : Colors.white).withValues(alpha: 1 - u));
        }
      }
    }
  }

  /// A four-pointed sparkle.
  static void _star(Canvas canvas, Offset p, double s, Color color) {
    canvas.drawPath(
      Path()
        ..moveTo(p.dx, p.dy - s)
        ..quadraticBezierTo(p.dx, p.dy, p.dx + s, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + s)
        ..quadraticBezierTo(p.dx, p.dy, p.dx - s, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - s),
      Paint()..color = color,
    );
  }

  static double _niceStep(double span, double width) {
    for (final s in [1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0]) {
      if (width / (span / s) >= 40) return s;
    }
    return 120;
  }

  static String _fmt(double t) {
    final s = t.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(PianoRollPainter old) =>
      old.notes != notes ||
      !setEquals(old.wandNotes, wandNotes) ||
      !setEquals(old.selectedNotes, selectedNotes) ||
      old.fieldAura != fieldAura ||
      old.refF0 != refF0 ||
      old.trace != trace ||
      old.ghost != ghost ||
      old.ghostShift != ghostShift ||
      old.duetSpans != duetSpans ||
      old.duetMine != duetMine ||
      old.minMidi != minMidi ||
      old.maxMidi != maxMidi ||
      old.windowSeconds != windowSeconds ||
      old.pitchShift != pitchShift ||
      old.totalDuration != totalDuration ||
      old.viewStart != viewStart ||
      old.viewSpan != viewSpan ||
      old.position != position ||
      old.selectedNote != selectedNote ||
      old.revision != revision ||
      old.beatTimes != beatTimes ||
      old.live != live ||
      old.liveHoldSeconds != liveHoldSeconds ||
      old.keyboard != keyboard ||
      old.sungMidi != sungMidi ||
      old.colors != colors;
}

/// Computes the displayed pitch range: song range ± 3 semitones (shifted).
({double min, double max}) pitchRangeFor(NoteList notes, double pitchShift) {
  if (notes.isEmpty) return (min: 48 + pitchShift, max: 72 + pitchShift);
  var lo = (notes.minPitch + pitchShift).floorToDouble() - 3;
  var hi = (notes.maxPitch + pitchShift).ceilToDouble() + 3;
  if (hi - lo < 12) {
    final mid = (hi + lo) / 2;
    lo = (mid - 6).floorToDouble();
    hi = lo + 12;
  }
  return (min: lo, max: hi);
}

/// Visible pitch range when zoomed in to [span] semitones: centred on the
/// notes inside the time window [t0, t1] (all of them when they fit, else
/// their median), clamped inside the whole-song range [full]. Returns null
/// when no note is in the window (the caller keeps the previous centre).
double? zoomTargetCenter(NoteList notes, double pitchShift, double t0, double t1, double span) {
  final ps = <double>[];
  for (var i = 0; i < notes.length; i++) {
    if (notes.offset[i] < t0) continue;
    if (notes.onset[i] > t1) break;
    ps.add(notes.pitch[i] + pitchShift);
  }
  if (ps.isEmpty) return null;
  ps.sort();
  final lo = ps.first, hi = ps.last;
  if (hi - lo + 4 <= span) return (lo + hi) / 2;
  return ps[ps.length ~/ 2];
}

/// The pitch range that must stay on screen around the playhead: the notes
/// sounding in [t0, t1] (after [pitchShift]) and the recently sung pitches
/// [recent]. Null when there is nothing to show.
({double lo, double hi})? essentialPitchRange(NoteList notes, double pitchShift, double t0, double t1, Iterable<double> recent) {
  var lo = double.infinity, hi = double.negativeInfinity;
  for (var i = 0; i < notes.length; i++) {
    if (notes.offset[i] < t0) continue;
    if (notes.onset[i] > t1) break;
    final p = notes.pitch[i] + pitchShift;
    if (p < lo) lo = p;
    if (p > hi) hi = p;
  }
  for (final p in recent) {
    if (p.isNaN) continue;
    if (p < lo) lo = p;
    if (p > hi) hi = p;
  }
  return lo.isFinite ? (lo: lo, hi: hi) : null;
}

/// Span (semitones) and centre that keep [essential] fully visible with a
/// [margin] above and below: the preferred [span] when it fits, else just
/// wide enough, never wider than [fullSpan].
({double span, double center})? followTarget(({double lo, double hi})? essential, double span, double fullSpan, {double margin = 1.5}) {
  if (essential == null) return null;
  final need = essential.hi - essential.lo + 2 * margin;
  return (span: math.min(fullSpan, math.max(span, need)), center: (essential.lo + essential.hi) / 2);
}

/// Clamps a window of [span] semitones centred on [center] inside [full].
({double min, double max}) zoomedRange(({double min, double max}) full, double center, double span) {
  final fullSpan = full.max - full.min;
  if (span >= fullSpan) return full;
  var lo = center - span / 2;
  lo = lo.clamp(full.min, full.max - span);
  return (min: lo, max: lo + span);
}

/// The note under [point] in a live roll of [size] (same geometry as
/// [PianoRollPainter]), or null. A few pixels of slack make thin notes easy
/// to hit; when several match, the one whose centre is closest wins.
int? hitTestNote(
  NoteList notes,
  Size size,
  Offset point, {
  required double minMidi,
  required double maxMidi,
  required double position,
  required double windowSeconds,
  double pitchShift = 0,
  double playheadFraction = 0.3,
  double gutter = 46,
}) {
  final h = size.height, plotW = size.width - gutter;
  if (point.dx < gutter || plotW <= 0 || h <= 0) return null;
  final rows = (maxMidi - minMidi) + 1;
  final rowH = h / rows;
  final t0 = position - windowSeconds * playheadFraction;
  final t1 = t0 + windowSeconds;
  double x(double t) => gutter + (t - t0) / windowSeconds * plotW;
  double y(double midi) => h - ((midi - minMidi + 0.5) / rows) * h;
  final noteH = math.max(3.0, rowH * 0.78);
  int? best;
  var bestD = double.infinity;
  for (var i = notes.firstVisible(t0); i < notes.length; i++) {
    final on = notes.onset[i];
    if (on > t1) break;
    final off = notes.offset[i];
    if (off < t0) continue;
    final yy = y(notes.pitch[i] + pitchShift);
    final r = Rect.fromLTRB(x(on) - 2, yy - noteH / 2 - 4, math.max(x(off), x(on) + 2) + 2, yy + noteH / 2 + 4);
    if (!r.contains(point)) continue;
    final d = (point - r.center).distanceSquared;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/// Height of one semitone row in a roll of height [h].
double rollRowHeight(double h, double minMidi, double maxMidi) => h / ((maxMidi - minMidi) + 1);

/// Convenience widget: clips, isolates repaints, and sizes the painter.
class PianoRollView extends StatelessWidget {
  const PianoRollView({
    super.key,
    required this.notes,
    required this.refF0,
    required this.trace,
    required this.minMidi,
    required this.maxMidi,
    this.position,
    this.windowSeconds = 8,
    this.pitchShift = 0,
    this.totalDuration,
    this.overlay = false,
    this.selectedNote,
    this.revision = 0,
    this.beatTimes = const [],
    this.beatAccents = const [],
    this.traceUntilPlayhead = false,
    this.live = false,
    this.liveHoldSeconds = 0.45,
    this.keyboard = false,
    this.sungMidi,
    this.wandNotes = const {},
    this.fieldAura = false,
    this.onSelectNote,
    this.selectedNotes = const {},
    this.viewStart = 0,
    this.viewSpan,
    this.ghost,
    this.ghostShift = 0,
    this.duetSpans = const [],
    this.duetMine,
  });

  /// See [PianoRollPainter.duetSpans] and [PianoRollPainter.duetMine].
  final List<DuetSpan> duetSpans;
  final DuetPart? duetMine;

  /// See [PianoRollPainter.ghost] and [PianoRollPainter.ghostShift].
  final LiveTrace? ghost;
  final double ghostShift;

  /// See [PianoRollPainter.viewStart] and [PianoRollPainter.viewSpan].
  final double viewStart;
  final double? viewSpan;

  /// See [PianoRollPainter.selectedNotes].
  final Set<int> selectedNotes;

  /// A click picks the note under it (null: none there); the whole-song
  /// view (with [totalDuration]) only.
  final ValueChanged<int?>? onSelectNote;

  /// See [PianoRollPainter.wandNotes] and [PianoRollPainter.fieldAura].
  final Set<int> wandNotes;
  final bool fieldAura;

  /// See [PianoRollPainter.keyboard].
  final bool keyboard;
  final ValueListenable<double>? sungMidi;

  final NoteList notes;
  final F0Curve refF0;
  final LiveTrace? trace;
  final double minMidi, maxMidi;
  final ValueListenable<double>? position;
  final double windowSeconds;
  final double pitchShift;
  final double? totalDuration;

  /// Drawn over a video: translucent background (see [PianoRollColors.overlay]).
  final bool overlay;

  final int? selectedNote;
  final int revision;
  final List<double> beatTimes;
  final List<bool> beatAccents;
  final bool traceUntilPlayhead;

  /// See [PianoRollPainter.live] and [PianoRollPainter.liveHoldSeconds].
  final bool live;
  final double liveHoldSeconds;

  Widget _roll(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CustomPaint(
          painter: PianoRollPainter(
            notes: notes,
            refF0: refF0,
            trace: trace,
            colors: overlay ? PianoRollColors.overlay(context) : PianoRollColors.of(context),
            minMidi: minMidi,
            maxMidi: maxMidi,
            position: position,
            windowSeconds: windowSeconds,
            pitchShift: pitchShift,
            totalDuration: totalDuration,
            viewStart: viewStart,
            viewSpan: viewSpan,
            selectedNote: selectedNote,
            revision: revision,
            beatTimes: beatTimes,
            beatAccents: beatAccents,
            traceUntilPlayhead: traceUntilPlayhead,
            live: live,
            liveHoldSeconds: liveHoldSeconds,
            keyboard: keyboard,
            sungMidi: sungMidi,
            wandNotes: wandNotes,
            fieldAura: fieldAura,
            selectedNotes: selectedNotes,
            ghost: ghost,
            ghostShift: ghostShift,
            duetSpans: duetSpans,
            duetMine: duetMine,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roll = _roll(context);
    if (onSelectNote == null || totalDuration == null) return roll;
    return LayoutBuilder(
      builder: (context, c) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapUp: (d) => onSelectNote!(noteAt(d.localPosition, c.biggest)),
          child: roll,
        ),
      ),
    );
  }

  /// The note drawn at [p] in a roll of [size] (whole-song view), with a few
  /// pixels to spare around short notes; null when there is none.
  int? noteAt(Offset p, Size size) {
    const gutter = 46.0;
    final plotW = size.width - gutter;
    if (p.dx < gutter || plotW <= 0 || notes.isEmpty) return null;
    final span = viewSpan ?? math.max(totalDuration!, 1).toDouble();
    final rows = (maxMidi - minMidi) + 1;
    final rowH = size.height / rows;
    final t = viewStart + (p.dx - gutter) / plotW * span;
    final midi = minMidi - 0.5 + (size.height - p.dy) / rowH;
    final slack = 5 / plotW * span; // seconds
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < notes.length; i++) {
      final on = notes.onset[i], off = notes.offset[i];
      if (t < on - slack || t > off + slack) continue;
      final dy = (notes.pitch[i] + pitchShift - midi).abs();
      if (dy > 0.9) continue;
      final dt = t < on ? on - t : (t > off ? t - off : 0.0);
      final d = dy + dt / slack;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }
}
