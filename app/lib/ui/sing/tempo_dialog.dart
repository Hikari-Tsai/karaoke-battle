// Tempo settings for one song: detected BPM / meter, manual BPM, beats per
// bar, the first downbeat (the song may start after silence or an intro),
// tap tempo (T or the button, while the track plays) and the metronome.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../state/beat_grid.dart';
import '../../state/i18n.dart';
import '../../state/sing_session.dart';

/// Returns the new override, or null when cancelled.
Future<TempoOverride?> showTempoDialog(
  BuildContext context, {
  required SingSession session,
  required DetectedBeats? detected,
  required TempoOverride current,
}) {
  return showDialog<TempoOverride>(
    context: context,
    builder: (_) => _TempoDialog(session: session, detected: detected, current: current),
  );
}

class _TempoDialog extends StatefulWidget {
  const _TempoDialog({required this.session, required this.detected, required this.current});
  final SingSession session;
  final DetectedBeats? detected;
  final TempoOverride current;

  @override
  State<_TempoDialog> createState() => _TempoDialogState();
}

class _TempoDialogState extends State<_TempoDialog> {
  late final TextEditingController _bpm;
  late double _first;
  late int _perBar;
  final List<double> _taps = [];
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  final _focus = FocusNode();

  DetectedBeats? get d => widget.detected;

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    final bpm = c.bpm ?? d?.bpm;
    _bpm = TextEditingController(text: bpm == null ? '' : _fmtBpm(bpm));
    _first = c.firstBeat ?? d?.firstDownbeat ?? 0;
    _perBar = c.beatsPerBar ?? d?.signature ?? 4;
  }

  @override
  void dispose() {
    _bpm.dispose();
    _focus.dispose();
    super.dispose();
  }

  static String _fmtBpm(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  double? get _bpmValue {
    final v = double.tryParse(_bpm.text.trim());
    return v != null && v >= 20 && v <= 400 ? v : null;
  }

  void _tap() {
    final now = DateTime.now();
    // A pause of more than 2 s starts a new tap sequence.
    if (now.difference(_lastTap).inMilliseconds > 2000) _taps.clear();
    _lastTap = now;
    _taps.add(widget.session.position.value);
    final r = BeatGrid.fromTaps(_taps);
    setState(() {
      if (r != null && _taps.length >= 4) {
        _bpm.text = _fmtBpm(r.bpm);
        _first = r.firstBeat;
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyT && !_bpmFieldFocused) {
      _tap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _bpmFieldFocused = false;

  TempoOverride _result() {
    final detectedBpm = d?.bpm;
    final bpm = _bpmValue;
    // Keep only what differs from the detection, so detection improvements
    // still apply to the rest.
    final manualBpm = bpm != null && (detectedBpm == null || (bpm - detectedBpm).abs() > 0.005) ? bpm : null;
    final detFirst = d?.firstDownbeat;
    final manualFirst = detFirst == null || (_first - detFirst).abs() > 0.0005 || manualBpm != null ? _first : null;
    final manualBar = _perBar != (d?.signature ?? 4) ? _perBar : null;
    return TempoOverride(bpm: manualBpm, firstBeat: manualFirst, beatsPerBar: manualBar);
  }

  String _modeLabel(String mode) => switch (mode) {
        'constant' => tr('tempo.modeConstant'),
        'variable' => tr('tempo.modeVariable'),
        'average' => tr('tempo.modeAverage'),
        _ => tr('tempo.modeNone'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<AppSettings>();
    final det = d;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text(tr('tempo.title')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Detection summary
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  det == null || det.beats.isEmpty
                      ? tr('tempo.noDetection')
                      : tr('tempo.detected', {
                          'bpm': det.bpm == null ? '—' : _fmtBpm(det.bpm!),
                          'bar': det.signature == null ? '?' : '${det.signature}',
                          'mode': _modeLabel(det.mode),
                          'first': (det.firstDownbeat ?? 0).toStringAsFixed(2),
                        }),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 14),
              Row(children: [
                SizedBox(
                  width: 120,
                  child: Focus(
                    onFocusChange: (f) => _bpmFieldFocused = f,
                    child: TextField(
                      controller: _bpm,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(labelText: 'BPM', border: OutlineInputBorder(), isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Text(tr('tempo.beatsPerBar')),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _perBar.clamp(1, 12),
                  items: [for (var n = 2; n <= 7; n++) DropdownMenuItem(value: n, child: Text('$n'))],
                  onChanged: (v) => setState(() => _perBar = v ?? _perBar),
                ),
              ]),
              const SizedBox(height: 14),
              Text(tr('tempo.firstBeat'), style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Row(children: [
                IconButton(tooltip: '-10 ms', onPressed: () => setState(() => _first = (_first - 0.01).clamp(0.0, 1e9)), icon: const Icon(Icons.remove)),
                SizedBox(width: 90, child: Text('${_first.toStringAsFixed(2)} s', textAlign: TextAlign.center, style: theme.textTheme.titleMedium)),
                IconButton(tooltip: '+10 ms', onPressed: () => setState(() => _first += 0.01), icon: const Icon(Icons.add)),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => setState(() => _first = widget.session.position.value),
                  icon: const Icon(Icons.my_location, size: 18),
                  label: Text(tr('tempo.setHere')),
                ),
              ]),
              Text(tr('tempo.firstBeatHint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 14),
              Row(children: [
                FilledButton.tonalIcon(onPressed: _tap, icon: const Icon(Icons.touch_app), label: Text(tr('tempo.tap'))),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _taps.isEmpty ? tr('tempo.tapHint') : tr('tempo.tapCount', {'n': _taps.length}),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ]),
              const Divider(height: 28),
              Row(children: [
                Icon(Icons.av_timer, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(tr('tempo.metronome')),
                const Spacer(),
                Switch(
                  value: settings.metronomeOn,
                  onChanged: (v) {
                    settings.setMetronomeOn(v);
                    widget.session.applyMetronome();
                  },
                ),
              ]),
              Row(children: [
                const Icon(Icons.volume_down, size: 18),
                Expanded(
                  child: Slider(
                    value: settings.metronomeGain,
                    max: 1.5,
                    onChanged: (v) {
                      settings.setMetronomeGain(v);
                      widget.session.applyMetronome();
                    },
                  ),
                ),
                const Icon(Icons.volume_up, size: 18),
              ]),
              Text(tr('tempo.metronomeHint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, const TempoOverride()), child: Text(tr('tempo.reset'))),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: _bpm.text.trim().isEmpty || _bpmValue != null ? () => Navigator.pop(context, _result()) : null,
            child: Text(tr('tempo.apply')),
          ),
        ],
      ),
    );
  }
}
