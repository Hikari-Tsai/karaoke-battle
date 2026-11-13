// Piano keyboard on the sing screen's dashboard.
//
// The song's range is filled in on the keys (deeper where most of the
// singing is, lighter out to the lowest and highest note), with a bar above
// and the comfortable male and female ranges on top; it slides to a new key.
// The note the score asks for lights blue (the colour of the note bars) and
// the note being sung orange, with a caret at the exact pitch: while
// recording (folded to the score's octave, like the roll) and before it (in
// its real octave), when the microphone is already analysed. Before
// recording the keys the singer has held get an orange dot: their range,
// next to the song's. Below: which voice the key suits and "AI 移調".
import 'package:flutter/material.dart';

import '../../state/i18n.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../../state/voice_range.dart';

const refKeyColor = Color(0xFF3D8BFF);
const sungKeyColor = Color(0xFFFF9F0A);
const maleZoneColor = Color(0xFF5AC8FA);
const femaleZoneColor = Color(0xFFFF6FAE);

/// The dashboard section: keyboard plus, before recording, the verdict and
/// the AI key change.
class VoiceKeyboardSection extends StatelessWidget {
  const VoiceKeyboardSection({super.key, required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final range = s.songRange;
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: tr('keyboard.legend'),
              child: Row(children: [
                Text(tr('keyboard.title'), style: theme.textTheme.labelSmall),
                const SizedBox(width: 4),
                Icon(Icons.help_outline, size: 12, color: theme.colorScheme.onSurfaceVariant),
              ]),
            ),
            const SizedBox(height: 4),
            // The range slides to a new key instead of jumping.
            TweenAnimationBuilder<double>(
              tween: Tween(end: s.pitchShift),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, shift, _) => ListenableBuilder(
                listenable: Listenable.merge([s.position, s.hud, s.reachedKeys]),
                builder: (context, _) {
                  final ref = s.notes.pitchAt(s.position.value);
                  final hud = s.hud.value;
                  final sung = s.recording ? hud.midi : hud.rawMidi;
                  return VoiceKeyboard(
                    range: range,
                    shift: shift,
                    refMidi: ref.isNaN ? null : ref + s.pitchShift,
                    sungMidi: hud.voiced && sung.isFinite ? sung : null,
                    reached: s.recording ? const {} : s.reachedKeys.value,
                  );
                },
              ),
            ),
            const SizedBox(height: 2),
            _KeyStepper(session: s),
            if (!s.recording) _ReachedRange(session: s),
            if (!s.recording && !range.isEmpty) ...[
              const SizedBox(height: 2),
              _Verdicts(range: range, shift: s.pitchShift),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: _AutoTransposeButton(session: s)),
                const SizedBox(width: 6),
                // Back to the original key (lit only when the key is changed).
                Expanded(
                  child: Tooltip(
                    message: tr('keyboard.resetKeyTip'),
                    child: OutlinedButton.icon(
                      onPressed: s.ready && !s.recording && s.pitchShift != 0 ? () => s.setPitchShift(0) : null,
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: Text(tr('keyboard.resetKey'), maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    ),
                  ),
                ),
              ]),
            ],
          ],
        );
      },
    );
  }
}

