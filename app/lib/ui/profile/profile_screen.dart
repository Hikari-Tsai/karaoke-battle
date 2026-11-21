// The profile, opened from the avatar at the top of the sidebar: a cartoon
// singer (female or male), the player's name (the one put on exported
// videos and replays) and the library's stats.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/achievements.dart';
import '../../services/identity.dart';
import '../../services/settings.dart';
import '../../services/sing_history.dart' show formatDay;
import '../../state/i18n.dart';
import '../library/library_stats.dart';
import '../widgets/brand.dart';
import '../widgets/info_tip.dart';
import '../widgets/rank.dart';
import '../widgets/reveal.dart';
import 'achievements_view.dart';
import 'singing_avatar.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: BrandedTitle(tr('profile.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 28),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: LayoutBuilder(builder: (context, c) {
                  const card = FadeSlideIn(child: _ProfileCard());
                  const stats = FadeSlideIn(
                    delay: Duration(milliseconds: 120),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [LibraryStats(), SizedBox(height: 16), _IdentityCard()]),
                  );
                  if (c.maxWidth < 860) {
                    return const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [card, SizedBox(height: 20), stats]);
                  }
                  return const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 340, child: card),
                    SizedBox(width: 24),
                    Expanded(child: stats),
                  ]);
                }),
              ),
            ),
          ),
          // --- achievements ---
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: const Padding(padding: EdgeInsets.fromLTRB(28, 36, 28, 0), child: AchievementsSection()),
            ),
          ),
        ],
      ),
    );
  }
}

/// The player's UUID and the devices it was used on: each by its machine
/// hash, with the OS version read at its last start; this one marked.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final svc = context.watch<IdentityService>();
    final id = svc.identity;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', fontFeatures: const [FontFeature.tabularFigures()]);
    void copy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('profile.copied'))));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.fingerprint, size: 20, color: cs.primary),
          const SizedBox(width: 8),
          Text(tr('profile.identity'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          InfoTip(sections: [(tr('profile.identity'), tr('profile.identityHint'))], size: 16, maxWidth: 300),
        ]),
        const SizedBox(height: 10),
        if (id == null)
          const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
        else ...[
          Text(tr('profile.userId'), style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
          Row(children: [
            Expanded(child: SelectableText(id.userId, style: mono?.copyWith(fontSize: 13, fontWeight: FontWeight.w700))),
            IconButton(tooltip: tr('profile.copy'), icon: const Icon(Icons.copy, size: 16), onPressed: () => copy(id.userId)),
          ]),
          const SizedBox(height: 8),
          Text(tr('profile.devices', {'n': id.devices.length}), style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 2),
          if (id.devices.isEmpty) Text(tr('profile.noDevice'), style: theme.textTheme.bodySmall),
          for (final d in id.devices)
            Tooltip(
              message: '${d.id}\n${tr('profile.deviceSeen', {'first': formatDay(d.firstSeen.toLocal()), 'last': formatDay(d.lastSeen.toLocal())})}',
              child: Row(children: [
                Icon(identical(d, svc.current) ? Icons.computer : Icons.devices_other, size: 16, color: identical(d, svc.current) ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: d.id.substring(0, 16), style: mono),
                      TextSpan(text: '  (${d.os})', style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (identical(d, svc.current))
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: cs.primary.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(4)),
                    child: Text(tr('profile.thisDevice'), style: theme.textTheme.labelSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
                  ),
                IconButton(tooltip: tr('profile.copy'), icon: const Icon(Icons.copy, size: 14), visualDensity: VisualDensity.compact, onPressed: () => copy(d.id)),
              ]),
            ),
        ],
      ]),
    );
  }
}

