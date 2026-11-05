// Asked when a song's preparation finds no lyrics: import a subtitle file,
// type them in, or (once available) recognise them with Whisper.
import 'package:flutter/material.dart';

import '../../services/song_library.dart';
import '../../state/i18n.dart';
import 'lyrics_actions.dart';

Future<void> showNoLyricsDialog(BuildContext context, Song song) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      Widget option(IconData icon, String label, String? value, {bool primary = false}) {
        final onPressed = value == null ? null : () => Navigator.pop(ctx, value);
        final child = Align(alignment: Alignment.centerLeft, child: Text(label));
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: primary
                ? FilledButton.icon(onPressed: onPressed, icon: Icon(icon), label: child)
                : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon), label: child),
          ),
        );
      }

      return AlertDialog(
        icon: const Icon(Icons.subtitles_off_outlined),
        title: Text(tr('lyrics.none.title')),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('lyrics.none.body', {'title': song.title}), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 8),
            option(Icons.file_open_outlined, tr('lyrics.none.import'), 'import', primary: true),
            option(Icons.content_paste, tr('lyrics.none.paste'), 'paste'),
            option(Icons.graphic_eq, tr('lyrics.none.whisperRun'), 'whisper'),
            option(Icons.edit_note, tr('lyrics.none.type'), 'type'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('lyrics.none.skip')))],
      );
    },
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'import':
      await pickAndImportLyrics(context, song);
    case 'paste':
      await pasteLyrics(context, song);
    case 'whisper':
      await recognizeLyrics(context, song);
    case 'type':
      await openLyricsEditor(context, song);
  }
}