/// "你唱到的音域": the singer's range found so far, with a reset.
class _ReachedRange extends StatelessWidget {
  const _ReachedRange({required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<Set<int>>(
      valueListenable: session.reachedKeys,
      builder: (context, keys, _) {
        final text = keys.isEmpty
            ? tr('keyboard.reachedNone')
            : tr('keyboard.reached', {
                'low': noteName(keys.reduce((a, b) => a < b ? a : b).toDouble()),
                'high': noteName(keys.reduce((a, b) => a > b ? a : b).toDouble()),
              });
        return Row(children: [
          const Icon(Icons.mic, size: 14, color: sungKeyColor),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
          if (keys.isNotEmpty)
            IconButton(
              tooltip: tr('keyboard.reachedClear'),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: session.clearReachedKeys,
              icon: const Icon(Icons.clear),
            ),
        ]);
      },
    );
  }
}

/// Key change one semitone at a time: the same as the -/+ under the stage
/// (locked while recording and while a take is being scored).
class _KeyStepper extends StatelessWidget {
  const _KeyStepper({required this.session});
  final SingSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return ValueListenableBuilder(
      valueListenable: s.processing,
      builder: (context, processing, _) {
        final enabled = s.canChangeKey && processing == null;
        final theme = Theme.of(context);
        final locked = s.recording ? tr('sing.keyLocked') : null;
        // Locked: lock, label and value in the grey of the disabled buttons.
        final grey = s.recording ? theme.colorScheme.onSurface.withValues(alpha: 0.38) : null;
        return Row(children: [
          if (s.recording) ...[
            Icon(Icons.lock, size: 12, color: grey),
            const SizedBox(width: 2),
          ],
          Text(tr('sing.pitchShift'), style: theme.textTheme.bodySmall?.copyWith(color: grey)),
          const Spacer(),
          IconButton(
            tooltip: locked ?? tr('keyboard.keyDown'),
            visualDensity: VisualDensity.compact,
            onPressed: enabled && s.pitchShift > -SongRange.maxShift ? () => s.setPitchShift(s.pitchShift - 1) : null,
            icon: const Icon(Icons.remove, size: 18),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '${s.pitchShift >= 0 ? '+' : ''}${s.pitchShift.toInt()}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(color: grey),
            ),
          ),
          IconButton(
            tooltip: locked ?? tr('keyboard.keyUp'),
            visualDensity: VisualDensity.compact,
            onPressed: enabled && s.pitchShift < SongRange.maxShift ? () => s.setPitchShift(s.pitchShift + 1) : null,
            icon: const Icon(Icons.add, size: 18),
          ),
        ]);
      },
    );
  }
}

class _Verdicts extends StatelessWidget {
  const _Verdicts({required this.range, required this.shift});
  final SongRange range;
  final double shift;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(VoiceZone z) {
      final v = range.verdict(z, shift);
      final who = tr(z.type == VoiceType.male ? 'keyboard.male' : 'keyboard.female');
      final text = switch (v.fit) {
        RangeFit.fits => tr('keyboard.fits', {'who': who}),
        RangeFit.high => tr('keyboard.high', {'who': who, 'n': '${v.bySemitones}'}),
        RangeFit.low => tr('keyboard.low', {'who': who, 'n': '${v.bySemitones}'}),
        RangeFit.wide => tr('keyboard.wide', {'who': who}),
      };
      final color = z.type == VoiceType.male ? maleZoneColor : femaleZoneColor;
      return Row(children: [
        Icon(z.type == VoiceType.male ? Icons.male : Icons.female, size: 16, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: v.fit == RangeFit.fits ? FontWeight.w700 : null,
              color: v.fit == RangeFit.fits ? null : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (v.fit == RangeFit.fits) Icon(Icons.check, size: 14, color: color),
      ]);
    }

    return Tooltip(
      message: tr('keyboard.rangeTip', {
        'low': noteName(range.low + shift),
        'high': noteName(range.high + shift),
        'lowest': noteName(range.lowest + shift),
        'highest': noteName(range.highest + shift),
      }),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        line(VoiceZone.male),
        line(VoiceZone.female),
      ]),
    );
  }
}

/// "AI 移調": a menu with the key change for each voice; picking one moves
/// the key (and the keyboard follows).
class _AutoTransposeButton extends StatelessWidget {
  const _AutoTransposeButton({required this.session});
  final SingSession session;

  static String _signed(int n) => n == 0 ? tr('keyboard.originalKey') : '${n > 0 ? '+' : ''}$n';

