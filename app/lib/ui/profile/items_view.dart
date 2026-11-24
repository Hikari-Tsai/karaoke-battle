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
      ItemKind.mentorTicket => Icons.school,
    };

/// An item's colour, with the lighter and darker ends of its medal.
Color itemColor(ItemKind k) => itemShades(k).$2;
(Color, Color, Color) itemShades(ItemKind k) => switch (k) {
      ItemKind.tuningWand => (const Color(0xFFD9A8FF), _wandColor, const Color(0xFF6B3FD6)),
      ItemKind.resonanceField => (const Color(0xFFA8F4FF), const Color(0xFF3FC8DE), const Color(0xFF1F7FA8)),
      ItemKind.mentorTicket => (const Color(0xFFFFE3A3), const Color(0xFFE9A93A), const Color(0xFFA86E12)),
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

  /// Places in the shop: the items and room for one more to come.
  static const slots = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              onPressed: () => _resetTrades(context),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(tr('items.devReset')),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => showItemsDevDialog(context),
              icon: const Icon(Icons.build_outlined, size: 18),
              label: Text(tr('items.devEdit')),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      // --- the wallet and the bag of items held, side by side ---
      LayoutBuilder(builder: (context, c) {
        const wallet = FadeSlideIn(child: _WalletCard());
        const bag = FadeSlideIn(delay: Duration(milliseconds: 100), child: _BagCard());
        if (c.maxWidth < 760) return const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [wallet, SizedBox(height: 14), bag]);
        return const IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: 400, child: wallet),
            SizedBox(width: 16),
            Expanded(child: bag),
          ]),
        );
      }),
      const SizedBox(height: 26),
      // --- the item shop: one slot per item, room kept for more ---
      FadeSlideIn(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF221A33), Color(0xFF17141F)]),
            border: Border.all(color: const Color(0x33C8BEFA)),
          ),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              SizedBox(width: 72, height: 60, child: ShineTicker(builder: (context, t) => CustomPaint(painter: ShopPainter(t: t ?? 0)))),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tr('items.shop'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(tr('items.shopNote'), style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFFC9C4D8))),
                ]),
              ),
              Text(tr('items.slots', {'n': ItemKind.values.length, 'of': slots}), style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, c) {
              final per = c.maxWidth >= 860 ? 4 : (c.maxWidth >= 540 ? 2 : 1);
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
          ]),
        ),
      ),
    ]);
  }
}

/// "11/25 05:00".
String resetLabel(DateTime t) => '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
    final locked = !kind.available;
    return Opacity(
      opacity: locked ? 0.6 : 1,
      child: Container(
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
          if (locked)
            Tooltip(
              message: tr('items.lockedTip'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(tr('items.locked'), style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ]),
              ),
            )
          else
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
        Row(children: [
          Flexible(child: Text(tr('items.${kind.name}.name'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          const SizedBox(width: 8),
          Tooltip(
            message: tr('items.dailyTip', {'n': kind.daily}),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: itemColor(kind).withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(8)),
              child: Text(tr('items.dailyChip', {'n': kind.daily}), style: theme.textTheme.labelSmall?.copyWith(color: itemColor(kind), fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(tr('items.${kind.name}.desc'), style: theme.textTheme.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        Expanded(
          child: Text(tr('items.${kind.name}.how'), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), overflow: TextOverflow.fade),
        ),
        Text(tr('items.usedNote', {'n': items.usedOf(kind)}), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Tooltip(
          message: locked ? tr('items.lockedTip') : (short > 0 ? tr('items.short', {'n': short}) : ''),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: itemColor(kind), foregroundColor: Colors.white),
            onPressed: locked || short > 0 ? null : () => confirmRedeem(context, kind),
            icon: Icon(locked ? Icons.lock_outline : Icons.stars, size: 18),
            label: Text(locked ? tr('items.lockedButton') : tr('items.redeem', {'n': kind.cost})),
          ),
        ),
      ]),
      ),
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

/// Asks before spending points on one [kind], then redeems it (its
/// celebration follows). False when cancelled or not enough points.
Future<bool> confirmRedeem(BuildContext context, ItemKind kind) async {
  final items = context.read<ItemService>();
  if (!items.canRedeem(kind)) return false;
  final theme = Theme.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: ItemMedal(kind: kind, size: 72),
      title: Text(tr('items.confirmTitle', {'item': tr('items.${kind.name}.name')})),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('items.${kind.name}.desc'), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: _pointsColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.stars, size: 18, color: _pointsColor),
              const SizedBox(width: 8),
              Text(tr('items.confirmPoints', {'cost': kind.cost, 'from': items.balance, 'to': items.balance - kind.cost}),
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: itemColor(kind), foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.check, size: 18),
          label: Text(tr('items.confirmRedeem')),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  return items.redeem(kind);
}

/// 開發模式: undoes every trade, after asking.
Future<void> _resetTrades(BuildContext context) async {
  final items = context.read<ItemService>();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.restart_alt, size: 32),
      title: Text(tr('items.devReset')),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: Text(tr('items.devResetBody', {'n': items.spent}))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('items.devResetGo'))),
      ],
    ),
  );
  if (ok == true) await items.resetTrades();
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

