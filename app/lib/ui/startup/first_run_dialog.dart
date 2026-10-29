// First-run check: required models + sidecars with download buttons.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/model_registry.dart';
import '../../services/sidecars.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';

Future<void> showFirstRunDialogIfNeeded(BuildContext context) async {
  final setup = context.read<SetupController>();
  await setup.refresh();
  final missingSidecar = [SidecarKind.ytDlp, SidecarKind.ffmpeg].any((k) => !setup.sidecarStates[k]!.available);
  if (setup.requiredInstalled && !missingSidecar) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ChangeNotifierProvider.value(value: setup, child: const FirstRunDialog()),
  );
}

class FirstRunDialog extends StatelessWidget {
  const FirstRunDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final setup = context.watch<SetupController>();
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(tr('firstRun.title')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('firstRun.body')),
              const SizedBox(height: 12),
              for (final m in ModelRegistry.required) ModelRow(spec: m),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('${tr('firstRun.total')}: ${formatBytes(ModelRegistry.required.fold(0, (a, m) => a + m.totalBytes))}', style: theme.textTheme.bodySmall),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: setup.requiredInstalled || setup.anyDownloading ? null : () => setup.installAll(ModelRegistry.required),
                    icon: const Icon(Icons.download),
                    label: Text('${tr('firstRun.downloadAll')} (${formatBytes(setup.requiredMissingBytes)})'),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(tr('firstRun.sidecars'), style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final k in [SidecarKind.ytDlp, SidecarKind.ffmpeg, SidecarKind.deno]) SidecarRow(kind: k),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: setup.anyDownloading ? null : () => Navigator.of(context).pop(), child: Text(tr('later'))),
        FilledButton(onPressed: setup.anyDownloading ? null : () => Navigator.of(context).pop(), child: Text(tr('ok'))),
      ],
    );
  }
}

/// One model with state + install/remove controls (shared with Settings).
class ModelRow extends StatelessWidget {
  const ModelRow({super.key, required this.spec, this.showRemove = false});
  final ModelSpec spec;
  final bool showRemove;

  @override
  Widget build(BuildContext context) {
    final setup = context.watch<SetupController>();
    final s = setup.stateOf(spec);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(s.installed ? Icons.check_circle : Icons.circle_outlined, size: 18, color: s.installed ? const Color(0xFF4CD964) : cs.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(spec.title),
                    Text('${spec.repo} · ${formatBytes(spec.totalBytes)} · ${spec.license}', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              if (s.downloading)
                TextButton(onPressed: () => setup.cancel(spec), child: Text(tr('cancel')))
              else if (!s.installed)
                OutlinedButton(onPressed: () => setup.install(spec), child: Text(tr('download')))
              else if (showRemove)
                TextButton(onPressed: () => setup.remove(spec), child: Text(tr('remove')))
              else
                Text(tr('installed'), style: theme.textTheme.bodySmall),
            ],
          ),
          if (s.downloading) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: s.fraction),
            Text('${s.file}  ${formatBytes(s.doneBytes)} / ${formatBytes(spec.totalBytes)}', style: theme.textTheme.bodySmall),
          ],
          if (s.error != null) Text(s.error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
        ],
      ),
    );
  }
}

class SidecarRow extends StatelessWidget {
  const SidecarRow({super.key, required this.kind});
  final SidecarKind kind;

  static String nameOf(SidecarKind k) => switch (k) {
        SidecarKind.ytDlp => 'yt-dlp',
        SidecarKind.ffmpeg => 'ffmpeg',
        SidecarKind.ffprobe => 'ffprobe',
        SidecarKind.deno => 'deno',
      };

  Future<void> _pickExecutable(BuildContext context) async {
    final setup = context.read<SetupController>();
    final files = await FilePicker.pickFiles();
    final path = files.isEmpty ? null : files.first.path;
    if (path != null) await setup.useExecutable(kind, path);
  }

  @override
  Widget build(BuildContext context) {
    final setup = context.watch<SetupController>();
    final s = setup.sidecarStates[kind]!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final noSource = !s.hasSource && !s.available;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(s.available ? Icons.check_circle : Icons.circle_outlined, size: 18, color: s.available ? const Color(0xFF4CD964) : cs.outline),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nameOf(kind)),
                    Text(s.path ?? tr('notInstalled'), style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (s.installing)
                const SizedBox(width: 120, child: LinearProgressIndicator())
              else if (!s.available && s.hasSource)
                OutlinedButton(onPressed: () => setup.installSidecar(kind), child: Text(tr('install')))
              else if (kind == SidecarKind.ffmpeg || !s.available)
                TextButton(onPressed: () => _pickExecutable(context), child: Text(tr('firstRun.pickFfmpeg'))),
            ],
          ),
          if (noSource && kind == SidecarKind.ffmpeg)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(tr('firstRun.ffmpegHint'), style: theme.textTheme.bodySmall),
            ),
          if (s.error != null) Text(s.error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error)),
        ],
      ),
    );
  }
}
