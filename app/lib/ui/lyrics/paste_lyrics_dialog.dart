// Paste lyrics as plain text; the app times them (GAME notes by default,
// Whisper optionally).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/model_registry.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import 'recognize_dialog.dart';

/// The pasted text and how to time it, or null when cancelled.
Future<RecognizeRequest?> showPasteLyricsDialog(BuildContext context) =>
    showDialog<RecognizeRequest>(context: context, builder: (_) => const _PasteLyricsDialog());

class _PasteLyricsDialog extends StatefulWidget {
  const _PasteLyricsDialog();

  @override
  State<_PasteLyricsDialog> createState() => _PasteLyricsDialogState();
}

class _PasteLyricsDialogState extends State<_PasteLyricsDialog> {
  final _text = TextEditingController();
  bool _whisper = false;
  String? _language; // for the AI; null = detect

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final size = formatBytes(ModelRegistry.whisperLarge.totalBytes);
    final installed = context.read<AppServices>().models.isInstalled(ModelRegistry.whisperLarge);
    return AlertDialog(
      icon: const Icon(Icons.content_paste),
      title: Text(tr('paste.title')),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('paste.hint'), style: muted),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 10,
            maxLines: 16,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(border: const OutlineInputBorder(), hintText: tr('paste.placeholder')),
          ),
          const SizedBox(height: 12),
          Text(tr('paste.method'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.music_note), label: Text(tr('paste.byNotes'))),
              ButtonSegment(value: true, icon: const Icon(Icons.graphic_eq), label: Text(tr('paste.byWhisper'))),
            ],
            selected: {_whisper},
            onSelectionChanged: (v) => setState(() => _whisper = v.first),
          ),
          const SizedBox(height: 6),
          FutureBuilder<bool>(
            future: installed,
            builder: (context, snap) => Text(
              _whisper ? tr(snap.data == true ? 'paste.byWhisperHint' : 'paste.byWhisperDownload', {'size': size}) : tr('paste.byNotesHint'),
              style: muted,
            ),
          ),
          if (_whisper) ...[
            const SizedBox(height: 12),
            Text(tr('recognize.chooseLang'), style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            LanguageChips(value: _language, onChanged: (v) => setState(() => _language = v)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: _text.text.trim().isEmpty ? null : () => Navigator.pop(context, RecognizeRequest.align(_text.text, useWhisper: _whisper, language: _language)),
          child: Text(tr('paste.start')),
        ),
      ],
    );
  }
}
