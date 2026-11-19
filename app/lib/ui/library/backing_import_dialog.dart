// "Import backing track": pick an official instrumental or karaoke track,
// align it with the song automatically, check it by ear and on the two
// envelopes, nudge it by hand, then use it in place of the separated
// accompaniment (BackingImport).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../services/backing_import.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/error_report.dart';

const _audioExtensions = ['mp3', 'wav', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'mp4', 'webm'];

/// Picks a file and runs the import dialog. True when a backing was applied.
Future<bool> importBackingTrack(BuildContext context, Song song) async {
  final picked = await FilePicker.pickFiles(dialogTitle: tr('backing.pickTitle'), type: FileType.custom, allowedExtensions: _audioExtensions);
  final path = picked.isEmpty ? null : picked.first.path;
  if (path == null || !context.mounted) return false;
  final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _BackingImportDialog(song: song, source: path));
  return ok ?? false;
}

/// Back to the separated accompaniment, after confirming.
Future<bool> revertBackingTrack(BuildContext context, Song song) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('backing.revertTitle')),
      content: Text(tr('backing.revertBody')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('backing.revert'))),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  await context.read<AppServices>().backingImport.revert(song);
  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('backing.reverted'))));
  return true;
}

class _BackingImportDialog extends StatefulWidget {
  const _BackingImportDialog({required this.song, required this.source});
  final Song song;
  final String source;

  @override
  State<_BackingImportDialog> createState() => _BackingImportDialogState();
}

class _BackingImportDialogState extends State<_BackingImportDialog> {
  late final BackingImport _import = context.read<AppServices>().backingImport;

  // Analysis.
  double _progress = 0;
  String _stage = 'decode';
  Object? _error;
  String? _wav;
  BackingAlignment? _result;
  BackingEnvelopes? _env;

  // The delay being edited (seconds) and the view: its centre (song time)
  // and how many seconds it spans.
  double _delay = 0;
  double _focus = 0;
  double _span = 8;

