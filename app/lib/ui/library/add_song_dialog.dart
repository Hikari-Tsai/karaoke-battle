// Add-song dialog: a drop zone / file picker for local media and a URL field
// for yt-dlp, each in its own labelled section.
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_services.dart';
import '../../state/i18n.dart';

const kLanguages = ['zh', 'ja', 'yue', 'en'];
const kMediaExtensions = ['mp4', 'mkv', 'webm', 'mov', 'mp3', 'm4a', 'wav', 'flac', 'ogg', 'aac'];

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
  bool _hover = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _language = context.read<AppServices>().settings.defaultLanguage;
    if (!kLanguages.contains(_language)) _language = 'zh';
    _url.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await body();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    await _guard(() => context.read<AppServices>().pipeline.addUrl(url, language: _language));
  }

  Future<void> _importPath(String path) => _guard(() => context.read<AppServices>().pipeline.importFile(path, language: _language));

  Future<void> _pickFile() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: kMediaExtensions);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    }
    final path = files.isEmpty ? null : files.first.path;
    if (path == null || !mounted) return;
    await _importPath(path);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _url.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasUrl = _url.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(tr('library.add')),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- local file --------------------------------------------------
            Text(tr('library.fileSection'), style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            DropTarget(
              onDragEntered: (_) => setState(() => _hover = true),
              onDragExited: (_) => setState(() => _hover = false),
              onDragDone: (d) {
                setState(() => _hover = false);
                if (_busy) return;
                for (final item in d.files) {
                  if (item.path.isNotEmpty) {
                    _importPath(item.path);
                    return;
                  }
                }
              },
              child: InkWell(
                onTap: _busy ? null : _pickFile,
                borderRadius: BorderRadius.circular(12),
                child: CustomPaint(
                  painter: _DashedBorderPainter(color: _hover ? cs.primary : cs.outline.withValues(alpha: 0.7), radius: 12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
                    decoration: BoxDecoration(
                      color: _hover ? cs.primary.withValues(alpha: 0.12) : cs.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.upload_file, size: 40, color: cs.primary),
                        const SizedBox(height: 10),
                        Text(tr('library.dropZone'), style: theme.textTheme.titleSmall, textAlign: TextAlign.center),
                        const SizedBox(height: 4),
                        Text(tr('library.supported'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(onPressed: _busy ? null : _pickFile, icon: const Icon(Icons.folder_open), label: Text(tr('library.pickFile'))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              const Expanded(child: Divider()),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(tr('library.or'), style: theme.textTheme.bodySmall)),
              const Expanded(child: Divider()),
            ]),
            const SizedBox(height: 12),
            // --- URL ---------------------------------------------------------
            Text(tr('library.urlSection'), style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      hintText: tr('library.urlHint'),
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: IconButton(tooltip: tr('library.paste'), icon: const Icon(Icons.content_paste), onPressed: _busy ? null : _paste),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addUrl(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy || !hasUrl ? null : _addUrl,
                  icon: const Icon(Icons.add),
                  label: Text(tr('library.addUrl')),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // --- language -------------------------------------------------------
            Row(
              children: [
                Icon(Icons.translate, size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(tr('library.language')),
                const SizedBox(width: 12),
                LanguageDropdown(value: _language, onChanged: (v) => setState(() => _language = v)),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              SelectableText(_error!, style: TextStyle(color: cs.error)),
            ],
            if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    const dash = 7.0;
    const gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, math.min(d + dash, metric.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color || old.radius != radius;
}
