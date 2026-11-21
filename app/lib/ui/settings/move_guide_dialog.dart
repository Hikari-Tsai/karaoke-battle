// Settings > Data folder > "Move to another computer": how to take the
// songs, takes, history, replays and achievements to a new computer (the
// whole data folder), what is not in it, and macOS <-> Windows notes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/app_paths.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/app_dialog.dart';

const _macDefault = '~/Library/Application Support/com.karaokebattle.karaokeBattle/KaraokeBattle';
const _winDefault = r'%APPDATA%\com.karaokebattle\karaoke_battle\KaraokeBattle';

Future<void> showMoveGuide(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _MoveGuideDialog());

class _MoveGuideDialog extends StatelessWidget {
  const _MoveGuideDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paths = context.read<AppServices>().paths;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: cs.onSurfaceVariant);
    Widget step(int n, String title, String body, {Widget? extra}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(radius: 12, backgroundColor: cs.primary, child: Text('$n', style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w800))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                ?extra,
              ]),
            ),
          ]),
        );
    Widget note(IconData icon, Color color, String title, String body) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.35))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(body, style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
              ]),
            ),
          ]),
        );
    return AppDialog(
      title: Text(tr('move.title')),
      scrollable: true,
      content: SizedBox(
        width: 600,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('move.intro'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.5)),
          const SizedBox(height: 16),
          step(1, tr('move.s1.title'), tr('move.s1.body')),
          step(
            2,
            tr('move.s2.title'),
            tr('move.s2.body'),
            extra: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                Expanded(child: SelectableText(paths.root, style: mono)),
                IconButton(
                  tooltip: tr('setlist.copyPath'),
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => Clipboard.setData(ClipboardData(text: paths.root)),
                ),
                TextButton.icon(onPressed: () => revealPath(paths.root), icon: const Icon(Icons.folder_open, size: 18), label: Text(tr('open'))),
              ]),
            ),
          ),
          step(
            3,
            tr('move.s3.title'),
            tr('move.s3.body'),
            extra: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('macOS', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                SelectableText(_macDefault, style: mono),
                const SizedBox(height: 4),
                Text('Windows', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
                SelectableText(_winDefault, style: mono),
              ]),
            ),
          ),
          step(4, tr('move.s4.title'), tr('move.s4.body')),
          const SizedBox(height: 4),
          note(Icons.check_circle_outline, const Color(0xFF30D158), tr('move.kept.title'), tr('move.kept.body')),
          note(Icons.tune, const Color(0xFFFF9F0A), tr('move.notKept.title'), tr('move.notKept.body')),
          note(Icons.swap_horiz, const Color(0xFF64D2FF), tr('move.crossOs.title'), tr('move.crossOs.body')),
          if (paths.source == DataRootSource.environment) note(Icons.info_outline, cs.primary, tr('move.env.title'), tr('move.env.body')),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('close')))],
    );
  }
}
