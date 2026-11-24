// Settings: backend, models, sidecars, audio devices, scoring defaults.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai_settings_dialog.dart';
import '../../services/app_log.dart';
import '../../services/app_paths.dart';
import '../../services/backend_manager.dart';
import '../../services/model_registry.dart';
import '../../services/settings.dart';
import '../../services/sidecars.dart';
import '../../state/song_data.dart' show noteName;
import 'move_guide_dialog.dart';
import 'range_detect_dialog.dart';
import '../../services/update_checker.dart';
import '../widgets/release_notes.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';
import '../library/add_song_dialog.dart';
import '../widgets/calibration.dart';
import '../../state/loudness.dart';
import '../widgets/info_tip.dart';
import 'setting_row.dart';
import '../results/score_reveal.dart' show ResultSfx;
import '../startup/setup_rows.dart';
import '../startup/ytdlp_dialog.dart';
import '../widgets/brand.dart';
import '../widgets/voice_fx.dart';
import '../widgets/error_report.dart';
import '../widgets/app_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<Backend, double?>? _bench;
  bool _benchRunning = false;
  bool _calibrating = false;
  double? _latencyDraft; // while the latency slider is dragged
  String? _calibError;
  String? _calibDetails;

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

  /// Changes the data folder: [target] null asks the user for a folder.
  /// Offers to move the existing data, writes the location pointer and asks
  /// for a restart (engine, models and services are bound to the old path).
  Future<void> _changeDataFolder(String? target, {bool reset = false}) async {
    final services = context.read<AppServices>();
    final paths = services.paths;
    if (services.pipeline.isBusy) {
      _snack(tr('folder.busy'));
      return;
    }
    String? dest = target;
    if (dest == null) {
      final String? picked;
      try {
        picked = await FilePicker.getDirectoryPath(dialogTitle: tr('folder.pickTitle'));
      } catch (e, st) {
        if (mounted) showErrorSnack(context, e, stack: st, where: 'pick folder');
        return;
      }
      if (picked == null || !mounted) return;
      dest = await DataLocation.resolveTarget(picked);
    }
    final sameFolder = p.equals(paths.root, dest);
    if (!(reset && sameFolder) && DataLocation.problem(paths.root, dest) != null) {
      _snack(tr('folder.bad'));
      return;
    }
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AppDialog(
        title: Text(tr('folder.confirmTitle')),
        content: Text(tr('folder.confirmBody', {'path': dest})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, 'switch'), child: Text(tr('folder.useEmpty'))),
          FilledButton(onPressed: () => Navigator.pop(c, 'move'), child: Text(tr('folder.move'))),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final progress = ValueNotifier<double>(0);
    Future<void> pointAtTarget() => reset ? DataLocation.clear(paths.defaultRoot) : DataLocation.write(paths.defaultRoot, dest!);
    var leftovers = false;
    if (choice == 'move' && !sameFolder) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        // Files are being moved: this cannot be cancelled.
        builder: (c) => AppDialog(
          canClose: false,
          title: Text(tr('folder.moving')),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, v, _) => SizedBox(width: 320, child: LinearProgressIndicator(value: v > 0 && v < 1 ? v : null)),
          ),
        ),
      );
      // The open log would stop Windows from moving or deleting the folder.
      await AppLog.close();
      try {
        leftovers = !await DataLocation.move(
          paths.root,
          dest,
          defaultRoot: paths.defaultRoot,
          onProgress: (v) => progress.value = v,
          // Written as soon as the copy is complete, before the source is
          // removed: the app then never points at a half-deleted folder.
          onCopied: pointAtTarget,
        );
      } catch (e, st) {
        await AppLog.init(paths.logs);
        if (mounted) Navigator.of(context).pop();
        if (e is StateError && '$e'.contains('not empty')) {
          _snack(tr('folder.notEmpty'));
        } else if (mounted) {
          showErrorSnack(context, e, stack: st, where: 'move data folder');
        }
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } else {
      await Directory(dest).create(recursive: true);
      await pointAtTarget(); // reset: back to KE_APP_SUPPORT / platform default
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      // The data folder has changed: the app must restart.
      builder: (c) => AppDialog(
        canClose: false,
        title: Text(tr('folder.restartTitle')),
        content: SelectableText('${tr('folder.restartBody', {'path': dest})}${leftovers ? '\n\n${tr('folder.leftovers')}' : ''}'),
        actions: [FilledButton(onPressed: () => exit(0), child: Text(tr('folder.quit')))],
      ),
    );
  }

  void _snack(String msg) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _setLatency(double seconds) async {
    final ms = (seconds * 1000).round().clamp(0, (AppSettings.maxLatencySeconds * 1000).round());
    await context.read<AppServices>().settings.setLatencySeconds(ms / 1000);
    if (mounted) setState(() => _latencyDraft = null);
  }

  Future<void> _calibrate() async {
    final services = context.read<AppServices>();
    setState(() {
      _calibrating = true;
      _calibError = null;
      _calibDetails = null;
    });
    try {
      await runCalibration(services);
    } catch (e) {
      _calibError = calibrationAdvice(e);
      _calibDetails = '$e';
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
      appBar: AppBar(title: BrandedTitle(tr('settings.title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- new version (the rail's Settings icon shows a bubble meanwhile) ----
          ValueListenableBuilder(
            valueListenable: UpdateChecker.available,
            builder: (context, release, _) => release == null
                ? const SizedBox.shrink()
                : Card(
                    color: theme.colorScheme.tertiaryContainer,
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(Icons.new_releases, color: theme.colorScheme.onTertiaryContainer),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              tr('about.newVersion', {'version': release.tag}),
                              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer, fontWeight: FontWeight.w600),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: () => launchUrl(Uri.parse(release.url)),
                            icon: const Icon(Icons.download),
                            label: Text(tr('about.downloadVersion', {'version': release.tag})),
                          ),
                        ]),
                        Padding(
                          padding: const EdgeInsets.only(left: 36, top: 8),
                          child: ReleaseNotesView(release: release, color: theme.colorScheme.onTertiaryContainer),
                        ),
                      ]),
                    ),
                  ),
          ),
          // ---- UI language -------------------------------------------------------
          _Section(
            title: tr('settings.uiLanguage'),
            children: [
              // Sections stretch their children; keep this one its own width.
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<String>(
                  segments: [
                    for (final code in I18n.supported) ButtonSegment(value: code, label: Text(I18n.nativeNames[code]!)),
                  ],
                  selected: {I18n.lang},
                  onSelectionChanged: (v) => I18n.lang = v.first,
                ),
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
                  const SizedBox(width: 4),
                  Tooltip(
                    richMessage: TextSpan(children: [
                      TextSpan(text: 'GAME Large\n', style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: '${tr('settings.gameLargeInfo')}\n\n'),
                      TextSpan(text: 'GAME Small\n', style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: tr('settings.gameSmallInfo')),
                    ]),
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(maxWidth: 380),
                    waitDuration: const Duration(milliseconds: 200),
                    showDuration: const Duration(seconds: 20),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.help,
                      child: Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
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
                    onPressed: context.watch<SetupController>().ytDlpBusy
                        ? null
                        : () async {
                            final r = await context.read<SetupController>().updateYtDlp();
                            if (!context.mounted) return;
                            setState(() => _ytUpdateResult = r.message);
                            if (!r.ok) await showYtDlpDialog(context, YtDlpIssue.failed, r.message);
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
              _DeviceDropdown(label: tr('settings.playbackDevice'), devices: _playbackDevices, value: settings.playbackDeviceId, onChanged: settings.setPlaybackDeviceId),
              SettingRow(
                title: tr('settings.sampleRate'),
                trailing: SizedBox(
                  width: SettingRow.controlWidth,
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: settings.sampleRate,
                    items: const [DropdownMenuItem(value: 44100, child: Text('44100 Hz')), DropdownMenuItem(value: 48000, child: Text('48000 Hz'))],
                    onChanged: (v) => v == null ? null : settings.setSampleRate(v),
                  ),
                ),
              ),
              // What the automatic volume on the sing screen aims for.
              SettingRow(
                title: tr('settings.targetLufs'),
                info: InfoTip(sections: [(tr('settings.targetLufs'), tr('settings.targetLufsInfo'))]),
                subtitle: tr('settings.targetLufsHint'),
                trailing: SliderControl(
                  slider: Slider(
                    min: AppSettings.targetLufsMin,
                    max: AppSettings.targetLufsMax,
                    divisions: ((AppSettings.targetLufsMax - AppSettings.targetLufsMin) * 2).round(),
                    value: settings.targetLufs,
                    label: '${lufsLabel(settings.targetLufs)} LUFS',
                    onChanged: settings.setTargetLufs,
                  ),
                  value: '${lufsLabel(settings.targetLufs)} LUFS',
                  trailing: IconButton(
                    tooltip: tr('settings.targetLufsReset'),
                    visualDensity: VisualDensity.compact,
                    onPressed: settings.targetLufs == AppSettings.targetLufsDefault ? null : () => settings.setTargetLufs(AppSettings.targetLufsDefault),
                    icon: const Icon(Icons.restart_alt, size: 18),
                  ),
                ),
              ),
              SettingRow(
                title: tr('settings.latency'),
                subtitle: tr('settings.calibrateHint'),
                trailing: SizedBox(
                  width: SettingRow.controlWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_calibrating) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      if (!_calibrating)
                        Text(settings.latencySeconds == null ? tr('settings.notCalibrated') : '${(settings.latencySeconds! * 1000).toStringAsFixed(0)} ms',
                            style: theme.textTheme.titleSmall),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _calibrating ? null : _calibrate,
                        icon: const Icon(Icons.timer_outlined, size: 18),
                        label: Text(_calibrating ? tr('settings.calibrating') : tr('settings.calibrate')),
                      ),
                    ],
                  ),
                ),
              ),
              SettingRow(
                title: tr('settings.latencyManual'),
                subtitle: tr('settings.latencyManualHint'),
                trailing: SliderControl(
                  leading: IconButton(
                    tooltip: '-1 ms',
                    visualDensity: VisualDensity.compact,
                    onPressed: _calibrating ? null : () => _setLatency((_latencyDraft ?? settings.latencySeconds ?? 0) - 0.001),
                    icon: const Icon(Icons.remove, size: 18),
                  ),
                  slider: Slider(
                    value: ((_latencyDraft ?? settings.latencySeconds ?? 0) * 1000).clamp(0, AppSettings.maxLatencySeconds * 1000).toDouble(),
                    max: AppSettings.maxLatencySeconds * 1000,
                    divisions: (AppSettings.maxLatencySeconds * 1000).round(),
                    label: '${((_latencyDraft ?? settings.latencySeconds ?? 0) * 1000).round()} ms',
                    onChanged: _calibrating ? null : (v) => setState(() => _latencyDraft = v / 1000),
                    onChangeEnd: (v) => _setLatency(v / 1000),
                  ),
                  value: '${((_latencyDraft ?? settings.latencySeconds ?? 0) * 1000).round()} ms',
                  trailing: IconButton(
                    tooltip: '+1 ms',
                    visualDensity: VisualDensity.compact,
                    onPressed: _calibrating ? null : () => _setLatency((_latencyDraft ?? settings.latencySeconds ?? 0) + 0.001),
                    icon: const Icon(Icons.add, size: 18),
                  ),
                ),
              ),
              if (_calibError != null) ...[
                const SizedBox(height: 8),
                CalibrationErrorPanel(advice: _calibError!, details: _calibDetails),
              ],
              SettingRow(
                title: tr('settings.livePitch'),
                info: InfoTip(
                  sections: [
                    (tr('settings.livePitch.dsp'), tr('info.livePitch.dsp')),
                    (tr('settings.livePitch.swiftf0'), tr('info.livePitch.swiftf0')),
                  ],
                  footer: tr('info.livePitch.footer'),
                ),
                trailing: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 0, label: Text(tr('settings.livePitch.dsp'))),
                    ButtonSegment(value: 1, label: Text(tr('settings.livePitch.swiftf0'))),
                  ],
                  selected: {settings.livePitchMode},
                  onSelectionChanged: (v) => settings.setLivePitchMode(v.first),
                ),
              ),
              SettingRow(
                title: tr('settings.liveJudgePitch'),
                info: InfoTip(
                  sections: [
                    (tr('settings.liveJudgePitch.off'), tr('info.liveJudgePitch.off')),
                    (tr('settings.liveJudgePitch.on'), tr('info.liveJudgePitch.on')),
                  ],
                  footer: tr('info.liveJudgePitch.footer'),
                ),
                trailing: Switch(value: settings.liveJudgePitch, onChanged: settings.setLiveJudgePitch),
              ),
              // The singer's range, shared by every song: reset, or detect it
              // again here (the sing screen also adds to it before a take).
              Builder(builder: (context) {
                final keys = settings.ownRangeKeys;
                final text = keys.isEmpty
                    ? tr('ownRange.none')
                    : '${noteName(keys.reduce((a, b) => a < b ? a : b).toDouble())}–${noteName(keys.reduce((a, b) => a > b ? a : b).toDouble())}';
                return SettingRow(
                  title: tr('ownRange.title'),
                  info: InfoTip(sections: [(tr('ownRange.title'), tr('ownRange.info'))]),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(text, style: theme.textTheme.titleSmall),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => showRangeDetectDialog(context),
                        icon: const Icon(Icons.mic, size: 18),
                        label: Text(tr('ownRange.detect')),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: keys.isEmpty ? null : () => settings.setOwnRangeKeys(const {}),
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: Text(tr('ownRange.reset')),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
          _Section(
            title: tr('voiceFx.section'),
            children: const [VoiceFxSettings()],
          ),
          // ---- prep / scoring defaults ------------------------------------------------
          _Section(
            title: tr('stage.transcribe'),
            children: [
              Row(
                children: [
                  Text(tr('settings.separation')),
                  InfoTip(
                    sections: [
                      (tr('settings.separation.fast'), tr('info.separation.fast')),
                      (tr('settings.separation.best'), tr('info.separation.best')),
                    ],
                    footer: tr('info.separation.footer'),
                  ),
                  const SizedBox(width: 8),
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
              SettingRow(
                title: tr('settings.noiseGate'),
                subtitle: tr('sing.gateHint'),
                trailing: SliderControl(
                  slider: Slider(
                    min: AppSettings.noiseGateOff,
                    max: AppSettings.noiseGateMax,
                    divisions: 40,
                    value: settings.noiseGateDb,
                    onChanged: settings.setNoiseGateDb,
                  ),
                  value: settings.noiseGateEnabled ? '${settings.noiseGateDb.round()} dB' : tr('sing.gateOff'),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('settings.octaveInvariant')),
                subtitle: Text(tr('settings.octaveInvariantHint')),
                value: settings.octaveInvariant,
                onChanged: settings.setOctaveInvariant,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('settings.wideKeyRange')),
                subtitle: Text(tr('settings.wideKeyRangeHint')),
                value: settings.wideKeyRange,
                onChanged: settings.setWideKeyRange,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('settings.resultSounds')),
                subtitle: Text(tr('settings.resultSoundsHint')),
                value: settings.resultSounds,
                onChanged: settings.setResultSounds,
              ),
              SettingRow(
                title: tr('settings.sfxVolume'),
                subtitle: tr('settings.sfxVolumeHint'),
                trailing: SliderControl(
                  slider: Slider(
                    divisions: 20,
                    value: settings.sfxVolume,
                    label: '${(settings.sfxVolume * 100).round()}%',
                    onChanged: settings.resultSounds ? settings.setSfxVolume : null,
                    // Hear the level just set.
                    onChangeEnd: (_) => ResultSfx.once(settings, 'item'),
                  ),
                  value: '${(settings.sfxVolume * 100).round()}%',
                ),
              ),
              // The same setting as the camera button on the sing screen.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('settings.showVideo')),
                subtitle: Text(tr('settings.showVideoHint')),
                value: settings.showVideo,
                onChanged: settings.setShowVideo,
              ),
            ],
          ),
          // ---- AI singing tips: service and API key ----------------------------------------
          _Section(
            title: tr('ai.section'),
            children: const [AiSettingsSummary()],
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
              const SizedBox(height: 4),
              Text(
                switch (services.paths.source) {
                  DataRootSource.setting => tr('folder.sourceSetting'),
                  DataRootSource.environment => tr('folder.sourceEnv'),
                  DataRootSource.platformDefault => tr('folder.sourceDefault'),
                },
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 4),
              Text(tr('folder.hint'), style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                OutlinedButton.icon(onPressed: () => _changeDataFolder(null), icon: const Icon(Icons.drive_file_move_outline), label: Text(tr('folder.change'))),
                // How to take everything to a new computer.
                OutlinedButton.icon(onPressed: () => showMoveGuide(context), icon: const Icon(Icons.devices_other), label: Text(tr('move.button'))),
                if (services.paths.source == DataRootSource.setting)
                  TextButton(
                    onPressed: () => _changeDataFolder(services.paths.fallbackRoot, reset: true),
                    child: Text(services.paths.envRoot != null ? tr('folder.resetEnv') : tr('folder.resetDefault')),
                  ),
              ]),
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
    return SettingRow(
      title: label,
      trailing: SizedBox(
        width: SettingRow.controlWidth,
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
    );
  }
}
