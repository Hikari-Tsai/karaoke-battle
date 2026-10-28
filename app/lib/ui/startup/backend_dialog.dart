// Backend decision dialogs shown after BackendManager.detect().
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/backend_manager.dart';
import '../../services/settings.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';

/// Shows the dialog matching [decision.dialog]; returns when dismissed.
Future<void> showBackendDialog(BuildContext context, AppServices services, BackendDecision decision) async {
  if (decision.dialog == BackendDialog.none) return;
  if (services.settings.dismissedBackendDialog && decision.dialog != BackendDialog.cudaSelftestFailed) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _BackendDialog(services: services, decision: decision),
  );
}

class _BackendDialog extends StatefulWidget {
  const _BackendDialog({required this.services, required this.decision});
  final AppServices services;
  final BackendDecision decision;

  @override
  State<_BackendDialog> createState() => _BackendDialogState();
}

class _BackendDialogState extends State<_BackendDialog> {
  bool _dontShow = false;
  bool _installing = false;
  double _fraction = 0;
  String _stage = '';
  String? _error;
  CudaPackManifest? _manifest;

  @override
  void initState() {
    super.initState();
    widget.services.backend.cudaPackManifest().then((m) {
      if (mounted) setState(() => _manifest = m);
    });
  }

  String get _gpuName {
    final gpus = widget.decision.gpus.where((g) => !g.isSoftware).toList();
    return gpus.isEmpty ? tr('unknown') : gpus.first.name;
  }

  Future<void> _close({BackendChoice? choose}) async {
    if (_dontShow) await widget.services.settings.setDismissedBackendDialog(true);
    if (choose != null) {
      await widget.services.settings.setBackend(choose);
      widget.services.backend.resetRuntime();
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _installCuda() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await widget.services.backend.installCudaPack(onProgress: (stage, f) {
        if (mounted) {
          setState(() {
            _stage = stage;
            _fraction = f;
          });
        }
      });
      widget.services.backend.resetRuntime();
      await widget.services.backend.detect();
      await _close(choose: BackendChoice.auto);
    } catch (e) {
      setState(() {
        _error = '$e';
        _installing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.decision;
    final theme = Theme.of(context);
    final String title;
    final String body;
    final actions = <Widget>[];
    switch (d.dialog) {
      case BackendDialog.driverTooOld:
        title = tr('backend.driverOld.title');
        body = '${tr('backend.driverOld.body')}\n${d.detail}';
        actions.addAll([
          TextButton(onPressed: () => launchUrl(Uri.parse('https://www.nvidia.com/Download/index.aspx')), child: Text(tr('backend.driverOld.link'))),
          FilledButton(onPressed: () => _close(choose: BackendChoice.auto), child: Text(tr('backend.useDirectml'))),
        ]);
      case BackendDialog.cudaPackMissing:
        title = tr('backend.cudaMissing.title');
        body = tr('backend.cudaMissing.body', {'gpu': _gpuName, 'size': _manifest == null ? '…' : formatBytes(_manifest!.totalBytes)});
        actions.addAll([
          TextButton(onPressed: _installing ? null : () => _close(), child: Text(tr('later'))),
          TextButton(onPressed: _installing ? null : () => _close(choose: BackendChoice.directml), child: Text(tr('backend.useDirectml'))),
          FilledButton(onPressed: _installing || _manifest == null || _manifest!.files.isEmpty ? null : _installCuda, child: Text(tr('backend.cudaMissing.download'))),
        ]);
      case BackendDialog.cudaSelftestFailed:
        title = tr('backend.selftestFailed.title');
        body = '${tr('backend.selftestFailed.body')}\n${widget.services.backend.lastSelftestError ?? ''}';
        actions.addAll([
          TextButton(onPressed: _installing ? null : () => _close(choose: BackendChoice.directml), child: Text(tr('backend.useDirectml'))),
          FilledButton(
              onPressed: _installing
                  ? null
                  : () async {
                      await widget.services.backend.removeCudaPack();
                      await _installCuda();
                    },
              child: Text(tr('backend.redownload'))),
        ]);
      case BackendDialog.noGpuCpuOnly:
        title = tr('backend.noGpu.title');
        body = tr('backend.noGpu.body');
        actions.add(FilledButton(onPressed: () => _close(), child: Text(tr('ok'))));
      case BackendDialog.usingDirectml:
        title = tr('backend.directml.title');
        body = '${tr('backend.directml.body', {'gpu': _gpuName})}${d.detail.isEmpty ? '' : '\n${d.detail}'}';
        actions.add(FilledButton(onPressed: () => _close(), child: Text(tr('ok'))));
      case BackendDialog.none:
        title = '';
        body = '';
    }
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (_installing) ...[
              const SizedBox(height: 12),
              Text('${tr('backend.installing')} $_stage', style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: _fraction),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _dontShow,
              onChanged: (v) => setState(() => _dontShow = v ?? false),
              title: Text(tr('backend.dontShowAgain')),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ],
        ),
      ),
      actions: actions,
    );
  }
}
