// Asks whether to go on with a download whose server certificate could not
// be verified (issue #6). Only offered for files with a pinned sha256, see
// Downloader.certificatePrompt.
import 'package:flutter/material.dart';

import '../../state/i18n.dart';
import 'app_dialog.dart';

Future<bool> showCertificatePrompt(BuildContext context, Uri url, String error) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AppDialog(
        icon: Icon(Icons.gpp_maybe_outlined, color: theme.colorScheme.error),
        title: Text(tr('cert.title')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('cert.body', {'host': url.host})),
                const SizedBox(height: 12),
                Text(tr('cert.safety')),
                const SizedBox(height: 12),
                Text(tr('cert.question'), style: theme.textTheme.titleSmall),
                const SizedBox(height: 12),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(tr('settings.calibFail.details'), style: theme.textTheme.bodySmall),
                  children: [SelectableText('$url\n$error', style: theme.textTheme.bodySmall)],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error, foregroundColor: theme.colorScheme.onError),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('cert.continue')),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
