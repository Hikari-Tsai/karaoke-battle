// About: author, version, download link, update check and license summary.
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_checker.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/brand.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

enum _UpdateState { idle, checking, upToDate, available, failed }

class _AboutScreenState extends State<AboutScreen> {
  static const _items = <(String, String, String, bool)>[
    // name, license, url, nonCommercial
    ('Karaoke Battle', 'MIT', UpdateChecker.repoUrl, false),
    ('GAME 1.0 Small / Large — Team OpenVPI (openvpi/GAME v1.0.3, unmodified)', 'CC BY-NC-SA 4.0', 'https://github.com/openvpi/GAME/releases/tag/v1.0.3', true),
    ('UVR-MDX-NET-Inst_HQ_4 — trained by UVR (Anjok07 & aufr33); MDX-Net architecture: kuielab', 'MIT', 'https://github.com/Anjok07/ultimatevocalremovergui', false),
    ('Kim_Vocal_2 — trained by KimberleyJensen (distributed via UVR)', 'Author permission statement (no license file)', 'https://github.com/KimberleyJensen/kmdx-net_music-source-separation/issues/3', false),
    ('python-audio-separator (MDX pipeline port)', 'MIT', 'https://github.com/nomadkaraoke/python-audio-separator', false),
    ('SwiftF0 — Lars Nieradzik (arXiv:2508.18440)', 'MIT', 'https://github.com/lars76/swift-f0', false),
    ('mir_eval (scoring metric definitions) — Raffel et al., ISMIR 2014', 'MIT', 'https://github.com/mir-evaluation/mir_eval', false),
    ('Beat This! — Foscarin, Schlüter, Widmer (CPJKU), ISMIR 2024 (beats / tempo)', 'MIT', 'https://github.com/CPJKU/beat_this', false),
    ('kuromoji.js — Takuya Asano / Atilika (Japanese readings for romaji)', 'Apache-2.0', 'https://github.com/takuyaa/kuromoji.js', false),
    ('mecab-ipadic — Nara Institute of Science and Technology (NAIST)', 'NAIST / ICOT terms', 'https://huggingface.co/aaatmy/kuromoji-ipadic-pack', false),
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

  String _appVersion = '';
  _UpdateState _state = _UpdateState.idle;
  ReleaseInfo? _latest;
  String _error = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _appVersion = info.version);
      _check();
    });
  }

  Future<void> _check() async {
    if (_state == _UpdateState.checking) return;
    setState(() => _state = _UpdateState.checking);
    try {
      final latest = await UpdateChecker.fetchLatest();
      if (!mounted) return;
      setState(() {
        _latest = latest;
        _state = UpdateChecker.isNewer(latest.version, _appVersion) ? _UpdateState.available : _UpdateState.upToDate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _state = _UpdateState.failed;
      });
    }
  }

  Widget _updateStatus(ThemeData theme) {
    final cs = theme.colorScheme;
    switch (_state) {
      case _UpdateState.idle:
        return const SizedBox.shrink();
      case _UpdateState.checking:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(tr('about.checking')),
        ]);
      case _UpdateState.upToDate:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(tr('about.upToDate', {'version': _latest?.tag ?? ''})),
        ]);
      case _UpdateState.available:
        final l = _latest!;
        return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
          Icon(Icons.new_releases, size: 16, color: cs.tertiary),
          Text(tr('about.newVersion', {'version': l.tag}), style: TextStyle(color: cs.tertiary, fontWeight: FontWeight.w600)),
          FilledButton.tonalIcon(
            onPressed: () => launchUrl(Uri.parse(l.url)),
            icon: const Icon(Icons.download, size: 16),
            label: Text(tr('about.downloadVersion', {'version': l.tag})),
          ),
        ]);
      case _UpdateState.failed:
        return Text('${tr('about.checkFailed')}: $_error', style: TextStyle(color: cs.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String engineVersion;
    try {
      engineVersion = context.read<AppServices>().engine.version;
    } catch (_) {
      engineVersion = tr('unknown');
    }
    return Scaffold(
      appBar: AppBar(title: BrandedTitle(tr('about.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(tr('app.title'), style: theme.textTheme.headlineMedium),
          const SizedBox(height: 4),
          Text('${tr('about.version')}: ${_appVersion.isEmpty ? tr('unknown') : _appVersion}    ${tr('about.engineVersion')}: $engineVersion', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(children: [
            Text('${tr('about.author')}: '),
            InkWell(
              onTap: () => launchUrl(Uri.parse('https://github.com/Hikari-Tsai')),
              child: Text('Hikari Tsai (Hikari-Tsai)', style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(tr('about.appLicense')),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.icon(
              onPressed: () => launchUrl(Uri.parse(UpdateChecker.releasesUrl)),
              icon: const Icon(Icons.download),
              label: Text(tr('about.download')),
            ),
            OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(UpdateChecker.repoUrl)),
              icon: const Icon(Icons.code),
              label: Text(tr('about.repo')),
            ),
            OutlinedButton.icon(
              onPressed: _state == _UpdateState.checking ? null : _check,
              icon: const Icon(Icons.system_update_alt),
              label: Text(tr('about.checkUpdate')),
            ),
            _updateStatus(theme),
          ]),
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
          TextButton(
            onPressed: () => launchUrl(Uri.parse('${UpdateChecker.repoUrl}/blob/main/docs/CITATIONS.md')),
            child: Text(tr('about.citations')),
          ),
          TextButton(onPressed: () => showLicensePage(context: context, applicationName: tr('app.title')), child: const Text('Flutter package licenses')),
        ],
      ),
    );
  }
}
