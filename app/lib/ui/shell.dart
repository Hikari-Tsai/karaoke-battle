// Main shell: NavigationRail + pages, runs the startup flow once.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_services.dart';
import '../state/i18n.dart';
import 'about/about_screen.dart';
import 'rules/rules_screen.dart';
import 'library/library_screen.dart';
import 'settings/settings_screen.dart';
import 'startup/backend_dialog.dart';
import 'startup/first_run_dialog.dart';

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
  int _index = _lastIndex;

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
    await showFirstRunDialogIfNeeded(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = _lastIndex = i),
            labelType: NavigationRailLabelType.all,
            leading: const _BrandMark(),
            destinations: [
              NavigationRailDestination(icon: const Icon(Icons.library_music_outlined), selectedIcon: const Icon(Icons.library_music), label: Text(tr('nav.library'))),
              NavigationRailDestination(icon: const Icon(Icons.emoji_events_outlined), selectedIcon: const Icon(Icons.emoji_events), label: Text(tr('nav.rules'))),
              NavigationRailDestination(icon: const Icon(Icons.settings_outlined), selectedIcon: const Icon(Icons.settings), label: Text(tr('nav.settings'))),
              NavigationRailDestination(icon: const Icon(Icons.info_outline), selectedIcon: const Icon(Icons.info), label: Text(tr('nav.about'))),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [LibraryScreen(), RulesScreen(), SettingsScreen(), AboutScreen()],
            ),
          ),
        ],
      ),
    );
  }
}

/// App logo at the top of the navigation rail: the full-colour app icon and
/// the name, separated from the destinations so it does not read as a button.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: theme.colorScheme.primary.withValues(alpha: 0.35), blurRadius: 12)],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/images/app_icon.png', width: 48, height: 48, filterQuality: FilterQuality.medium),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Karaoke\nBattle',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.1, letterSpacing: 0.3),
          ),
          const SizedBox(height: 10),
          SizedBox(width: 48, child: Divider(height: 1, color: theme.colorScheme.outlineVariant)),
        ],
      ),
    );
  }
}
