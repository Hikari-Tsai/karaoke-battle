// Model and tool rows with download controls (setup gate and Settings).
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/model_registry.dart';
import '../../services/sidecars.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';
import 'ytdlp_dialog.dart';

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
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final files = await FilePicker.pickFiles(dialogTitle: tr('sidecar.pickTitle', {'name': nameOf(kind)}));
      final path = files.isEmpty ? null : files.first.path;
      if (path != null) await setup.useExecutable(kind, path);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('${tr('error')}: $e')));
    }
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
              else ...[
                if (!s.available && s.hasSource)
                  OutlinedButton(
                    onPressed: () async {
                      await setup.installSidecar(kind);
                      final err = setup.sidecarStates[kind]!.error;
                      if (kind == SidecarKind.ytDlp && err != null && context.mounted) await showYtDlpDialog(context, YtDlpIssue.failed, err);
                    },
                    child: Text(tr('install')),
                  ),
                // Any tool can point at the user's own copy (e.g. a newer
                // yt-dlp or a full ffmpeg build).
                TextButton(onPressed: () => _pickExecutable(context), child: Text(tr('sidecar.pickPath'))),
              ],
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
