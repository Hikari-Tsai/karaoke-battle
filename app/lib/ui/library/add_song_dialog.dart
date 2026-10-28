// Add-song dialog: URL (yt-dlp) or local file (file_picker).
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_services.dart';
import '../../state/i18n.dart';

const kLanguages = ['zh', 'ja', 'yue', 'en'];

class LanguageDropdown extends StatelessWidget {
  const LanguageDropdown({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: kLanguages.contains(value) ? value : 'zh',
      items: [for (final l in kLanguages) DropdownMenuItem(value: l, child: Text(tr('lang.$l')))],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

class AddSongDialog extends StatefulWidget {
  const AddSongDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(context: context, builder: (_) => const AddSongDialog());

  @override
  State<AddSongDialog> createState() => _AddSongDialogState();
}

class _AddSongDialogState extends State<AddSongDialog> {
  final _url = TextEditingController();
  late String _language;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _language = context.read<AppServices>().settings.defaultLanguage;
    if (!kLanguages.contains(_language)) _language = 'zh';
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _addUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final services = context.read<AppServices>();
      await services.pipeline.addUrl(url, language: _language);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['mp4', 'mkv', 'webm', 'mov', 'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac']);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppServices>().pipeline.importFile(path, language: _language);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('library.add')),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(labelText: tr('library.url'), hintText: tr('library.urlHint'), border: const OutlineInputBorder()),
              onSubmitted: (_) => _addUrl(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(tr('library.language')),
                const SizedBox(width: 12),
                LanguageDropdown(value: _language, onChanged: (v) => setState(() => _language = v)),
                const Spacer(),
                OutlinedButton.icon(onPressed: _busy ? null : _pickFile, icon: const Icon(Icons.folder_open), label: Text(tr('library.pickFile'))),
              ],
            ),
            const SizedBox(height: 8),
            Text(tr('library.orDrop'), style: Theme.of(context).textTheme.bodySmall),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
        FilledButton(onPressed: _busy ? null : _addUrl, child: Text(tr('library.addUrl'))),
      ],
    );
  }
}
