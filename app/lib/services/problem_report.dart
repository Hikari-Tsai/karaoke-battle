// "Report a problem": opens the GitHub issue form with the app version, OS,
// compute backend and graphics card filled in (nothing personal; the rest is
// up to the reporter, see CONTRIBUTING.md).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_services.dart';
import 'backend_manager.dart';
import 'update_checker.dart';

/// The bug-report form (`.github/ISSUE_TEMPLATE/bug_report.yml`); query
/// parameters named after the form's field ids pre-fill those fields.
Uri problemReportUri({String? version, String? os, String? backend, String? gpu}) => Uri.parse('${UpdateChecker.repoUrl}/issues/new').replace(queryParameters: {
      'template': 'bug_report.yml',
      if (version != null && version.isNotEmpty) 'version': version,
      if (os != null && os.isNotEmpty) 'os': os,
      if (backend != null && backend.isNotEmpty) 'backend': backend,
      if (gpu != null && gpu.isNotEmpty) 'gpu': gpu,
    });

/// The graphics cards for the report, e.g. "NVIDIA GeForce RTX 3060 (12 GB,
/// CUDA 12.8)"; software adapters are left out. Null when there is none.
String? gpuSummary(List<GpuInfo> gpus) {
  final parts = <String>[];
  for (final g in gpus) {
    if (g.isSoftware) continue;
    final details = <String>[
      if (g.vramMb > 0) g.vramMb >= 1024 ? '${(g.vramMb / 1024).round()} GB' : '${g.vramMb} MB',
      if (g.cudaDriverVersion case final v? when v > 0) 'CUDA ${v ~/ 1000}.${(v % 1000) ~/ 10}',
    ];
    parts.add(details.isEmpty ? g.name : '${g.name} (${details.join(', ')})');
  }
  return parts.isEmpty ? null : parts.join(' / ');
}

Future<void> openProblemReport(BuildContext context) async {
  String? backend;
  String? gpu;
  try {
    final b = context.read<AppServices>().backend;
    backend = b.active?.name.toUpperCase();
    gpu = gpuSummary(b.decision?.gpus ?? b.engine.gpuInfo().map(GpuInfo.new).toList());
  } catch (_) {}
  String? version;
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  final os = '${Platform.isMacOS ? 'macOS' : Platform.isWindows ? 'Windows' : Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  await launchUrl(problemReportUri(version: version, os: os, backend: backend, gpu: gpu));
}
