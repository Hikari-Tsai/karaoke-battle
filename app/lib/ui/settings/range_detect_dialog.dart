// "偵測你的音域": listens to the microphone (pitch only, nothing recorded) and
// fills in the keys the singer holds, on the same keyboard as the sing
// screen's dashboard. Saving replaces the range shared by every song. Opened
// from Settings, and once on first use right after the latency check (before
// the sing screen opens its own audio device).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/range_finder.dart';
import '../../state/song_data.dart';
import '../../state/voice_range.dart';
import '../sing/voice_keyboard.dart';

Future<void> showRangeDetectDialog(BuildContext context) =>
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const RangeDetectDialog());

/// First use: no range yet and not dismissed. Returns when the user saved,
/// skipped or chose not to be asked again.
Future<void> showRangePromptIfNeeded(BuildContext context, AppServices services) async {
  final s = services.settings;
  if (s.ownRangeKeys.isNotEmpty || s.rangePromptDismissed) return;
  await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const RangeDetectDialog(firstUse: true));
}

class RangeDetectDialog extends StatefulWidget {
  const RangeDetectDialog({super.key, this.firstUse = false});

  /// The first-use prompt: says why, can be skipped or not asked again.
  final bool firstUse;

  @override
  State<RangeDetectDialog> createState() => _RangeDetectDialogState();
}

class _RangeDetectDialogState extends State<RangeDetectDialog> with SingleTickerProviderStateMixin {
  // Starts empty: this is a new measurement.
  final _finder = RangeFinder();
  final _sung = ValueNotifier<double?>(null);
  final _empty = SongRange.of(NoteList(Float64List(0), Float64List(0), Float64List(0)));
  LiveAudio? _live;
  Ticker? _ticker;
  String? _error;
  bool _dontAsk = false;

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    final s = services.settings;
    try {
      final l = LiveAudio.create(services.engine, captureDevice: s.captureDeviceId, playbackDevice: s.playbackDeviceId, sampleRate: s.sampleRate);
      _live = l;
      l.startCapture(mode: 0, monitor: true);
      final gateDb = s.noiseGateEnabled ? s.noiseGateDb : double.negativeInfinity;
      _ticker = createTicker((_) => _drain(l, gateDb))..start();
    } catch (e) {
      _error = '$e';
    }
  }

  void _drain(LiveAudio l, double gateDb) {
    double? last;
    var any = false;
    for (final f in l.readFrames()) {
      if (f.source != 0) continue;
      any = true;
      if (f.f0 > 0 && f.rmsDb >= gateDb) {
        final m = hzToMidi(f.f0);
        _finder.add(m, f.time);
        last = m;
      } else {
        last = null;
      }
    }
    if (any) _sung.value = last;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    final l = _live;
    if (l != null) {
      try {
        if (l.isCapturing) l.stopCapture();
      } catch (_) {}
      l.dispose();
    }
    _finder.dispose();
    _sung.dispose();
    super.dispose();
  }

  Future<void> _skip() async {
    if (_dontAsk) await context.read<AppServices>().settings.setRangePromptDismissed(true);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    await context.read<AppServices>().settings.setOwnRangeKeys(_finder.keys.value);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: widget.firstUse ? Icon(Icons.piano, size: 36, color: theme.colorScheme.primary) : null,
      title: Text(tr(widget.firstUse ? 'rangePrompt.title' : 'ownRange.detectTitle')),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.firstUse) ...[
              Text(tr('rangePrompt.body'), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
            ],
            Text(tr('ownRange.detectHint'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            if (_error != null)
              Text(tr('ownRange.micError', {'error': _error!}), style: TextStyle(color: theme.colorScheme.error))
            else
              ListenableBuilder(
                listenable: Listenable.merge([_finder.keys, _sung]),
                builder: (context, _) {
                  final keys = _finder.keys.value;
                  final sung = _sung.value;
                  final own = VoiceZone.ofReached(keys);
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    VoiceKeyboard(
                      range: _empty,
                      shift: 0,
                      sungMidi: sung,
                      reached: keys,
                      own: keys.isEmpty ? null : (keys.reduce((a, b) => a < b ? a : b), keys.reduce((a, b) => a > b ? a : b)),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.mic, size: 16, color: sungKeyColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          keys.isEmpty
                              ? tr('ownRange.none')
                              : tr('keyboard.reached', {
                                  'low': noteName(keys.reduce((a, b) => a < b ? a : b).toDouble()),
                                  'high': noteName(keys.reduce((a, b) => a > b ? a : b).toDouble()),
                                }),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(sung == null ? '—' : noteName(sung), textAlign: TextAlign.end, style: theme.textTheme.titleMedium),
                      ),
                    ]),
                    if (keys.isNotEmpty && own == null) ...[
                      const SizedBox(height: 4),
                      Text(tr('keyboard.ownNarrow', {'n': '${VoiceZone.minOwnSpan}'}),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ]);
                },
              ),
            if (widget.firstUse)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _dontAsk,
                onChanged: (v) => setState(() => _dontAsk = v ?? false),
                title: Text(tr('rangePrompt.dontAsk')),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _error == null ? () => _finder.reset() : null, child: Text(tr('ownRange.restart'))),
        TextButton(
          onPressed: widget.firstUse ? _skip : () => Navigator.of(context).pop(),
          child: Text(tr(widget.firstUse ? 'calibPrompt.skip' : 'cancel')),
        ),
        ValueListenableBuilder<Set<int>>(
          valueListenable: _finder.keys,
          builder: (context, keys, _) => FilledButton(onPressed: keys.isEmpty ? null : _save, child: Text(tr('ownRange.save'))),
        ),
      ],
    );
  }
}
