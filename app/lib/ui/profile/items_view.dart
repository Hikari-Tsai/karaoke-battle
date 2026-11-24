// Items on the profile: the points left to spend and the items to redeem
// with them (see ItemService).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/dev_mode.dart';
import '../../services/items.dart';
import '../../services/settings.dart';
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
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [itemShades(kind).$1, itemShades(kind).$2, itemShades(kind).$3]),
                boxShadow: [BoxShadow(color: itemColor(kind).withValues(alpha: 0.25 + 0.25 * shinePulse(t ?? 0, period: 3)), blurRadius: 18)],
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
      ItemKind.resonanceField => Icons.wifi_tethering,
    };

/// An item's colour, with the lighter and darker ends of its medal.
Color itemColor(ItemKind k) => itemShades(k).$2;
(Color, Color, Color) itemShades(ItemKind k) => switch (k) {
      ItemKind.tuningWand => (const Color(0xFFD9A8FF), _wandColor, const Color(0xFF6B3FD6)),
      ItemKind.resonanceField => (const Color(0xFFA8F4FF), const Color(0xFF3FC8DE), const Color(0xFF1F7FA8)),
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

  /// Places in the bag: room for the items to come.
  static const slots = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    final dev = devFeatures(context.watch<AppSettings>());
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
          if (dev) ...[
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => showItemsDevDialog(context),
              icon: const Icon(Icons.build_outlined, size: 18),
              label: Text(tr('items.devEdit')),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      // --- the points wallet ---
      StatsCard(icon: Icons.account_balance_wallet_outlined, title: tr('items.wallet'), tiles: [
        _DevEditable(
          focus: 'points',
          child: StatTile(
            key: ValueKey('balance-${items.balance}'),
            icon: Icons.stars,
            color: _pointsColor,
            label: tr('items.balance'),
            value: items.balance.toDouble(),
            format: (v) => '${v.round()}',
            valueColor: const Color(0xFFFFD66B),
            note: tr('items.balanceHint'),
          ),
        ),
        StatTile(
          key: ValueKey('earned-${items.earned}'),
          icon: Icons.emoji_events_outlined,
          color: const Color(0xFFBF5AF2),
          label: tr('items.earned'),
          value: items.earned.toDouble(),
          format: (v) => '${v.round()}',
          note: tr('items.earnedNote'),
        ),
        StatTile(
          key: ValueKey('spent-${items.spent}'),
          icon: Icons.shopping_bag_outlined,
          color: _wandColor,
          label: tr('items.spent'),
          value: items.spent.toDouble(),
          format: (v) => '${v.round()}',
          note: tr('items.spentNote'),
        ),
      ]),
      const SizedBox(height: 26),
      // --- the bag ---
      FadeSlideIn(
        child: Row(children: [
          Text(tr('items.bag'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: theme.colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(tr('items.slots', {'n': ItemKind.values.length, 'of': slots}), style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, c) {
        final per = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 560 ? 2 : 1);
        const gap = 12.0;
        final w = (c.maxWidth - gap * (per - 1)) / per;
        final kinds = ItemKind.values;
        final count = math.max(slots, (kinds.length / per).ceil() * per);
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (var i = 0; i < count; i++)
            SizedBox(
              width: w,
              height: 280,
              child: FadeSlideIn(delay: Duration(milliseconds: 40 * i), offset: 10, child: i < kinds.length ? _ItemSlot(kind: kinds[i]) : const _EmptySlot()),
            ),
        ]);
      }),
    ]);
  }
}

/// 開發模式: a double click on [child] sets the points or items ([focus]).
class _DevEditable extends StatelessWidget {
  const _DevEditable({required this.focus, required this.child});
  final String focus;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!devFeatures(context.watch<AppSettings>())) return child;
    return Tooltip(
      message: tr('items.devDoubleClick'),
      child: GestureDetector(onDoubleTap: () => showItemsDevDialog(context, focus: focus), child: child),
    );
  }
}

/// One item in the bag: what it does, how many are held, and redeeming one.
class _ItemSlot extends StatelessWidget {
  const _ItemSlot({required this.kind});
  final ItemKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    final short = kind.cost - items.balance;
    final held = items.ownedOf(kind);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: itemColor(kind).withValues(alpha: held > 0 ? 0.6 : 0.3)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ItemMedal(kind: kind, size: 56),
          const Spacer(),
          _DevEditable(
            focus: kind.name,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: itemColor(kind).withValues(alpha: held > 0 ? 0.28 : 0.12), borderRadius: BorderRadius.circular(12)),
              child: Text('× $held', style: theme.textTheme.titleSmall?.copyWith(color: const Color(0xFFE3CCFF), fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Text(tr('items.${kind.name}.name'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(tr('items.${kind.name}.desc'), style: theme.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Expanded(
          child: Text(tr('items.${kind.name}.how'), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), overflow: TextOverflow.fade),
        ),
        Text(tr('items.usedNote', {'n': items.usedOf(kind)}), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Tooltip(
          message: short > 0 ? tr('items.short', {'n': short}) : '',
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: itemColor(kind), foregroundColor: Colors.white),
            onPressed: short > 0 ? null : () => items.redeem(kind),
            icon: const Icon(Icons.stars, size: 18),
            label: Text(tr('items.redeem', {'n': kind.cost})),
          ),
        ),
      ]),
    );
  }
}

/// A place kept for an item to come.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return CustomPaint(
      painter: _DashedBorderPainter(color: theme.colorScheme.outlineVariant),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(shape: BoxShape.circle, color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)),
            child: Icon(Icons.question_mark_rounded, color: muted),
          ),
          const SizedBox(height: 10),
          Text(tr('items.soon'), style: theme.textTheme.titleSmall?.copyWith(color: muted, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(tr('items.soonNote'), style: theme.textTheme.labelSmall?.copyWith(color: muted)),
        ]),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18)).deflate(0.75));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 12) {
        canvas.drawPath(m.extractPath(d, math.min(d + 6, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

/// 開發模式: sets the points to spend and how many of each item are held.
/// [focus] ('points' or an item's name) is the field to start in.
Future<void> showItemsDevDialog(BuildContext context, {String? focus}) async {
  final items = context.read<ItemService>();
  final points = TextEditingController(text: '${items.balance}');
  final counts = {for (final k in ItemKind.values) k: TextEditingController(text: '${items.ownedOf(k)}')};
  Widget field(String label, TextEditingController c, bool autofocus, {bool signed = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          autofocus: autofocus,
          keyboardType: TextInputType.numberWithOptions(signed: signed),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(signed ? r'^-?\d*' : r'^\d*'))],
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
          onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
        ),
      );
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(children: [const Icon(Icons.build_outlined, size: 20), const SizedBox(width: 8), Text(tr('items.devEdit'))]),
      content: SizedBox(
        width: 340,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('items.devHint'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          field(tr('items.balance'), points, focus == null || focus == 'points', signed: true),
          for (final k in ItemKind.values) field(tr('items.devOwned', {'item': tr('items.${k.name}.name')}), counts[k]!, focus == k.name),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('items.devSave'))),
      ],
    ),
  );
  if (ok == true) {
    final p = int.tryParse(points.text);
    if (p != null && p != items.balance) await items.setBalance(p);
    for (final k in ItemKind.values) {
      final n = int.tryParse(counts[k]!.text);
      if (n != null && n != items.ownedOf(k)) await items.setOwned(k, n);
    }
  }
  points.dispose();
  for (final c in counts.values) {
    c.dispose();
  }
}