  // Preview.
  Player? _player;
  BackingPreview? _playing;
  bool _rendering = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final (wav, a) = await _import.analyze(widget.song, widget.source, onProgress: (x, stage) {
        if (mounted) {
          setState(() {
            _progress = x;
            _stage = stage;
          });
        }
      });
      final env = await _import.envelopes(widget.song, wav);
      if (!mounted) return;
      setState(() {
        _wav = wav;
        _result = a;
        _env = env;
        _delay = a.delay;
        _focus = _firstOnset(env.reference);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Where the music clearly starts in the reference (a good first view).
  static double _firstOnset(List<double> env) {
    for (var i = 0; i < env.length; i++) {
      if (env[i] > 0.55) return math.max(0, i / BackingEnvelopes.rate + 1.0);
    }
    return 4;
  }

  double get _songSeconds => (_env?.reference.length ?? 0) / BackingEnvelopes.rate;

  void _nudge(double seconds) => setState(() => _delay = double.parse((_delay + seconds).toStringAsFixed(5)));

  Future<void> _preview(BackingPreview mode) async {
    if (_playing == mode) return _stop();
    final wav = _wav, a = _result;
    if (wav == null || a == null || _rendering) return;
    setState(() => _rendering = true);
    try {
      final start = math.max(0.0, _focus - 2);
      final out = await _import.preview(widget.song, wav, _delay, start, mode, gain: a.gain.abs() > 0.05 ? a.gain : 1);
      final player = _player ??= Player();
      await player.open(Media(out));
      if (mounted) setState(() => _playing = mode);
      unawaited(player.stream.completed.firstWhere((c) => c).then((_) {
        if (mounted && _playing == mode) setState(() => _playing = null);
      }));
    } catch (e) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  Future<void> _stop() async {
    await _player?.stop();
    if (mounted) setState(() => _playing = null);
  }

  Future<void> _apply() async {
    final wav = _wav;
    if (wav == null) return;
    await _stop();
    setState(() => _applying = true);
    try {
      await _import.apply(widget.song, wav, _delay, sourceName: p.basename(widget.source), alignment: _result);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('backing.applied'))));
      Navigator.pop(context, true);
    } catch (e, st) {
      if (mounted) {
        setState(() => _applying = false);
        await showErrorDialog(context, e, stack: st, where: 'apply backing');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('backing.title')),
      content: SizedBox(
        width: 760,
        child: _error != null
            ? _ErrorBody(error: _error!)
            : _result == null
            ? _Progress(stage: _stage, fraction: _progress, file: p.basename(widget.source))
            : SingleChildScrollView(child: _body(theme)),
      ),
      actions: [
        TextButton(onPressed: _applying ? null : () => Navigator.pop(context, false), child: Text(tr('cancel'))),
        if (_result != null)
          FilledButton.icon(
            onPressed: _applying ? null : _apply,
            icon: _applying ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check),
            label: Text(tr('backing.apply')),
          ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    final a = _result!, env = _env!;
    final cs = theme.colorScheme;
    final (color, verdict) = switch (a.verdict) {
      'aligned' => (const Color(0xFF4CAF50), tr('backing.verdict.aligned')),
      'drift' => (const Color(0xFFFFB74D), tr('backing.verdict.drift')),
      _ => (const Color(0xFFEF5350), tr('backing.verdict.mismatch')),
    };
    final ms = (_delay * 1000).round();
    final warnings = [
      if (a.verdict == 'drift') tr('backing.warn.drift', {'ppm': a.driftPpm.abs().round()}),
      if (a.verdict == 'mismatch') tr('backing.warn.mismatch'),
      if (a.keyChanged) tr('backing.warn.key', {'n': a.keyShift > 0 ? '+${a.keyShift}' : '${a.keyShift}'}),
      if (a.bandWarning) tr('backing.warn.bands', {'ms': a.bandSpreadMs.toStringAsFixed(1)}),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(p.basename(widget.source), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(999), border: Border.all(color: color)),
            child: Text(verdict, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Text(tr('backing.confidence', {'p': (a.confidence * 100).round()})),
          const Spacer(),
          if ((_delay - a.delay).abs() > 1e-6)
            TextButton.icon(onPressed: () => setState(() => _delay = a.delay), icon: const Icon(Icons.restart_alt, size: 18), label: Text(tr('backing.resetAuto'))),
        ]),
        for (final w in warnings)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: cs.tertiary),
              const SizedBox(width: 6),
              Expanded(child: Text(w, style: theme.textTheme.bodySmall)),
            ]),
          ),
        const SizedBox(height: 14),
        // The two envelopes; drag the lower one to move the backing.
        _AlignView(env: env, delay: _delay, focus: _focus, span: _span, onDrag: (dt) => _nudge(dt)),
        Row(children: [
          Text(tr('backing.position'), style: theme.textTheme.bodySmall),
          Expanded(
            child: Slider(
              value: _focus.clamp(0, math.max(1, _songSeconds)),
              max: math.max(1, _songSeconds),
              onChanged: (v) => setState(() => _focus = v),
            ),
          ),
          SegmentedButton<double>(
            segments: [for (final s in const [8.0, 2.0, 0.5]) ButtonSegment(value: s, label: Text(s >= 1 ? '${s.toInt()} s' : '${(s * 1000).round()} ms'))],
            selected: {_span},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _span = v.first),
          ),
        ]),
        const SizedBox(height: 8),
        // The delay in numbers, with nudges.
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
          Text(
            ms == 0 ? tr('backing.offsetNone') : tr(ms > 0 ? 'backing.offsetPad' : 'backing.offsetCut', {'s': (ms.abs() / 1000).toStringAsFixed(3)}),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(width: 8),
          for (final step in const [-100, -10, -1, 1, 10, 100])
            OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: () => _nudge(step / 1000),
              child: Text('${step > 0 ? '+' : ''}$step ms'),
            ),
        ]),
        const SizedBox(height: 12),
        // Listen around the position.
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final mode in BackingPreview.values)
            FilledButton.tonalIcon(
              onPressed: _rendering && _playing != mode ? null : () => _preview(mode),
              icon: Icon(_playing == mode ? Icons.stop : Icons.play_arrow),
              label: Text(tr('backing.preview.${mode.name}')),
            ),
        ]),
        const SizedBox(height: 6),
        Text(tr('backing.previewHint'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.stage, required this.fraction, required this.file});
  final String stage;
  final double fraction;
  final String file;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(file, style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 12),
    Text(tr('backing.stage.$stage')),
    const SizedBox(height: 8),
    LinearProgressIndicator(value: fraction > 0 && fraction < 1 ? fraction : null),
  ]);
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(tr('backing.failed'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
    const SizedBox(height: 8),
    SelectableText('$error', style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 12),
    ReportBugButton(error: '$error', where: 'import backing'),
  ]);
}

