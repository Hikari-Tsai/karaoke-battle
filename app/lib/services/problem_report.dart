// "Report a problem": opens the GitHub issue form with the app version, OS,
// compute backend and graphics card filled in, and from an error message also
// the error and the recent log lines (home folders written as "~"; the rest is
// up to the reporter, see CONTRIBUTING.md). A form URL can carry only so much,
// so when the log does not fit, the full log is saved next to app.log and
// shown in Finder / Explorer for dragging into the issue.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_services.dart';
import '../state/i18n.dart';
import 'app_log.dart';
import 'backend_manager.dart';
import 'update_checker.dart';

/// The bug-report form (`.github/ISSUE_TEMPLATE/bug_report.yml`); query
/// parameters named after the form's field ids pre-fill those fields.
Uri problemReportUri({String? version, String? os, String? backend, String? gpu, String? error, String? logs}) =>
    Uri.parse('${UpdateChecker.repoUrl}/issues/new').replace(queryParameters: {
      'template': 'bug_report.yml',
      if (version != null && version.isNotEmpty) 'version': version,
      if (os != null && os.isNotEmpty) 'os': os,
      if (backend != null && backend.isNotEmpty) 'backend': backend,
      if (gpu != null && gpu.isNotEmpty) 'gpu': gpu,
      if (error != null && error.isNotEmpty) 'error': error,
      if (logs != null && logs.isNotEmpty) 'logs': logs,
    });

/// Longest form URL we open. Signed out, GitHub first redirects to the
/// sign-in page with the whole URL in it, and that fails (HTTP 500) from
/// about 6900 characters, or about 5400 when the text is mostly Chinese or
/// Japanese (measured 2026-11).
const maxReportUrlLength = 5000;

/// The error may use at most this much of [maxReportUrlLength]; the log
/// gets the rest.
const maxReportErrorUrlLength = 2500;

/// Longest error message put in the form.
const maxReportErrorChars = 1500;

/// [text] cut (with "…") until [urlWith] of it is at most [maxUrl] long.
String shortenToFit(String text, Uri Function(String text) urlWith, {int maxUrl = maxReportErrorUrlLength}) {
  if (urlWith(text).toString().length <= maxUrl) return text;
  var lo = 0, hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (urlWith('${text.substring(0, mid)}…').toString().length <= maxUrl) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return '${text.substring(0, lo)}…';
}

/// The last of [lines] that fit in the form next to [base] (a URL without
/// logs) within [maxUrl] characters, oldest first. [note] (when given) goes on
/// the first line whenever some lines had to be left out.
({String text, int kept}) fitReportLogs(Uri base, List<String> lines, {int maxUrl = maxReportUrlLength, String? Function(int kept)? note}) {
  int urlLength(String logs) => base.replace(queryParameters: {...base.queryParameters, 'logs': logs}).toString().length;
  if (lines.isEmpty) return (text: '', kept: 0);
  final all = lines.join('\n');
  if (urlLength(all) <= maxUrl) return (text: all, kept: lines.length);
  // Binary search on how many trailing lines fit, with the note in front.
  String build(int n) {
    final tail = lines.sublist(lines.length - n).join('\n');
    final head = note?.call(n);
    return head == null ? tail : '$head\n$tail';
  }

  var lo = 0, hi = lines.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (urlLength(build(mid)) <= maxUrl) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return (text: lo == 0 ? (note?.call(0) ?? '') : build(lo), kept: lo);
}

/// [error] for the form: home folders as "~", at most [maxReportErrorChars].
String reportErrorText(Object error) {
  final s = AppLog.redact('$error').trim();
  return s.length <= maxReportErrorChars ? s : '${s.substring(0, maxReportErrorChars)}…';
}

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

/// Opens the form. From an error message pass [error]: the form then also
/// gets the error and the recent log.
Future<void> openProblemReport(BuildContext context, {Object? error}) async {
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
  if (error == null) {
    await launchUrl(problemReportUri(version: version, os: os, backend: backend, gpu: gpu));
    return;
  }
  Uri withError(String e) => problemReportUri(version: version, os: os, backend: backend, gpu: gpu, error: e);
  final base = withError(shortenToFit(reportErrorText(error), withError));
  final snapshot = await AppLog.writeSnapshot();
  final lines = AppLog.recent;
  final fit = fitReportLogs(
    base,
    lines,
    note: snapshot == null ? null : (n) => tr('report.logTrimmed', {'n': '$n', 'file': AppLog.redact(snapshot)}),
  );
  await launchUrl(fit.text.isEmpty ? base : base.replace(queryParameters: {...base.queryParameters, 'logs': fit.text}));
  // The rest of the log did not fit: show the saved copy to drag in.
  if (fit.kept < lines.length && snapshot != null) {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', snapshot]);
      } else {
        await revealPath(snapshot);
      }
    } catch (_) {}
  }
}
