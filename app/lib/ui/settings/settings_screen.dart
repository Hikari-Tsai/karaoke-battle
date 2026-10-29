// Settings: backend, models, sidecars, audio devices, scoring defaults.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/engine.dart';
import '../../services/backend_manager.dart';
import '../../services/model_registry.dart';
import '../../services/settings.dart';
import '../../services/sidecars.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';
import '../library/add_song_dialog.dart';
import '../startup/first_run_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<Backend, double?>? _bench;
  bool _benchRunning = false;
  bool _calibrating = false;
  String? _calibError;
  bool _cudaInstalled = false;
  bool _cudaBusy = false;
  double _cudaFraction = 0;
  String? _ytUpdateResult;
  List<Map<String, dynamic>> _captureDevices = const [];
  List<Map<String, dynamic>> _playbackDevices = const [];
  String? _deviceError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SetupController>().refresh();
      _refreshDevices();
      _refreshCuda();
    });
  }

  void _refreshDevices() {
    try {
      final d = context.read<AppServices>().engine.audioDevices();
      _captureDevices = ((d['capture'] as List?) ?? const []).cast<Map<String, dynamic>>();
      _playbackDevices = ((d['playback'] as List?) ?? const []).cast<Map<String, dynamic>>();
      _deviceError = null;
    } catch (e) {
      _deviceError = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _refreshCuda() async {
    final v = await context.read<AppServices>().backend.cudaPackInstalled();
    if (mounted) setState(() => _cudaInstalled = v);
  }

  Future<void> _benchmark() async {
    final services = context.read<AppServices>();
    if (!await File(services.swiftF0ModelPath).exists()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('settings.benchmarkNeedsModel'))));
      return;
    }
    setState(() => _benchRunning = true);
    try {
      final r = await services.backend.benchmark(services.swiftF0ModelPath);
      if (mounted) setState(() => _bench = r);
    } finally {
      if (mounted) setState(() => _benchRunning = false);
    }
  }

  Future<void> _calibrate() async {
    final services = context.read<AppServices>();
    final s = services.settings;
    setState(() {
      _calibrating = true;
      _calibError = null;
    });
    try {
      final sec = await LiveAudio.calibrateInBackground(
        services.engine,
        captureDevice: s.captureDeviceId,
        playbackDevice: s.playbackDeviceId,
        sampleRate: s.sampleRate,
      );
      await s.setLatencySeconds(sec);
    } catch (e) {
      _calibError = '$e';
    } finally {
      if (mounted) setState(() => _calibrating = false);
    }
  }

  Future<void> _installCuda() async {
    final backend = context.read<AppServices>().backend;
    setState(() {
      _cudaBusy = true;
      _cudaFraction = 0;
    });
    try {
      await backend.installCudaPack(onProgress: (_, f) {
        if (mounted) setState(() => _cudaFraction = f);
      });
      backend.resetRuntime();
      await backend.detect();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _cudaBusy = false);
      _refreshCuda();
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final settings = context.watch<AppSettings>();
    final backend = context.watch<BackendManager>();
    final theme = Theme.of(context);
    final decision = backend.decision;

    final choices = <BackendChoice>[
      BackendChoice.auto,
      if (Platform.isWindows) ...[BackendChoice.cuda, BackendChoice.directml],
      if (Platform.isMacOS) BackendChoice.coreml,
      BackendChoice.cpu,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(tr('settings.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- UI language -------------------------------------------------------
          _Section(
            title: tr('settings.uiLanguage'),
            children: [
              SegmentedButton<String>(
                segments: [
                  for (final code in I18n.supported) ButtonSegment(value: code, label: Text(I18n.nativeNames[code]!)),
                ],
                selected: {I18n.lang},
                onSelectionChanged: (v) => I18n.lang = v.first,
              ),
            ],
          ),
          // ---- backend --------------------------------------------------------------
          _Section(
            title: tr('settings.backend'),
            trailing: TextButton.icon(onPressed: () => backend.detect(), icon: const Icon(Icons.refresh), label: Text(tr('settings.detect'))),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final c in choices)
                    ChoiceChip(
                      label: Text(c == BackendChoice.auto ? tr('settings.backend.auto') : c.name.toUpperCase()),
                      selected: settings.backend == c,
                      onSelected: (_) async {
                        await settings.setBackend(c);
                        backend.resetRuntime();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text('${tr('settings.backend.active')}: ${backend.active?.name.toUpperCase() ?? '—'}'
                  '${decision != null ? '  (${tr('settings.backend.auto')}: ${decision.recommended.name.toUpperCase()})' : ''}'),
              const SizedBox(height: 6),
              Text(tr('settings.restartNote'), style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              if (decision != null)
                for (final g in decision.gpus)
                  Text('${tr('settings.gpu')}: ${g.name} (${g.vendor})'
                      '${g.vramMb > 0 ? ' · ${tr('settings.vram')} ${g.vramMb} MB' : ''}'
                      '${g.cudaDriverVersion != null ? ' · ${tr('settings.driver')} CUDA ${g.cudaDriverVersion}' : ''}'
                      '${g.computeCapability != null ? ' · CC ${g.computeCapability}' : ''}'),
              if (backend.lastSelftestError != null && backend.lastSelftestError!.isNotEmpty)
                Text(backend.lastSelftestError!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              if (Platform.isWindows) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${tr('settings.cudaPack')}: ${_cudaInstalled ? tr('installed') : tr('notInstalled')}'),
                    const SizedBox(width: 12),
                    if (_cudaBusy)
                      SizedBox(width: 160, child: LinearProgressIndicator(value: _cudaFraction))
                    else if (_cudaInstalled)
                      TextButton(
                          onPressed: () async {
                            await backend.removeCudaPack();
                            backend.resetRuntime();
                            _refreshCuda();
                          },
                          child: Text(tr('remove')))
                    else
                      OutlinedButton(onPressed: _installCuda, child: Text(tr('install'))),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _benchRunning ? null : _benchmark,
                    icon: const Icon(Icons.speed),
                    label: Text(_benchRunning ? tr('settings.benchmarkRunning') : tr('settings.benchmark')),
                  ),
                  const SizedBox(width: 16),
                  if (_bench != null)
                    Expanded(
                      child: Wrap(
                        spacing: 16,
                        children: [
                          for (final e in _bench!.entries) Text('${e.key.name.toUpperCase()}: ${e.value == null ? tr('notAvailable') : '${e.value!.toStringAsFixed(1)} ms'}'),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
          // ---- models ----------------------------------------------------------------
          _Section(
            title: tr('settings.models'),
            trailing: TextButton.icon(onPressed: () => context.read<SetupController>().refresh(), icon: const Icon(Icons.refresh), label: Text(tr('settings.reload'))),
            children: [
              Row(
                children: [
                  Text(tr('settings.gameModel')),
                  const SizedBox(width: 12),
                  SegmentedButton<String>(
                    segments: const [ButtonSegment(value: 'game-large', label: Text('GAME Large')), ButtonSegment(value: 'game-small', label: Text('GAME Small'))],
                    selected: {settings.gameModelId},
                    onSelectionChanged: (v) => settings.setGameModelId(v.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final m in ModelRegistry.all) ModelRow(spec: m, showRemove: true),
            ],
          ),
          // ---- sidecars ---------------------------------------------------------------
          _Section(
            title: tr('settings.sidecars'),
            children: [
              for (final k in SidecarKind.values) SidecarRow(kind: k),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await context.read<SetupController>().updateYtDlp();
                      if (mounted) setState(() => _ytUpdateResult = r);
                    },
                    icon: const Icon(Icons.system_update_alt),
                    label: Text(tr('settings.updateYtDlp')),
                  ),
                  const SizedBox(width: 12),
                  if (_ytUpdateResult != null) Expanded(child: Text(_ytUpdateResult!, style: theme.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ],
          ),
          // ---- audio -----------------------------------------------------------------
          _Section(
            title: tr('settings.audio'),
            trailing: TextButton.icon(onPressed: _refreshDevices, icon: const Icon(Icons.refresh), label: Text(tr('settings.reload'))),
            children: [
              if (_deviceError != null) Text(_deviceError!, style: TextStyle(color: theme.colorScheme.error)),
              _DeviceDropdown(label: tr('settings.captureDevice'), devices: _captureDevices, value: settings.captureDeviceId, onChanged: settings.setCaptureDeviceId),
              const SizedBox(height: 8),
              _DeviceDropdown(label: tr('settings.playbackDevice'), devices: _playbackDevices, value: settings.playbackDeviceId, onChanged: settings.setPlaybackDeviceId),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(tr('settings.sampleRate')),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: settings.sampleRate,
                    items: const [DropdownMenuItem(value: 44100, child: Text('44100 Hz')), DropdownMenuItem(value: 48000, child: Text('48000 Hz'))],
                    onChanged: (v) => v == null ? null : settings.setSampleRate(v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _calibrating ? null : _calibrate,
                    icon: const Icon(Icons.timer_outlined),
                    label: Text(_calibrating ? tr('settings.calibrating') : tr('settings.calibrate')),
                  ),
                  const SizedBox(width: 12),
                  if (_calibrating) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (!_calibrating)
                    Text(settings.latencySeconds == null ? tr('settings.notCalibrated') : '${(settings.latencySeconds! * 1000).toStringAsFixed(0)} ms'),
                ],
              ),
              const SizedBox(height: 6),
              Text(tr('settings.calibrateHint'), style: theme.textTheme.bodySmall),
              if (_calibError != null) Text(_calibError!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(tr('settings.livePitch')),
                  const SizedBox(width: 12),
                  SegmentedButton<int>(
                    segments: [
                      ButtonSegment(value: 0, label: Text(tr('settings.livePitch.dsp'))),
                      ButtonSegment(value: 1, label: Text(tr('settings.livePitch.swiftf0'))),
                      ButtonSegment(value: 2, label: Text(tr('settings.livePitch.both'))),
                    ],
                    selected: {settings.livePitchMode},
                    onSelectionChanged: (v) => settings.setLivePitchMode(v.first),
                  ),
                ],
              ),
            ],
          ),
          // ---- prep / scoring defaults ------------------------------------------------
          _Section(
            title: tr('stage.transcribe'),
            children: [
              Row(
                children: [
                  Text(tr('settings.separation')),
                  const SizedBox(width: 12),
                  SegmentedButton<SeparationQuality>(
                    segments: [
                      ButtonSegment(value: SeparationQuality.fast, label: Text(tr('settings.separation.fast'))),
                      ButtonSegment(value: SeparationQuality.best, label: Text(tr('settings.separation.best'))),
                    ],
                    selected: {settings.separationQuality},
                    onSelectionChanged: (v) => settings.setSeparationQuality(v.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(tr('settings.defaultLanguage')),
                  const SizedBox(width: 12),
                  LanguageDropdown(value: settings.defaultLanguage, onChanged: settings.setDefaultLanguage),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('settings.octaveInvariant')),
                subtitle: Text(tr('settings.octaveInvariantHint')),
                value: settings.octaveInvariant,
                onChanged: settings.setOctaveInvariant,
              ),
            ],
          ),
          // ---- data folder ---------------------------------------------------------------
          _Section(
            title: tr('settings.dataFolder'),
            children: [
              Row(
                children: [
                  Expanded(child: SelectableText(services.paths.root)),
                  TextButton.icon(onPressed: () => revealPath(services.paths.root), icon: const Icon(Icons.folder_open), label: Text(tr('open'))),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.trailing});
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  const _DeviceDropdown({required this.label, required this.devices, required this.value, required this.onChanged});
  final String label;
  final List<Map<String, dynamic>> devices;
  final String? value;
  final Future<void> Function(String?) onChanged;

  @override
  Widget build(BuildContext context) {
    final ids = devices.map((d) => d['id'] as String?).whereType<String>().toSet();
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: value != null && ids.contains(value) ? value : '',
            items: [
              DropdownMenuItem(value: '', child: Text(tr('settings.systemDefault'))),
              for (final d in devices)
                if (d['id'] is String)
                  DropdownMenuItem(value: d['id'] as String, child: Text('${d['name'] ?? d['id']}${d['default'] == true ? ' ★' : ''}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => onChanged(v == null || v.isEmpty ? null : v),
          ),
        ),
      ],
    );
  }
}
