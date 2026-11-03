// Main shell: NavigationRail + pages, runs the startup flow once. Until the
// launch check finds every required model and tool, the setup gate is shown
// instead of the app.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/problem_report.dart';
import '../state/app_services.dart';
import '../state/i18n.dart';
import '../state/setup_controller.dart';
import 'about/about_screen.dart';
import 'charts/charts_screen.dart';
import 'rules/rules_screen.dart';
import 'library/library_screen.dart';
import 'replays/replays_screen.dart';
import 'settings/settings_screen.dart';
import 'startup/backend_dialog.dart';
import 'startup/setup_gate.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Static so a language change (which remounts the shell) keeps the current
  // tab and does not show the startup dialogs again.
  static int _lastIndex = 0;
  static bool _startupDoneGlobal = false;
  static bool _readyGlobal = false;
  static const _chartsIndex = 2;
  int _index = _lastIndex;
  bool _checking = !_readyGlobal;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    if (_startupDoneGlobal) return;
    _startupDoneGlobal = true;
    final services = context.read<AppServices>();
    try {
      final decision = await services.backend.detect();
      if (!mounted) return;
      await showBackendDialog(context, services, decision);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('settings.backend')}: $e')));
    }
    if (!mounted) return;
    final setup = context.read<SetupController>();
    try {
      await setup.verifyRequired();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (setup.ready) _readyGlobal = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_readyGlobal) {
      return SetupGate(checking: _checking, onContinue: () => setState(() => _readyGlobal = true));
    }
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = _lastIndex = i),
            labelType: NavigationRailLabelType.all,
            leading: const SizedBox(height: 8),
            // Always in reach, so a streamer can report a problem mid-stream.
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tooltip(
                    message: tr('nav.report'),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => openProblemReport(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.bug_report_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(height: 4),
                          Text(tr('nav.report'), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            destinations: [
              NavigationRailDestination(icon: const Icon(Icons.library_music_outlined), selectedIcon: const Icon(Icons.library_music), label: Text(tr('nav.library'))),
              NavigationRailDestination(icon: const Icon(Icons.ondemand_video_outlined), selectedIcon: const Icon(Icons.ondemand_video), label: Text(tr('nav.replays'))),
              NavigationRailDestination(icon: const Icon(Icons.leaderboard_outlined), selectedIcon: const Icon(Icons.leaderboard), label: Text(tr('nav.charts'))),
              NavigationRailDestination(icon: const Icon(Icons.emoji_events_outlined), selectedIcon: const Icon(Icons.emoji_events), label: Text(tr('nav.rules'))),
              NavigationRailDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: Text(tr('nav.settings'))),
              NavigationRailDestination(icon: const Icon(Icons.info_outline), selectedIcon: const Icon(Icons.info), label: Text(tr('nav.about'))),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                const LibraryScreen(),
                const ReplaysScreen(),
                ChartsScreen(active: _index == _chartsIndex),
                const RulesScreen(),
                const SettingsScreen(),
                const AboutScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