/// The points wallet: a drawn wallet and the points to spend, counting from
/// the number shown to each new one.
class _WalletCard extends StatelessWidget {
  const _WalletCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3D1546), Color(0xFF241640), Color(0xFF16141F)]),
        border: Border.all(color: const Color(0x33C8BEFA)),
        boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 30, offset: Offset(0, 12))],
      ),
      padding: const EdgeInsets.fromLTRB(22, 18, 26, 18),
      child: Row(children: [
        SizedBox(
          width: 120,
          height: 96,
          child: ShineTicker(builder: (context, t) => CustomPaint(painter: WalletPainter(t: t ?? 0))),
        ),
        const SizedBox(width: 22),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('items.wallet'), style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(tr('items.balance'), style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFC9C4D8))),
            const SizedBox(height: 2),
            _DevEditable(
              focus: 'points',
              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                const Icon(Icons.stars, color: _pointsColor, size: 30),
                const SizedBox(width: 8),
                CountUp(
                  value: items.balance.toDouble(),
                  format: (v) => '${v.round()}',
                  delay: const Duration(milliseconds: 150),
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFFFFD66B),
                    fontFeatures: const [FontFeature.tabularFigures()],
                    shadows: const [Shadow(color: Color(0x88E5A823), blurRadius: 16)],
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 6),
            Text(tr('items.walletLine'), style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFFE8B9FF), fontStyle: FontStyle.italic, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}

