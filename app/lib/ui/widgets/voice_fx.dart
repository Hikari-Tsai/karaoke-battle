// Vocal return (hear yourself through the app) and the hall reverb on the
// voice: one stage button with a panel for the sing / replay screens, and a
// settings block.
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

/// The voice button over the stage: one mic icon (yellow while the return
/// or the reverb is on) that opens a panel with the vocal return switch, the
/// reverb switch and the mix. [onPreview] gets every reverb change (instant
/// feedback); [onClosed] runs when the panel closes after a change (the
/// replay screen re-renders its mix then). Replays have no microphone, so
/// [showReturn] hides the return there.
class VoiceFxButton extends StatefulWidget {
  const VoiceFxButton({super.key, this.onPreview, this.onClosed, this.showReturn = true, this.offColor = Colors.white});
  final void Function(bool on, double mix)? onPreview;
  final VoidCallback? onClosed;
  final bool showReturn;

  /// Icon colour while everything is off (white over the stage).
  final Color offColor;

  @override
  State<VoiceFxButton> createState() => _VoiceFxButtonState();
}

class _VoiceFxButtonState extends State<VoiceFxButton> {
  final _controller = MenuController();
  bool _changed = false;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final active = (widget.showReturn && st.vocalReturn) || st.reverbOn;
    return MenuAnchor(
      controller: _controller,
      alignmentOffset: const Offset(-280, 4),
      onClose: () {
        if (_changed) widget.onClosed?.call();
        _changed = false;
      },
      menuChildren: [
        _VoiceFxPanel(
          showReturn: widget.showReturn,
          onReverbChanged: (on, mix) {
            _changed = true;
            widget.onPreview?.call(on, mix);
          },
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tr(widget.showReturn ? 'voiceFx.button' : 'voiceFx.reverb'),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(active ? Icons.mic : Icons.mic_none, color: active ? _onColor : widget.offColor),
      ),
    );
  }
}

class _VoiceFxPanel extends StatefulWidget {
  const _VoiceFxPanel({required this.onReverbChanged, required this.showReturn});
  final void Function(bool on, double mix) onReverbChanged;
  final bool showReturn;

  @override
  State<_VoiceFxPanel> createState() => _VoiceFxPanelState();
}

class _VoiceFxPanelState extends State<_VoiceFxPanel> {
  late double _mix = context.read<AppSettings>().reverbMix;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget row(IconData icon, String title, String? hint, bool value, ValueChanged<bool> onChanged) => Row(children: [
          Icon(icon, size: 20, color: value ? _onColor : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.titleSmall),
              if (hint != null) Text(hint, style: muted),
            ]),
          ),
          Switch(value: value, onChanged: onChanged),
        ]);
    return SizedBox(
      width: 320,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showReturn) ...[
              row(Icons.headphones, tr('voiceFx.vocalReturn'), tr('voiceFx.returnShort'), st.vocalReturn,
                  (v) => v ? toggleVocalReturn(context) : st.setVocalReturn(false)),
              const Divider(height: 20),
            ],
            row(Icons.waves, tr('voiceFx.reverb'), null, st.reverbOn, (v) {
              st.setReverbOn(v);
              widget.onReverbChanged(v, _mix);
            }),
            Row(children: [
              const SizedBox(width: 30),
              Text(tr('voiceFx.mix')),
              Expanded(
                child: Slider(
                  value: _mix,
                  onChanged: !st.reverbOn
                      ? null
                      : (v) {
                          setState(() => _mix = v);
                          widget.onReverbChanged(true, v);
                        },
                  onChangeEnd: (v) => st.setReverbMix(v),
                ),
              ),
              SizedBox(width: 48, child: Text('${(_mix * 100).round()}%', textAlign: TextAlign.end)),
            ]),
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 2),
              child: Text(
                widget.showReturn && st.reverbOn && !st.vocalReturn
                    ? '${tr('voiceFx.reverbNeedsReturn')}\n${tr('voiceFx.reverbHint')}'
                    : tr('voiceFx.reverbHint'),
                style: muted,
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
          secondary: const Icon(Icons.headphones),
          title: Text(tr('voiceFx.vocalReturn')),
          subtitle: Text(tr('voiceFx.vocalReturnHint')),
          value: st.vocalReturn,
          onChanged: (v) => v ? toggleVocalReturn(context) : st.setVocalReturn(false),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.waves),
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