/// The singer, the name (big, with a pen to edit it) and the look.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard();

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  late final AppSettings _settings = context.read<AppSettings>();
  final _name = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _edit() {
    _name.text = _settings.playerName;
    _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<void> _save() async {
    await _settings.setPlayerName(_name.text);
    if (mounted) setState(() => _editing = false);
  }

  void _cancel() => setState(() => _editing = false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<AppSettings>();
    final kind = avatarKindOf(settings.avatarKind);
    final name = settings.playerName;
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3D1546), Color(0xFF241640), Color(0xFF16141F)]),
        border: Border.all(color: const Color(0x33C8BEFA)),
        boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 30, offset: Offset(0, 12))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(
          child: SizedBox(
            width: 240,
            height: 240,
            child: Stack(clipBehavior: Clip.none, children: [
              SingingAvatar(kind: kind, size: 240),
              // The best rank ever reached, stuck on like a sticker.
              if (bestRankOf(context.watch<AchievementService>()) case final rank?)
                Positioned(right: -14, bottom: 14, child: RankSticker(rank: rank)),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // --- the name: big, with a pen to edit it ---
        SizedBox(
          height: 56,
          child: _editing
              ? CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        focusNode: _focus,
                        maxLength: 40,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                        decoration: InputDecoration(hintText: tr('profile.name'), counterText: '', isDense: true),
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                    IconButton(tooltip: tr('ok'), onPressed: _save, icon: const Icon(Icons.check, color: Color(0xFF30D158))),
                    IconButton(tooltip: tr('cancel'), onPressed: _cancel, icon: const Icon(Icons.close)),
                  ]),
                )
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const SizedBox(width: 40), // balances the pen, so the name is centred
                  Flexible(
                    child: Text(
                      name.isEmpty ? tr('profile.noName') : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: name.isEmpty ? const Color(0xFFAAA6BA) : Colors.white,
                        shadows: const [Shadow(color: Color(0x66BF5AF2), blurRadius: 18)],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('profile.editName'),
                    onPressed: _edit,
                    icon: const Icon(Icons.edit_outlined, size: 20, color: Color(0xFFC8BEFA)),
                  ),
                ]),
        ),
        const SizedBox(height: 20),
        // --- the look: people and small animals ---
        Text(tr('profile.look'), style: theme.textTheme.labelLarge?.copyWith(color: const Color(0xFFC9C4D8))),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            for (final k in AvatarKind.values) _LookChoice(kind: k, selected: k == kind, onTap: () => settings.setAvatarKind(k.name)),
          ],
        ),
      ]),
    );
  }
}

/// The best rank ever reached, from the rank collection (kept for good,
/// like every achievement); null before the first scored take.
String? bestRankOf(AchievementService svc) {
  for (final e in rankAchievements.entries.toList().reversed) {
    if (svc.unlocked.containsKey(e.key)) return e.value;
  }
  return null;
}

/// A rank as a sticker: the rank chip (shining from S up) on a white
/// die-cut edge, a little askew, popping on when it appears.
class RankSticker extends StatelessWidget {
  const RankSticker({super.key, required this.rank, this.fontSize = 30});
  final String rank;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tr('profile.bestRank', {'rank': rank}),
      child: TweenAnimationBuilder<double>(
        key: ValueKey(rank),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.elasticOut,
        builder: (context, v, child) => Transform.rotate(angle: -0.21 - 0.5 * (1 - v), child: Transform.scale(scale: v, child: child)),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 10, offset: Offset(2, 4))],
          ),
          child: RankChip(rank: rank, fontSize: fontSize),
        ),
      ),
    );
  }
}

/// One look in the picker: its face and name, ringed when chosen.
class _LookChoice extends StatelessWidget {
  const _LookChoice({required this.kind, required this.selected, required this.onTap});
  final AvatarKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? cs.primary.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(color: selected ? cs.primary : Colors.transparent, width: 1.5),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SingingAvatar(kind: kind, size: 44, headOnly: true, animated: false),
          const SizedBox(height: 4),
          Text(
            tr('profile.${kind.name}'),
            style: theme.textTheme.labelSmall?.copyWith(color: selected ? Colors.white : const Color(0xFFC9C4D8), fontWeight: selected ? FontWeight.w700 : null),
          ),
        ]),
      ),
    );
  }
}
