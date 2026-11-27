// Main shell: NavigationRail + pages, runs the startup flow once. Until the
// launch check finds every required model and tool, the setup gate is shown
// instead of the app.
import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/problem_report.dart';
import '../services/settings.dart';
import '../services/song_library.dart';
import '../services/update_checker.dart';
import '../state/app_services.dart';
import '../state/i18n.dart';
import '../state/setup_controller.dart';
import 'about/about_screen.dart';
import 'charts/charts_screen.dart';
import 'history/history_screen.dart';
import 'live/cheer_celebration.dart';
import 'rules/rules_screen.dart';
import 'library/library_screen.dart';
import 'profile/profile_screen.dart';
import 'profile/item_celebration.dart';
import 'profile/achievements_view.dart';
import 'profile/singing_avatar.dart';
import 'lyrics/no_lyrics_dialog.dart';
import 'replays/replays_screen.dart';
import 'settings/settings_screen.dart';
import 'startup/backend_dialog.dart';
import 'startup/setup_gate.dart';
import 'startup/ytdlp_dialog.dart';
import 'widgets/achievement_events.dart';
import 'widgets/speech_bubble.dart';
import '../state/stream_privacy.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Lets a page switch tabs, e.g. the rules page to the replays after
  /// saving a demo replay.
  static final tabRequest = ValueNotifier<int?>(null);
  static const replaysIndex = 2;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // Static so a language change (which remounts the shell) keeps the current
  // tab and does not show the startup dialogs again.
  static int _lastIndex = 0;
  static bool _startupDoneGlobal = false;
  static bool _readyGlobal = false;
  static const _historyIndex = 1;
  static const _chartsIndex = 3;
  static const _aboutIndex = 7; // at the bottom of the rail, with the links
  static const _profileIndex = 8; // the avatar at the top of the rail
  int _index = _lastIndex;
  bool _checking = !_readyGlobal;

  // Songs whose preparation found no lyrics, asked about one at a time.
  static final List<Song> _noLyricsQueue = [];
  StreamSubscription<Song>? _noLyricsSub;
  Timer? _noLyricsRetry;
  bool _askingLyrics = false;

  @override
  void initState() {
    super.initState();
    _noLyricsSub = context.read<AppServices>().pipeline.noLyrics.listen((song) {
      _noLyricsQueue.add(song);
      _askNoLyrics();
    });
    AppShell.tabRequest.addListener(_onTabRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
    if (_noLyricsQueue.isNotEmpty) _askNoLyrics();
  }

  @override
  void dispose() {
    AppShell.tabRequest.removeListener(_onTabRequest);
    _noLyricsSub?.cancel();
    _noLyricsRetry?.cancel();
    super.dispose();
  }

  void _onTabRequest() {
    final i = AppShell.tabRequest.value;
    if (i == null) return;
    AppShell.tabRequest.value = null;
    if (mounted) setState(() => _index = _lastIndex = i);
  }

  /// Shows the queued no-lyrics questions, but only while the shell itself
  /// is on screen: never over a song being sung or another page.
  Future<void> _askNoLyrics() async {
    if (_askingLyrics) return;
    _askingLyrics = true;
    try {
      while (_noLyricsQueue.isNotEmpty && mounted) {
        if (!_readyGlobal || !(ModalRoute.of(context)?.isCurrent ?? true)) {
          _noLyricsRetry?.cancel();
          _noLyricsRetry = Timer(const Duration(seconds: 2), _askNoLyrics);
          return;
        }
        final song = _noLyricsQueue.removeAt(0);
        final services = context.read<AppServices>();
        // Deleted, or lyrics added from the song's menu meanwhile.
        if (!services.library.songs.any((s) => s.id == song.id)) continue;
        if (!(await services.pipeline.loadLyrics(song)).isEmpty || !mounted) continue;
        await showNoLyricsDialog(context, song);
      }
    } finally {
      _askingLyrics = false;
    }
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
    // A broken app copy of yt-dlp, or only one from PATH: offer to fix it now.
    await showYtDlpLaunchDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    if (!_readyGlobal) {
      return SetupGate(checking: _checking, onContinue: () => setState(() => _readyGlobal = true));
    }
    // Achievement unlocks and items gained pop up over every page.
    return CheerPopups(child: ItemGainPopups(child: AchievementPopups(
      child: Scaffold(
      body: Row(
        children: [
          // Fills the height; a short window scrolls it instead of pushing
          // the links at the bottom out of reach.
          LayoutBuilder(
            builder: (context, c) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: IntrinsicHeight(
                  child: NavigationRail(
            selectedIndex: _index == _aboutIndex || _index == _profileIndex ? null : _index,
            onDestinationSelected: (i) => setState(() => _index = _lastIndex = i),
            labelType: NavigationRailLabelType.all,
            // The profile: the player's cartoon singer, above the Library.
            leading: Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 2),
              child: _ProfileButton(
                selected: _index == _profileIndex,
                onTap: () => setState(() => _index = _lastIndex = _profileIndex),
              ),
            ),
            // Always in reach, so a streamer can report a problem mid-stream.
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // Debug builds only (compiled out of releases).
                    if (kDebugMode) ...[const _DevModeSwitch(), const SizedBox(height: 8)],
                    // 開發模式: act as if OBS were open (直播模式).
                    if (kDebugMode && context.watch<AppSettings>().devMode) ...[const _SimulateLiveSwitch(), const SizedBox(height: 8)],
                    _RailLink(
                      icon: Icons.info_outline,
                      selectedIcon: Icons.info,
                      label: tr('nav.about'),
                      selected: _index == _aboutIndex,
                      onTap: () => setState(() => _index = _lastIndex = _aboutIndex),
                    ),
                    const SizedBox(height: 4),
                    _RailLink(
                      icon: Icons.star_outline,
                      label: tr('nav.star'),
                      onTap: () {
                        recordAchievementEvent(context, 'support.star');
                        launchUrl(Uri.parse(UpdateChecker.repoUrl));
                      },
                    ),
                    const SizedBox(height: 4),
                    _RailLink(icon: Icons.bug_report_outlined, label: tr('nav.report'), onTap: () => openProblemReport(context)),
                  ]),
                ),
              ),
            ),
            destinations: [
              NavigationRailDestination(icon: const Icon(Icons.library_music_outlined), selectedIcon: const Icon(Icons.library_music), label: Text(tr('nav.library'))),
              NavigationRailDestination(icon: const Icon(Icons.live_tv_outlined), selectedIcon: const Icon(Icons.live_tv), label: Text(tr('nav.history'))),
              NavigationRailDestination(icon: const Icon(Icons.ondemand_video_outlined), selectedIcon: const Icon(Icons.ondemand_video), label: Text(tr('nav.replays'))),
              NavigationRailDestination(icon: const Icon(Icons.leaderboard_outlined), selectedIcon: const Icon(Icons.leaderboard), label: Text(tr('nav.charts'))),
              // A teaser for a feature still to come: greyed out and does nothing.
              NavigationRailDestination(
                icon: const Icon(Icons.military_tech_outlined),
                label: Text(tr('nav.ladder'), textAlign: TextAlign.center),
                disabled: true,
              ),
              NavigationRailDestination(icon: const Icon(Icons.emoji_events_outlined), selectedIcon: const Icon(Icons.emoji_events), label: Text(tr('nav.rules'))),
              NavigationRailDestination(
                icon: _UpdateBubble(child: const Icon(Icons.settings_outlined)),
                selectedIcon: _UpdateBubble(child: const Icon(Icons.settings)),
                label: Text(tr('nav.settings')),
              ),
            ],
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                const LibraryScreen(),
                HistoryScreen(active: _index == _historyIndex),
                const ReplaysScreen(),
                ChartsScreen(active: _index == _chartsIndex),
                const SizedBox.shrink(), // the ladder teaser has no page yet
                const RulesScreen(),
                const SettingsScreen(),
                const AboutScreen(),
                const ProfileScreen(),
              ],
            ),
          ),
        ],
      ),
    ),
    )));
  }
}