  @override
  Widget build(BuildContext context) {
    final s = session;
    final enabled = s.ready && !s.recording;
    return MenuAnchor(
      menuChildren: [
        for (final z in VoiceZone.all)
          Builder(builder: (context) {
            final best = s.songRange.bestShift(z);
            final who = tr(z.type == VoiceType.male ? 'keyboard.male' : 'keyboard.female');
            final current = best == s.pitchShift.round();
            return MenuItemButton(
              leadingIcon: Icon(z.type == VoiceType.male ? Icons.male : Icons.female,
                  color: z.type == VoiceType.male ? maleZoneColor : femaleZoneColor),
              trailingIcon: current ? const Icon(Icons.check, size: 16) : null,
              onPressed: () => s.autoTranspose(z.type),
              child: Text(tr('keyboard.autoFor', {'who': who, 'key': _signed(best)})),
            );
          }),
      ],
      builder: (context, controller, _) => Tooltip(
        message: tr('keyboard.autoTip'),
        child: FilledButton.tonalIcon(
          onPressed: enabled ? () => controller.isOpen ? controller.close() : controller.open() : null,
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: Text(tr('keyboard.auto'), maxLines: 1, overflow: TextOverflow.ellipsis),
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        ),
      ),
    );
  }
}

/// The keyboard itself (C2..C6).
class VoiceKeyboard extends StatelessWidget {
  const VoiceKeyboard({super.key, required this.range, required this.shift, this.refMidi, this.sungMidi, this.reached = const {}});
  final SongRange range;
  final double shift;
  final double? refMidi, sungMidi;

  /// Keys the singer has held (orange dots).
  final Set<int> reached;

