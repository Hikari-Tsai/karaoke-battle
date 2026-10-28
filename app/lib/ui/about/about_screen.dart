// About: version and license summary with links.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_services.dart';
import '../../state/i18n.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _items = <(String, String, String, bool)>[
    // name, license, url, nonCommercial
    ('Karaoke Battle', 'MIT', 'https://github.com', false),
    ('GAME (openvpi) — transcription models', 'CC BY-NC-SA 4.0', 'https://github.com/openvpi/GAME', true),
    ('UVR MDX-Net (Kim_Vocal_2, Inst_HQ_4)', 'MIT', 'https://github.com/Anjok07/ultimatevocalremovergui', false),
    ('SwiftF0', 'MIT', 'https://github.com/lars76/swift-f0', false),
    ('ONNX Runtime', 'MIT', 'https://github.com/microsoft/onnxruntime', false),
    ('miniaudio', 'MIT-0', 'https://github.com/mackron/miniaudio', false),
    ('pocketfft', 'BSD-3-Clause', 'https://github.com/mreineck/pocketfft', false),
    ('signalsmith-stretch', 'MIT', 'https://github.com/Signalsmith-Audio/signalsmith-stretch', false),
    ('nlohmann/json', 'MIT', 'https://github.com/nlohmann/json', false),
    ('yt-dlp', 'Unlicense', 'https://github.com/yt-dlp/yt-dlp', false),
    ('ffmpeg', 'LGPL 2.1+', 'https://ffmpeg.org/legal.html', false),
    ('deno', 'MIT', 'https://github.com/denoland/deno', false),
    ('Flutter, media_kit (libmpv: LGPL 2.1)', 'BSD-3 / MIT', 'https://github.com/media-kit/media-kit', false),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String version;
    try {
      version = context.read<AppServices>().engine.version;
    } catch (_) {
      version = tr('unknown');
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('about.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(tr('app.title'), style: theme.textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text('${tr('about.engineVersion')}: $version', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(tr('about.appLicense')),
          const SizedBox(height: 24),
          Text(tr('about.licenses'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final it in _items)
            ListTile(
              dense: true,
              title: Text(it.$1),
              subtitle: Text(it.$4 ? '${it.$2} (${tr('about.nonCommercial')})' : it.$2),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () => launchUrl(Uri.parse(it.$3)),
            ),
          const SizedBox(height: 16),
          TextButton(onPressed: () => showLicensePage(context: context, applicationName: tr('app.title')), child: const Text('Flutter package licenses')),
        ],
      ),
    );
  }
}
