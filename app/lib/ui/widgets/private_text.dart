// 直播模式 on screen: text that may hold private details (a path, an alert
// URL) masked while a streaming app runs, and the badge that says the mode
// is on (see state/stream_privacy.dart).
import 'package:flutter/material.dart';

import '../../state/i18n.dart';
import '../../state/stream_privacy.dart';

/// [text] as it may be shown (masked in 直播模式), updating when the mode
/// changes.
class PrivateText extends StatelessWidget {
  const PrivateText(this.text, {super.key, this.style, this.selectable = false, this.maxLines, this.overflow});

  /// Selectable while not masked (an error message, a path).
  const PrivateText.selectable(this.text, {super.key, this.style, this.maxLines, this.overflow}) : selectable = true;
  final String text;
  final TextStyle? style;
  final bool selectable;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: StreamPrivacy.live,
        builder: (context, live, _) {
          final s = live ? maskPrivate(text) : text;
          // Masked text is not for copying.
          return selectable && !live ? SelectableText(s, style: style, maxLines: maxLines) : Text(s, style: style, maxLines: maxLines, overflow: overflow);
        },
      );
}

/// 直播模式 on: a small red badge (nothing while off).
class LiveModeBadge extends StatelessWidget {
  const LiveModeBadge({super.key, this.compact = false, this.leadingGap = 0});

  /// Narrower padding.
  final bool compact;

  /// Space before it, only when it shows.
  final double leadingGap;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: StreamPrivacy.live,
        builder: (context, live, _) {
          if (!live) return const SizedBox.shrink();
          final theme = Theme.of(context);
          final badge = Tooltip(
            message: tr(StreamPrivacy.simulate.value ? 'liveMode.tipSimulated' : 'liveMode.tip'),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFE53935), borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.videocam, size: 14, color: Colors.white),
                const SizedBox(width: 4),
                Text(tr('liveMode.badge'), style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
              ]),
            ),
          );
          return leadingGap == 0 ? badge : Padding(padding: EdgeInsets.only(left: leadingGap), child: badge);
        },
      );
}