  static const lowMidi = 36, highMidi = 84;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: double.infinity,
        height: 84,
        child: CustomPaint(
          painter: VoiceKeyboardPainter(
            range: range,
            shift: shift,
            refMidi: refMidi,
            sungMidi: sungMidi,
            reached: reached,
            textColor: Theme.of(context).colorScheme.onSurfaceVariant,
            rangeColor: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class VoiceKeyboardPainter extends CustomPainter {
  VoiceKeyboardPainter({
    required this.range,
    required this.shift,
    required this.refMidi,
    required this.sungMidi,
    this.reached = const {},
    required this.textColor,
    required this.rangeColor,
  });
  final SongRange range;
  final double shift;
  final double? refMidi, sungMidi;
  final Set<int> reached;
  final Color textColor, rangeColor;

  static const _lo = VoiceKeyboard.lowMidi, _hi = VoiceKeyboard.highMidi;
  static const _black = {1, 3, 6, 8, 10};

  static bool isBlack(int midi) => _black.contains(midi % 12);

  static int _whiteIndex(int midi) {
    var n = 0;
    for (var m = _lo; m < midi; m++) {
      if (!isBlack(m)) n++;
    }
    return n;
  }

  static int get whiteCount => _whiteIndex(_hi) + 1;

  /// Centre x of a key (black keys sit on the line between two whites).
  static double keyCenter(int midi, double width) {
    final w = width / whiteCount;
    final i = _whiteIndex(midi);
    return isBlack(midi) ? i * w : (i + 0.5) * w;
  }

  /// x of a fractional pitch, between neighbouring key centres; clamped.
  static double xOf(double midi, double width) {
    final m = midi.clamp(_lo.toDouble(), _hi.toDouble());
    final a = m.floor(), f = m - a;
    final xa = keyCenter(a, width);
    if (f == 0 || a >= _hi) return xa;
    return xa + (keyCenter(a + 1, width) - xa) * f;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w < 60) return;
    const zoneTop = 0.0, zoneH = 5.0, zoneGap = 2.0;
    const rangeTop = zoneTop + 2 * (zoneH + zoneGap) + 1, rangeH = 8.0;
    const keysTop = rangeTop + rangeH + 3, keysH = 40.0;
    final whiteW = w / whiteCount;
    final paint = Paint();

    // Comfortable ranges.
    void zone(VoiceZone z, double top, Color c) {
      final x0 = xOf(z.low, w) - whiteW / 2, x1 = xOf(z.high, w) + whiteW / 2;
      paint.color = c.withValues(alpha: 0.75);
      canvas.drawRRect(RRect.fromLTRBR(x0, top, x1, top + zoneH, const Radius.circular(2)), paint);
    }

    zone(VoiceZone.male, zoneTop, maleZoneColor);
    zone(VoiceZone.female, zoneTop + zoneH + zoneGap, femaleZoneColor);

    // The melody: extremes as a thin line, tessitura as a thick bar.
    if (!range.isEmpty) {
      final y = rangeTop + rangeH / 2;
      paint
        ..color = rangeColor.withValues(alpha: 0.55)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(xOf(range.lowest + shift, w), y), Offset(xOf(range.highest + shift, w), y), paint);
      paint.color = rangeColor;
      canvas.drawRRect(
        RRect.fromLTRBR(xOf(range.low + shift, w) - 2, rangeTop, xOf(range.high + shift, w) + 2, rangeTop + rangeH, const Radius.circular(4)),
        paint,
      );
    }

    final ref = refMidi?.round(), sung = sungMidi?.round();
    // The song's range filled in on the keys (after the key change).
    double inRange(int m) {
      if (range.isEmpty) return 0;
      final p = m - shift;
      if (p >= range.low - 0.5 && p <= range.high + 0.5) return 1;
      if (p >= range.lowest - 0.5 && p <= range.highest + 0.5) return 0.5;
      return 0;
    }

    Color? fillOf(int m) {
      if (m == sung) return sungKeyColor;
      if (m == ref) return refKeyColor;
      return null;
    }

    Color whiteOf(int m) {
      final r = inRange(m);
      const base = Color(0xFFF4F5F7);
      return r == 0 ? base : Color.lerp(base, rangeColor, r == 1 ? 0.8 : 0.35)!;
    }

    Color blackOf(int m) {
      final r = inRange(m);
      const base = Color(0xFF1C1E24);
      return r == 0 ? base : Color.lerp(base, rangeColor, r == 1 ? 0.7 : 0.35)!;
    }

    // White keys.
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFF3A3F4B);
    for (var m = _lo, i = 0; m <= _hi; m++) {
      if (isBlack(m)) continue;
      final r = Rect.fromLTWH(i * whiteW, keysTop, whiteW, keysH);
      paint.color = fillOf(m) ?? whiteOf(m);
      canvas.drawRect(r, paint);
      canvas.drawRect(r, border);
      i++;
    }
    // Black keys.
    final blackW = whiteW * 0.62, blackH = keysH * 0.6;
    for (var m = _lo; m <= _hi; m++) {
      if (!isBlack(m)) continue;
      final cx = keyCenter(m, w);
      paint.color = fillOf(m) ?? blackOf(m);
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(cx - blackW / 2, keysTop, cx + blackW / 2, keysTop + blackH,
            bottomLeft: const Radius.circular(1.5), bottomRight: const Radius.circular(1.5)),
        paint,
      );
    }
    // Keys the singer has held: an orange dot near the bottom of each.
    for (final m in reached) {
      if (m < _lo || m > _hi || m == sung) continue;
      final cx = keyCenter(m, w);
      final y = isBlack(m) ? keysTop + blackH - 5 : keysTop + keysH - 5;
      canvas.drawCircle(Offset(cx, y), 2.4, Paint()..color = sungKeyColor);
    }
    // When the singer is on the score's key, ring it so both stay visible.
    if (ref != null && ref == sung) {
      final cx = keyCenter(ref, w);
      final top = isBlack(ref) ? keysTop + blackH - 9 : keysTop + keysH - 10;
      canvas.drawCircle(
        Offset(cx, top),
        3.2,
        Paint()
          ..color = refKeyColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    // Exact sung pitch: a caret under the keys.
    final s = sungMidi;
    if (s != null) {
      final x = xOf(s, w);
      final y = keysTop + keysH + 1;
      final path = Path()
        ..moveTo(x, y)
        ..lineTo(x - 4, y + 6)
        ..lineTo(x + 4, y + 6)
        ..close();
      canvas.drawPath(path, Paint()..color = sungKeyColor);
    }

    // C labels.
    for (var m = _lo; m <= _hi; m += 12) {
      final tp = TextPainter(
        text: TextSpan(text: noteName(m.toDouble()), style: TextStyle(fontSize: 8, color: textColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = keyCenter(m, w) - tp.width / 2;
      tp.paint(canvas, Offset(x.clamp(0, w - tp.width), keysTop + keysH + 8));
    }
  }

  @override
  bool shouldRepaint(VoiceKeyboardPainter old) =>
      old.shift != shift || old.refMidi?.round() != refMidi?.round() || old.sungMidi != sungMidi || old.range != range ||
      old.reached != reached ||
      old.textColor != textColor || old.rangeColor != rangeColor;
}
