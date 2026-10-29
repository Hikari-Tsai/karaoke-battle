// Latency calibration helpers shared by Settings and the first-use prompt.
import 'package:flutter/material.dart';

import '../../engine/engine.dart';
import '../../engine/engine_bindings.dart' show KeError;
import '../../state/app_services.dart';
import '../../state/i18n.dart';

/// Maps a calibration failure to a localized explanation with a fix.
String calibrationAdvice(Object e) {
  final msg = e is EngineException ? e.message : '$e';
  final code = e is EngineException ? e.code : 0;
  if (msg.contains('no click detected')) return tr('settings.calibFail.noClick');
  if (msg.contains('timed out')) return tr('settings.calibFail.timeout');
  if (code == KeError.state) return tr('settings.calibFail.busy');
  if (code == KeError.audioDevice || msg.contains('ke_audio_create') || msg.contains('device id')) return tr('settings.calibFail.device');
  return tr('settings.calibFail.other');
}

/// Runs a calibration with the devices chosen in Settings and stores the
/// result. Throws on failure (see [calibrationAdvice]).
Future<double> runCalibration(AppServices services) async {
  final s = services.settings;
  final sec = await LiveAudio.calibrateInBackground(
    services.engine,
    captureDevice: s.captureDeviceId,
    playbackDevice: s.playbackDeviceId,
    sampleRate: s.sampleRate,
  );
  await s.setLatencySeconds(sec);
  return sec;
}

/// Red panel with the localized advice and the raw engine message.
class CalibrationErrorPanel extends StatelessWidget {
  const CalibrationErrorPanel({super.key, required this.advice, this.details});
  final String advice;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 6),
            Text(tr('settings.calibFail.title'), style: theme.textTheme.titleSmall?.copyWith(color: cs.onErrorContainer)),
          ]),
          const SizedBox(height: 6),
          Text(advice, style: TextStyle(color: cs.onErrorContainer)),
          if (details != null)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text(tr('settings.calibFail.details'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onErrorContainer)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(details!, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: cs.onErrorContainer)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// First-use prompt shown before the sing screen opens its audio device when
/// latency has never been measured. Returns when the user is done (measured,
/// skipped, or chose not to be asked again).
Future<void> showCalibrationPromptIfNeeded(BuildContext context, AppServices services) async {
  final s = services.settings;
  if (s.latencySeconds != null || s.calibrationPromptDismissed) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CalibrationPrompt(services: services),
  );
}

class _CalibrationPrompt extends StatefulWidget {
  const _CalibrationPrompt({required this.services});
  final AppServices services;

  @override
  State<_CalibrationPrompt> createState() => _CalibrationPromptState();
}

class _CalibrationPromptState extends State<_CalibrationPrompt> {
  bool _running = false;
  bool _dontAsk = false;
  double? _result;
  String? _advice;
  String? _details;

  Future<void> _measure() async {
    setState(() {
      _running = true;
      _advice = null;
      _details = null;
    });
    try {
      final sec = await runCalibration(widget.services);
      if (mounted) setState(() => _result = sec);
    } catch (e) {
      if (mounted) {
        setState(() {
          _advice = calibrationAdvice(e);
          _details = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _close() async {
    if (_dontAsk && _result == null) await widget.services.settings.setCalibrationPromptDismissed(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final done = _result != null;
    return AlertDialog(
      icon: Icon(done ? Icons.check_circle : Icons.timer_outlined, size: 36, color: done ? const Color(0xFF30D158) : cs.primary),
      title: Text(done ? tr('calibPrompt.doneTitle') : tr('calibPrompt.title')),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (done)
              Text(tr('calibPrompt.done', {'ms': (_result! * 1000).round()}), style: theme.textTheme.bodyLarge)
            else ...[
              Text(tr('calibPrompt.body')),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: cs.secondaryContainer.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.speaker, size: 18, color: cs.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tr('settings.calibrateHint'), style: TextStyle(color: cs.onSecondaryContainer))),
                ]),
              ),
              if (_running) ...[
                const SizedBox(height: 16),
                Row(children: [
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text(tr('settings.calibrating')),
                ]),
              ],
              if (_advice != null) ...[
                const SizedBox(height: 12),
                CalibrationErrorPanel(advice: _advice!, details: _details),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _dontAsk,
                onChanged: _running ? null : (v) => setState(() => _dontAsk = v ?? false),
                title: Text(tr('calibPrompt.dontAsk')),
              ),
            ],
          ],
        ),
      ),
      actions: done
          ? [FilledButton(onPressed: _close, child: Text(tr('calibPrompt.continue')))]
          : [
              TextButton(onPressed: _running ? null : _close, child: Text(tr('calibPrompt.skip'))),
              FilledButton.icon(
                onPressed: _running ? null : _measure,
                icon: const Icon(Icons.play_arrow),
                label: Text(_advice == null ? tr('calibPrompt.measure') : tr('calibPrompt.retry')),
              ),
            ],
    );
  }
}
