// Items on the profile: the points left to spend and the items to redeem
// with them (see ItemService).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/items.dart';
import '../../state/i18n.dart';
import '../widgets/reveal.dart';
import '../widgets/shine.dart';
import '../widgets/stats_card.dart';

const _wandColor = Color(0xFFB57CFF);
const _pointsColor = Color(0xFFE5A823);

/// The item's icon in its round medal, with sparkles turning around it.
class ItemMedal extends StatelessWidget {
  const ItemMedal({super.key, required this.kind, this.size = 64});
  final ItemKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ShineTicker(
        builder: (context, t) => CustomPaint(
          painter: _SparklePainter(t: t ?? 0),
          child: Center(
            child: Container(
              width: size * 0.78,
              height: size * 0.78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFD9A8FF), _wandColor, Color(0xFF6B3FD6)]),
                boxShadow: [BoxShadow(color: _wandColor.withValues(alpha: 0.25 + 0.25 * shinePulse(t ?? 0, period: 3)), blurRadius: 18)],
              ),
              child: Icon(itemIcon(kind), color: Colors.white, size: size * 0.42),
            ),
          ),
        ),
      ),
    );
  }
}

IconData itemIcon(ItemKind k) => switch (k) {
      ItemKind.tuningWand => Icons.auto_fix_high,
    };

class _SparklePainter extends CustomPainter {
  _SparklePainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    for (var i = 0; i < 4; i++) {
      final a = t * 0.9 + i * math.pi / 2;
      final twinkle = shinePulse(t, period: 1.6, phase: i * 0.25);
      final p = c + Offset(math.cos(a), math.sin(a)) * r * 0.92;
      final s = 2.0 + 2.5 * twinkle;
      final paint = Paint()..color = Color.lerp(const Color(0xFFFFE08A), Colors.white, twinkle)!.withValues(alpha: 0.4 + 0.6 * twinkle);
      canvas.drawPath(
        Path()
          ..moveTo(p.dx, p.dy - s)
          ..quadraticBezierTo(p.dx, p.dy, p.dx + s, p.dy)
          ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + s)
          ..quadraticBezierTo(p.dx, p.dy, p.dx - s, p.dy)
          ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - s),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.t != t;
}

class ItemsSection extends StatelessWidget {
  const ItemsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FadeSlideIn(
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: _wandColor),
            child: const Icon(Icons.backpack, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Text(tr('items.title'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        ]),
      ),
      const SizedBox(height: 16),
      StatsCard(icon: Icons.account_balance_wallet_outlined, title: tr('items.wallet'), tiles: [
        StatTile(
          icon: Icons.stars,
          color: _pointsColor,
          label: tr('items.balance'),
          value: items.balance.toDouble(),
          format: (v) => '${v.round()}',
          valueColor: const Color(0xFFFFD66B),
          note: tr('items.balanceNote', {'earned': items.earned, 'spent': items.spent}),
        ),
        for (final k in ItemKind.values)
          StatTile(
            icon: itemIcon(k),
            color: _wandColor,
            label: tr('items.${k.name}.name'),
            value: items.ownedOf(k).toDouble(),
            format: (v) => '× ${v.round()}',
            note: tr('items.usedNote', {'n': items.usedOf(k)}),
          ),
      ]),
      const SizedBox(height: 16),
      for (final (i, k) in ItemKind.values.indexed) FadeSlideIn(delay: Duration(milliseconds: 120 + 60 * i), child: _ItemCard(kind: k)),
    ]);
  }
}

/// One item to redeem: what it does, how many are held, and the button.
class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.kind});
  final ItemKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    final short = kind.cost - items.balance;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: _wandColor.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 18, 14),
      child: Row(children: [
        ItemMedal(kind: kind),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(tr('items.${kind.name}.name'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: _wandColor.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(10)),
                child: Text(tr('items.owned', {'n': items.ownedOf(kind)}), style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFD9BDFF), fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(tr('items.${kind.name}.desc'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text(tr('items.${kind.name}.how'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 16),
        Tooltip(
          message: short > 0 ? tr('items.short', {'n': short}) : '',
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _wandColor, foregroundColor: Colors.white),
            onPressed: short > 0 ? null : () => items.redeem(kind),
            icon: const Icon(Icons.stars, size: 18),
            label: Text(tr('items.redeem', {'n': kind.cost})),
          ),
        ),
      ]),
    );
  }
}
