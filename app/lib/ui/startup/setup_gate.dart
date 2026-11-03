// Shown instead of the app until every required model passes its check and
// the required tools are present (checked on every launch).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/model_registry.dart';
import '../../services/sidecars.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';
import '../widgets/brand.dart';
import 'setup_rows.dart';

class SetupGate extends StatelessWidget {
  const SetupGate({super.key, required this.checking, required this.onContinue});

  /// The launch check is still running.
  final bool checking;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final setup = context.watch<SetupController>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: BrandedTitle(tr('gate.title'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: checking
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(tr('gate.checking'), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(setup.verifying ?? '', style: theme.textTheme.bodySmall),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(tr('gate.body'), style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 16),
                    Text(tr('firstRun.body')),
                    const SizedBox(height: 8),
                    for (final m in ModelRegistry.required) ModelRow(spec: m),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text('${tr('firstRun.total')}: ${formatBytes(ModelRegistry.required.fold(0, (a, m) => a + m.totalBytes))}',
                            style: theme.textTheme.bodySmall),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: setup.requiredInstalled || setup.anyDownloading ? null : () => setup.installAll(ModelRegistry.required),
                          icon: const Icon(Icons.download),
                          label: Text('${tr('firstRun.downloadAll')} (${formatBytes(setup.requiredMissingBytes)})'),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    Text(tr('firstRun.sidecars'), style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final k in [SidecarKind.ytDlp, SidecarKind.ffmpeg, SidecarKind.deno]) SidecarRow(kind: k),
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: setup.ready && !setup.anyDownloading ? onContinue : null,
                        child: Text(setup.ready ? tr('gate.continue') : tr('gate.notReady')),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