/// Debug builds only: turns the developer features on or off. Off, the app
/// looks as it does when released (apart from this switch).
class _DevModeSwitch extends StatelessWidget {
  const _DevModeSwitch();

  /// Off: the dev-only fake 直播模式 goes too.
  static void _set(AppSettings settings, bool on) {
    if (!on) StreamPrivacy.simulate.value = false;
    settings.setDevMode(on);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final on = settings.devMode;
    return Tooltip(
      message: tr('dev.modeHint'),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _set(settings, !on),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 24,
              child: FittedBox(child: Switch(value: on, onChanged: (v) => _set(settings, v))),
            ),
            const SizedBox(height: 2),
            Text(tr('dev.mode'), style: theme.textTheme.labelSmall?.copyWith(color: on ? cs.tertiary : cs.onSurfaceVariant, fontWeight: on ? FontWeight.w700 : null)),
          ]),
        ),
      ),
    );
  }
}

/// 開發模式: 直播模式 as if a streaming app such as OBS were open (only
/// the masking; the live achievements still look for a real one).
class _SimulateLiveSwitch extends StatelessWidget {
  const _SimulateLiveSwitch();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: StreamPrivacy.simulate,
      builder: (context, on, _) => Tooltip(
        message: tr('dev.simulateLiveHint'),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => StreamPrivacy.simulate.value = !on,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 24,
                child: FittedBox(child: Switch(value: on, onChanged: (v) => StreamPrivacy.simulate.value = v)),
              ),
              const SizedBox(height: 2),
              Text(tr('dev.simulateLive'), style: theme.textTheme.labelSmall?.copyWith(color: on ? cs.tertiary : cs.onSurfaceVariant, fontWeight: on ? FontWeight.w700 : null)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The avatar at the top of the rail: the profile's cartoon singer, still,
/// ringed while the profile is shown.
class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final name = settings.playerName;
    return Tooltip(
      message: name.isEmpty ? tr('nav.profile') : '${tr('nav.profile')}：$name',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 2),
            ),
            child: SingingAvatar(kind: avatarKindOf(settings.avatarKind), size: 44, headOnly: true, animated: false),
          ),
          const SizedBox(height: 2),
          Text(tr('nav.profile'), style: theme.textTheme.labelMedium?.copyWith(color: selected ? cs.onSurface : cs.onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : null)),
        ]),
      ),
    );
  }
}

/// "Update" over the Settings icon while a newer release is out.
class _UpdateBubble extends StatelessWidget {
  const _UpdateBubble({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: UpdateChecker.available,
        builder: (context, release, _) => SpeechBubbleBadge(text: tr('nav.update'), show: release != null, child: child),
      );
}

/// An entry at the bottom of the rail: a web link, or the About tab, which
/// looks like a selected rail destination while it is shown.
class _RailLink extends StatelessWidget {
  const _RailLink({required this.icon, required this.label, required this.onTap, this.selectedIcon, this.selected = false});
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 32,
              decoration: selected ? BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(16)) : null,
              child: Icon(selected ? selectedIcon ?? icon : icon, color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: selected ? cs.onSurface : cs.onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : null)),
          ]),
        ),
      ),
    );
  }
}
