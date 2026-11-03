// "Report a problem": opens the GitHub issue form with the app version, OS
// and compute backend filled in (nothing personal; the rest is up to the
// reporter, see CONTRIBUTING.md).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_services.dart';
import 'update_checker.dart';

/// The bug-report form (`.github/ISSUE_TEMPLATE/bug_report.yml`); query
/// parameters named after the form's field ids pre-fill those fields.
Uri problemReportUri({String? version, String? os, String? backend}) => Uri.parse('${UpdateChecker.repoUrl}/issues/new').replace(queryParameters: {
      'template': 'bug_report.yml',
      if (version != null && version.isNotEmpty) 'version': version,
      if (os != null && os.isNotEmpty) 'os': os,
      if (backend != null && backend.isNotEmpty) 'backend': backend,
    });

Future<void> openProblemReport(BuildContext context) async {
  String? backend;
  try {
    backend = context.read<AppServices>().backend.active?.name.toUpperCase();
  } catch (_) {}
  String? version;
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  final os = '${Platform.isMacOS ? 'macOS' : Platform.isWindows ? 'Windows' : Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  await launchUrl(problemReportUri(version: version, os: os, backend: backend));
}