/// The reference (upper lane) and the backing moved by the current delay
/// (lower lane) over [span] seconds around [focus]; dragging the lower lane
/// changes the delay.
class _AlignView extends StatelessWidget {
  const _AlignView({required this.env, required this.delay, required this.focus, required this.span, required this.onDrag});
  final BackingEnvelopes env;
  final double delay, focus, span;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx / w * span),
          child: Container(
            height: 150,
            decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
            child: CustomPaint(
              size: Size(w, 150),
              painter: _AlignPainter(
                env: env,
                delay: delay,
                focus: focus,
                span: span,
                refColor: cs.primary,
                backColor: const Color(0xFFFFB74D),
                grid: cs.onSurface.withValues(alpha: 0.12),
                text: cs.onSurfaceVariant,
                refLabel: tr('backing.laneReference'),
                backLabel: tr('backing.laneBacking'),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _AlignPainter extends CustomPainter {
  _AlignPainter({
    required this.env,
    required this.delay,
    required this.focus,
    required this.span,
    required this.refColor,
    required this.backColor,
    required this.grid,
    required this.text,
    required this.refLabel,
    required this.backLabel,
  });
  final BackingEnvelopes env;
  final double delay, focus, span;
  final Color refColor, backColor, grid, text;
  final String refLabel, backLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final lane = size.height / 2;
    final t0 = focus - span / 2;
    // Seconds grid.
    final step = span > 4 ? 1.0 : (span > 1 ? 0.25 : 0.05);
    final g = Paint()..color = grid;
    for (var t = (t0 / step).ceil() * step; t < t0 + span; t += step) {
      final x = (t - t0) / span * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), g);
    }
    canvas.drawLine(Offset(0, lane), Offset(size.width, lane), g);
    _lane(canvas, size, env.reference, 0, t0, 0, refColor);
    // Backing time = song time - delay.
    _lane(canvas, size, env.backing, lane, t0, delay, backColor);
    final centre = Paint()
      ..color = text.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(size.width / 2, 0), Offset(size.width / 2, size.height), centre);
    _label(canvas, refLabel, const Offset(6, 4));
    _label(canvas, backLabel, Offset(6, lane + 4));
  }

  void _lane(Canvas canvas, Size size, List<double> e, double top, double t0, double shift, Color color) {
    final h = size.height / 2 - 6;
    final path = Path()..moveTo(0, top + h + 3);
    final n = size.width.toInt();
    for (var i = 0; i <= n; i++) {
      final t = t0 + i / size.width * span - shift;
      final k = (t * BackingEnvelopes.rate).floor();
      final v = k >= 0 && k < e.length ? e[k] : 0.0;
      path.lineTo(i.toDouble(), top + 3 + h * (1 - v));
    }
    path
      ..lineTo(size.width, top + h + 3)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.55));
  }

  void _label(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(color: text, fontSize: 11)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_AlignPainter old) => old.delay != delay || old.focus != focus || old.span != span || old.env != env;
}