/// A wallet in flat colours: a purple leather body, its flap with a gold
/// clasp, a card and gold coins peeking out of the top; the coins glint now
/// and then ([t] is the shine ticker's seconds).
class WalletPainter extends CustomPainter {
  WalletPainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Coins and a card behind the body.
    final card = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.14, h * 0.10, w * 0.5, h * 0.42), Radius.circular(w * 0.04));
    canvas.save();
    canvas.translate(w * 0.39, h * 0.31);
    canvas.rotate(-0.12);
    canvas.translate(-w * 0.39, -h * 0.31);
    canvas.drawRRect(card, Paint()..color = const Color(0xFF64D2FF));
    canvas.drawRect(Rect.fromLTWH(card.left, card.top + h * 0.08, card.width, h * 0.06), Paint()..color = const Color(0xFF2B6E8C));
    canvas.restore();
    void coin(Offset c, double r, double glint) {
      canvas.drawCircle(c + Offset(0, r * 0.18), r, Paint()..color = const Color(0xFFB57A12));
      canvas.drawCircle(c, r, Paint()..color = const Color(0xFFF2C14E));
      canvas.drawCircle(c, r * 0.68, Paint()..color = const Color(0xFFE5A823));
      final star = Path();
      for (var k = 0; k < 10; k++) {
        final a = -math.pi / 2 + k * math.pi / 5;
        final rr = k.isEven ? r * 0.42 : r * 0.18;
        final p = c + Offset(math.cos(a), math.sin(a)) * rr;
        k == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(star..close(), Paint()..color = const Color(0xFFFFF1B8));
      if (glint > 0) {
        canvas.drawCircle(c + Offset(-r * 0.35, -r * 0.35), r * 0.22 * glint, Paint()..color = Colors.white.withValues(alpha: 0.9 * glint));
      }
    }

    final g1 = math.max(0.0, math.sin(t * 1.3) * 2 - 1).toDouble();
    final g2 = math.max(0.0, math.sin(t * 1.3 + 2.2) * 2 - 1).toDouble();
    coin(Offset(w * 0.62, h * 0.24), w * 0.13, g1);
    coin(Offset(w * 0.80, h * 0.33), w * 0.11, g2);

    // The body.
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.04, h * 0.34, w * 0.92, h * 0.62), Radius.circular(w * 0.08));
    canvas.drawRRect(body.shift(const Offset(0, 4)), Paint()..color = const Color(0x55000000));
    canvas.drawRRect(
      body,
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF9B6BF2), Color(0xFF6B3FD6)]).createShader(body.outerRect),
    );
    // Stitching.
    final stitch = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final inset = body.deflate(w * 0.035);
    for (var x = inset.left + 4; x < inset.right - 4; x += 7) {
      canvas.drawLine(Offset(x, inset.bottom), Offset(x + 3, inset.bottom), stitch);
    }
    // The flap and its clasp.
    final flap = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.50, h * 0.48, w * 0.46, h * 0.28),
      topLeft: Radius.circular(h * 0.14),
      bottomLeft: Radius.circular(h * 0.14),
      topRight: Radius.circular(w * 0.02),
      bottomRight: Radius.circular(w * 0.02),
    );
    canvas.drawRRect(flap, Paint()..color = const Color(0xFF552DB0));
    final clasp = Offset(w * 0.62, h * 0.62);
    canvas.drawCircle(clasp, h * 0.075, Paint()..color = const Color(0xFFF2C14E));
    canvas.drawCircle(clasp, h * 0.04, Paint()..color = const Color(0xFFB57A12));
    // A light along the top edge.
    canvas.drawLine(Offset(body.left + w * 0.06, body.top + 2), Offset(body.right - w * 0.06, body.top + 2), Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(WalletPainter old) => old.t != t;
}

/// The bag: the items held, each with its count, and the daily reset.
class _BagCard extends StatelessWidget {
  const _BagCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = context.watch<ItemService>();
    final held = [for (final k in ItemKind.values) if (items.ownedOf(k) > 0) k];
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: const Color(0x33C8BEFA)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 20, 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 96, height: 104, child: ShineTicker(builder: (context, t) => CustomPaint(painter: BackpackPainter(t: t ?? 0, full: held.isNotEmpty)))),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(tr('items.bag'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          // What the reset tops up to, on hover.
          Tooltip(
            message: tr('items.dailyTip2', {
              'list': ItemKind.values.where((k) => k.available && k.daily > 0).map((k) => tr('items.dailyItem', {'item': tr('items.${k.name}.name'), 'n': k.daily})).join(tr('items.listSep')),
            }),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.schedule, size: 15, color: Color(0xFF8FE6F2)),
              const SizedBox(width: 4),
              Text(tr('items.daily'), style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFF8FE6F2), fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        if (held.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(tr('items.bagEmpty'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          )
        else
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final k in held)
              _DevEditable(
                focus: k.name,
                child: Tooltip(
                  message: tr('items.${k.name}.desc'),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
                    decoration: BoxDecoration(
                      color: itemColor(k).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: itemColor(k).withValues(alpha: 0.45)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ItemMedal(kind: k, size: 48),
                      const SizedBox(width: 8),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(tr('items.${k.name}.name'), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                        CountUp(
                          value: items.ownedOf(k).toDouble(),
                          format: (v) => '× ${v.round()}',
                          style: theme.textTheme.titleLarge?.copyWith(color: itemColor(k), fontWeight: FontWeight.w900, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ]),
                    ]),
                  ),
                ),
              ),
          ]),
      ])),
      ]),
    );
  }
}

