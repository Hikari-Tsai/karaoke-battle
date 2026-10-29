// Vocal return (hear yourself through the app) and the hall reverb on the
// voice: stage buttons for the sing / replay screens and a settings block.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../state/i18n.dart';

const _onColor = Color(0xFFFFD60A);

/// Asks once for headphones before the first vocal return (speakers feed back).
Future<bool> confirmVocalReturn(BuildContext context) async {
  final st = context.read<AppSettings>();
  if (st.vocalReturnWarned) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.headphones, size: 32),
      title: Text(tr('voiceFx.warnTitle')),
      content: SizedBox(width: 420, child: Text(tr('voiceFx.warnBody'))),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(tr('voiceFx.warnOk'))),
      ],
    ),
  );
  if (ok == true) await st.setVocalReturnWarned(true);
  return ok == true;
}

Future<void> toggleVocalReturn(BuildContext context) async {
  final st = context.read<AppSettings>();
  if (st.vocalReturn) {
    await st.setVocalReturn(false);
    return;
  }
  if (await confirmVocalReturn(context)) await st.setVocalReturn(true);
}

/// Headset toggle for the vocal return (yellow when on).
class VocalReturnButton extends StatelessWidget {
  const VocalReturnButton({super.key});

  @override
  Widget build(BuildContext context) {
    final on = context.watch<AppSettings>().vocalReturn;
    return IconButton(
      tooltip: tr(on ? 'voiceFx.vocalReturnOff' : 'voiceFx.vocalReturnOn'),
      onPressed: () => toggleVocalReturn(context),
      icon: Icon(on ? Icons.headset_mic : Icons.headset_mic_outlined, color: on ? _onColor : Colors.white),
    );
  }
}

/// Reverb button: opens a small panel with on/off and the mix. [onPreview]
/// gets every slider move (for instant feedback); [onClosed] runs when the
/// panel closes after a change (the replay screen re-renders its mix then).
class ReverbButton extends StatefulWidget {
  const ReverbButton({super.key, this.onPreview, this.onClosed, this.showLiveHint = true, this.offColor = Colors.white});
  final void Function(bool on, double mix)? onPreview;

  /// Icon colour while the reverb is off (white over the stage).
  final Color offColor;
  final VoidCallback? onClosed;

  /// Mention that live listening needs the vocal return (sing screen only).
  final bool showLiveHint;

  @override
  State<ReverbButton> createState() => _ReverbButtonState();
}

class _ReverbButtonState extends State<ReverbButton> {
  final _controller = MenuController();
  bool _changed = false;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    return MenuAnchor(
      controller: _controller,
      alignmentOffset: const Offset(-220, 4),
      onClose: () {
        if (_changed) widget.onClosed?.call();
        _changed = false;
      },
      menuChildren: [
        _ReverbPanel(
          showLiveHint: widget.showLiveHint && !st.vocalReturn,
          onChanged: (on, mix) {
            _changed = true;
            widget.onPreview?.call(on, mix);
          },
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tr('voiceFx.reverb'),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(Icons.spatial_audio, color: st.reverbOn ? _onColor : widget.offColor),
      ),
    );
  }
}

class _ReverbPanel extends StatefulWidget {
  const _ReverbPanel({required this.onChanged, required this.showLiveHint});
  final void Function(bool on, double mix) onChanged;
  final bool showLiveHint;

  @override
  State<_ReverbPanel> createState() => _ReverbPanelState();
}

class _ReverbPanelState extends State<_ReverbPanel> {
  late double _mix = context.read<AppSettings>().reverbMix;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final theme = Theme.of(context);
    return SizedBox(
      width: 300,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(tr('voiceFx.reverb'), style: theme.textTheme.titleSmall)),
              Switch(
                value: st.reverbOn,
                onChanged: (v) {
                  st.setReverbOn(v);
                  widget.onChanged(v, _mix);
                },
              ),
            ]),
            Row(children: [
              Text(tr('voiceFx.mix')),
              Expanded(
                child: Slider(
                  value: _mix,
                  onChanged: !st.reverbOn
                      ? null
                      : (v) {
                          setState(() => _mix = v);
                          widget.onChanged(true, v);
                        },
                  onChangeEnd: (v) => st.setReverbMix(v),
                ),
              ),
              SizedBox(width: 48, child: Text('${(_mix * 100).round()}%', textAlign: TextAlign.end)),
            ]),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                widget.showLiveHint ? '${tr('voiceFx.reverbNeedsReturn')}\n${tr('voiceFx.reverbHint')}' : tr('voiceFx.reverbHint'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings block: vocal return switch, reverb switch and mix.
class VoiceFxSettings extends StatelessWidget {
  const VoiceFxSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.headset_mic),
          title: Text(tr('voiceFx.vocalReturn')),
          subtitle: Text(tr('voiceFx.vocalReturnHint')),
          value: st.vocalReturn,
          onChanged: (v) => v ? toggleVocalReturn(context) : st.setVocalReturn(false),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.spatial_audio),
          title: Text(tr('voiceFx.reverb')),
          subtitle: Text(tr('voiceFx.reverbHint')),
          value: st.reverbOn,
          onChanged: st.setReverbOn,
        ),
        Row(children: [
          const SizedBox(width: 40),
          Text(tr('voiceFx.mix')),
          Expanded(child: _MixSlider(enabled: st.reverbOn)),
        ]),
        Text(tr('voiceFx.credit'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _MixSlider extends StatefulWidget {
  const _MixSlider({required this.enabled});
  final bool enabled;

  @override
  State<_MixSlider> createState() => _MixSliderState();
}

class _MixSliderState extends State<_MixSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final v = _drag ?? st.reverbMix;
    return Row(children: [
      Expanded(
        child: Slider(
          value: v,
          onChanged: widget.enabled ? (x) => setState(() => _drag = x) : null,
          onChangeEnd: (x) {
            st.setReverbMix(x);
            setState(() => _drag = null);
          },
        ),
      ),
      SizedBox(width: 44, child: Text('${(v * 100).round()}%', textAlign: TextAlign.end)),
    ]);
  }
}
