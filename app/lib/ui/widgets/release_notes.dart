// "What's new" under a new-version notice: the CHANGELOG sections between
// this app and the latest release, in the UI language.
import 'package:flutter/material.dart';

import '../../services/update_checker.dart';
import '../../state/i18n.dart';

class ReleaseNotesView extends StatefulWidget {
  const ReleaseNotesView({super.key, required this.release, this.color, this.maxHeight = 260});
  final ReleaseInfo release;

  /// Text colour (e.g. onTertiaryContainer inside a coloured card).
  final Color? color;
  final double maxHeight;

  @override
  State<ReleaseNotesView> createState() => _ReleaseNotesViewState();
}

class _ReleaseNotesViewState extends State<ReleaseNotesView> {
  late Future<List<ReleaseNotes>> _notes;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _notes = UpdateChecker.fetchNotes(widget.release, I18n.lang);
  }

  @override
  void didUpdateWidget(ReleaseNotesView old) {
    super.didUpdateWidget(old);
    if (old.release.tag != widget.release.tag) _notes = UpdateChecker.fetchNotes(widget.release, I18n.lang);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Markdown that reads oddly as plain text: `code`, **bold**, [text](url).
  static String _plain(String s) => s
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll('**', '')
      .replaceAll('`', '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.color ?? theme.colorScheme.onSurface;
    return FutureBuilder<List<ReleaseNotes>>(
      future: _notes,
      builder: (context, snap) {
        final notes = snap.data;
        // Still loading, failed, or no changelog at that tag: the download
        // button's release page still has the details.
        if (notes == null || notes.isEmpty) return const SizedBox.shrink();
        final body = theme.textTheme.bodyMedium?.copyWith(color: color);
        final children = <Widget>[];
        for (final n in notes) {
          children.add(Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 12, bottom: 4),
            child: Text(
              n.date.isEmpty ? 'v${n.version}' : 'v${n.version} · ${n.date}',
              style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ));
          for (final line in n.lines) {
            final t = line.trimLeft();
            if (t.startsWith('#')) {
              children.add(Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(_plain(t.replaceFirst(RegExp(r'^#+\s*'), '')), style: theme.textTheme.labelLarge?.copyWith(color: color.withValues(alpha: 0.8), fontWeight: FontWeight.w700)),
              ));
            } else if (t.startsWith('- ') || t.startsWith('* ')) {
              children.add(Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('•  ', style: body),
                  Expanded(child: Text(_plain(t.substring(2)), style: body)),
                ]),
              ));
            } else {
              children.add(Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(_plain(t), style: body)));
            }
          }
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(tr('about.whatsNew'), style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.only(right: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
              ),
            ),
          ),
        ]);
      },
    );
  }
}