/// A little shop front in flat colours: a striped awning with a scalloped
/// edge, a window with potions on a shelf, a door and a sign; a star on the
/// sign twinkles now and then ([t] is the shine ticker's seconds).
class ShopPainter extends CustomPainter {
  ShopPainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // The building.
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.08, h * 0.34, w * 0.84, h * 0.62), Radius.circular(w * 0.04));
    canvas.drawRRect(body.shift(const Offset(0, 3)), Paint()..color = const Color(0x55000000));
    canvas.drawRRect(body, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF9B6BF2), Color(0xFF6B3FD6)]).createShader(body.outerRect));
    // The window and its shelf of potions.
    final win = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.15, h * 0.52, w * 0.38, h * 0.30), Radius.circular(w * 0.03));
    canvas.drawRRect(win, Paint()..color = const Color(0xFF2A2140));
    canvas.drawLine(Offset(win.left + 2, win.bottom - h * 0.07), Offset(win.right - 2, win.bottom - h * 0.07), Paint()
      ..color = const Color(0xFFB58A4A)
      ..strokeWidth = 2);
    const potions = [Color(0xFFB57CFF), Color(0xFF3FC8DE), Color(0xFFE9A93A)];
    for (var k = 0; k < 3; k++) {
      final c = Offset(win.left + win.width * (0.22 + 0.28 * k), win.bottom - h * 0.12);
      canvas.drawCircle(c, w * 0.035, Paint()..color = potions[k]);
      canvas.drawRect(Rect.fromCenter(center: c - Offset(0, w * 0.045), width: w * 0.018, height: w * 0.03), Paint()..color = const Color(0xFFDDD6F2));
    }
    // The door with its knob.
    final door = RRect.fromRectAndCorners(Rect.fromLTWH(w * 0.60, h * 0.52, w * 0.24, h * 0.44), topLeft: Radius.circular(w * 0.1), topRight: Radius.circular(w * 0.1));
    canvas.drawRRect(door, Paint()..color = const Color(0xFF3E2283));
    canvas.drawCircle(Offset(door.right - w * 0.05, door.top + door.height * 0.55), w * 0.018, Paint()..color = const Color(0xFFF2C14E));
    // The awning: stripes, then a scalloped edge.
    final top = h * 0.14, bottom = h * 0.36;
    const stripes = 6;
    final sw = w / stripes;
    for (var k = 0; k < stripes; k++) {
      final color = k.isEven ? const Color(0xFFFF4FA3) : const Color(0xFFFFE3F0);
      final path = Path()
        ..moveTo(w * 0.08 + (w * 0.84) * k / stripes, top)
        ..lineTo(w * 0.08 + (w * 0.84) * (k + 1) / stripes, top)
        ..lineTo(sw * (k + 1), bottom)
        ..lineTo(sw * k, bottom)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawCircle(Offset(sw * (k + 0.5), bottom), sw / 2, Paint()..color = color);
    }
    // The sign on the roof, with a twinkling star.
    final sign = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, h * 0.08), width: w * 0.36, height: h * 0.15), Radius.circular(h * 0.05));
    canvas.drawRRect(sign, Paint()..color = const Color(0xFFF2C14E));
    final tw = 0.5 + 0.5 * math.sin(t * 2.2);
    final c = sign.center;
    final r = h * (0.045 + 0.015 * tw);
    final star = Path();
    for (var k = 0; k < 10; k++) {
      final a = -math.pi / 2 + k * math.pi / 5;
      final rr = k.isEven ? r : r * 0.45;
      final p = c + Offset(math.cos(a), math.sin(a)) * rr;
      k == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(star..close(), Paint()..color = Color.lerp(const Color(0xFFA86E12), Colors.white, tw)!);
  }

  @override
  bool shouldRepaint(ShopPainter old) => old.t != t;
}

