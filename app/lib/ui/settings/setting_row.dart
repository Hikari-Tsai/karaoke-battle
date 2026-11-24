// One line of a settings card: the title and hint on the left, the control
// on the right, so dropdowns and sliders line up at one width.

import 'package:flutter/material.dart';

/// A settings line: the title (with its circled i) and a short hint on the
/// left, the control on the right, as the switch tiles lay out.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, required this.trailing, this.info, this.subtitle});
  final String title;
  final Widget? info;
  final String? subtitle;
  final Widget trailing;

  /// Width of the dropdowns and sliders, so they line up on the right.
  static const controlWidth = 340.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [Flexible(child: Text(title, style: theme.textTheme.bodyLarge)), ?info]),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          trailing,
        ],
      ),
    );
  }
}

/// A slider of [SettingRow.controlWidth] with its value on the right and
/// optional buttons around it; their places are kept when empty, so the
/// sliders of one card start and end in line.
class SliderControl extends StatelessWidget {
  const SliderControl({super.key, required this.slider, required this.value, this.leading, this.trailing});
  final Widget slider;
  final String value;
  final Widget? leading, trailing;

  static const buttonWidth = 40.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SettingRow.controlWidth,
      child: Row(
        children: [
          SizedBox(width: buttonWidth, child: leading),
          Expanded(child: slider),
          SizedBox(width: buttonWidth, child: trailing),
          SizedBox(width: 72, child: Text(value, textAlign: TextAlign.end, style: Theme.of(context).textTheme.titleSmall)),
        ],
      ),
    );
  }
}
