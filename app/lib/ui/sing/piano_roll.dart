// Scrolling / static piano roll painter.
//
// Scrolling mode: a window of [windowSeconds] around a ValueListenable
// position with the playhead at [playheadFraction]; repaints are driven by the
// listenable (no widget rebuilds). Static mode: the whole [totalDuration].
// Only the visible window is painted (binary searches into the flat arrays).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
    this.gutter = 46,
    this.selectedNote,
    this.revision = 0,
    this.beatTimes = const [],
    this.beatAccents = const [],
    this.traceUntilPlayhead = false,
  }) : super(repaint: position);

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
  final double pitchShift;
  /// When set, the painter is static and shows 0..totalDuration.
  final double? totalDuration;
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
      t0 = 0;
      t1 = math.max(totalDuration!, 1);
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
      if (labelEvery == 1 || pc == 0) {
        final tp = _label(noteName(m.toDouble()), pc == 0 ? colors.label.withValues(alpha: 0.95) : colors.label, rowH >= 14 ? 11 : 9);
        tp.paint(canvas, Offset(gutter - tp.width - 4, yy - tp.height / 2));
      }
    }

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
      if (outline != null) canvas.drawRRect(rect, outline);
      if (i == selectedNote) {
        canvas.drawRRect(
          rect.inflate(3),
          Paint()
            ..color = const Color(0xFFFFD60A).withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
        canvas.drawRRect(
          rect.inflate(1.5),
          Paint()
            ..color = const Color(0xFFFFD60A)
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

    // Playhead.
    if (!isStatic) {
      final px = x(pos);
      canvas.drawLine(
          Offset(px, 0),
          Offset(px, h),
          Paint()
            ..color = colors.playhead
            ..strokeWidth = 2);
    }
    canvas.restore();
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
      old.refF0 != refF0 ||
      old.trace != trace ||
      old.minMidi != minMidi ||
      old.maxMidi != maxMidi ||
      old.windowSeconds != windowSeconds ||
      old.pitchShift != pitchShift ||
      old.totalDuration != totalDuration ||
      old.position != position ||
      old.selectedNote != selectedNote ||
      old.revision != revision ||
      old.beatTimes != beatTimes ||
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
  });

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

  @override
  Widget build(BuildContext context) {
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
            selectedNote: selectedNote,
            revision: revision,
            beatTimes: beatTimes,
            beatAccents: beatAccents,
            traceUntilPlayhead: traceUntilPlayhead,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