/// A backpack in flat colours: a rounded purple body with a front pocket,
/// a flap with a gold buckle and a carry loop; when [full], an item's tip
/// (a wand with a twinkle) peeks out of the top ([t] is the shine ticker's
/// seconds).
class BackpackPainter extends CustomPainter {
  BackpackPainter({required this.t, this.full = true});
  final double t;
  final bool full;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // The carry loop.
    canvas.drawArc(Rect.fromCenter(center: Offset(w / 2, h * 0.17), width: w * 0.34, height: h * 0.22), math.pi, math.pi, false, Paint()
      ..color = const Color(0xFF552DB0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.05
      ..strokeCap = StrokeCap.round);
    // A wand sticking out of the top.
    if (full) {
      canvas.save();
      canvas.translate(w * 0.66, h * 0.22);
      canvas.rotate(0.45);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w * 0.06, height: h * 0.34), Radius.circular(w * 0.03)), Paint()..color = const Color(0xFF3E2283));
      canvas.restore();
      final tip = Offset(w * 0.73, h * 0.08);
      final tw = 0.5 + 0.5 * math.sin(t * 2.4);
      final r = w * (0.06 + 0.025 * tw);
      final star = Path();
      for (var k = 0; k < 10; k++) {
        final a = -math.pi / 2 + k * math.pi / 5;
        final rr = k.isEven ? r : r * 0.45;
        final pt = tip + Offset(math.cos(a), math.sin(a)) * rr;
        k == 0 ? star.moveTo(pt.dx, pt.dy) : star.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(star..close(), Paint()..color = Color.lerp(const Color(0xFFF2C14E), Colors.white, tw * 0.7)!);
    }
    // The body.
    final body = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.12, h * 0.22, w * 0.76, h * 0.74),
      topLeft: Radius.circular(w * 0.3),
      topRight: Radius.circular(w * 0.3),
      bottomLeft: Radius.circular(w * 0.12),
      bottomRight: Radius.circular(w * 0.12),
    );
    canvas.drawRRect(body.shift(const Offset(0, 4)), Paint()..color = const Color(0x55000000));
    canvas.drawRRect(body, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF9B6BF2), Color(0xFF6B3FD6)]).createShader(body.outerRect));
    // Side straps.
    final strap = Paint()..color = const Color(0xFF552DB0);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.24, h * 0.30, w * 0.07, h * 0.6), Radius.circular(w * 0.03)), strap);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.69, h * 0.30, w * 0.07, h * 0.6), Radius.circular(w * 0.03)), strap);
    // The front pocket with stitching.
    final pocket = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.27, h * 0.62, w * 0.46, h * 0.28), Radius.circular(w * 0.08));
    canvas.drawRRect(pocket, Paint()..color = const Color(0xFF7E52E0));
    final stitch = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    for (var x = pocket.left + 6; x < pocket.right - 6; x += 6) {
      canvas.drawLine(Offset(x, pocket.top + 4), Offset(x + 2.5, pocket.top + 4), stitch);
    }
    // The flap and its buckle.
    final flap = Path()
      ..moveTo(w * 0.2, h * 0.36)
      ..quadraticBezierTo(w / 2, h * 0.24, w * 0.8, h * 0.36)
      ..lineTo(w * 0.8, h * 0.46)
      ..quadraticBezierTo(w / 2, h * 0.58, w * 0.2, h * 0.46)
      ..close();
    canvas.drawPath(flap, Paint()..color = const Color(0xFF552DB0));
    final buckle = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, h * 0.5), width: w * 0.16, height: h * 0.1), Radius.circular(w * 0.03));
    canvas.drawRRect(buckle, Paint()..color = const Color(0xFFF2C14E));
    canvas.drawRRect(buckle.deflate(w * 0.03), Paint()..color = const Color(0xFFB57A12));
    // A light on the top curve.
    canvas.drawArc(Rect.fromLTWH(w * 0.2, h * 0.25, w * 0.6, h * 0.3), math.pi * 1.15, math.pi * 0.7, false, Paint()
      ..color = const Color(0x55FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(BackpackPainter old) => old.t != t || old.full != full;
}
