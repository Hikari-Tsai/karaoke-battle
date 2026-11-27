// 直播工具 › 觀眾加油: the on/off bar at the top of the page, the dialog that
// sets up the payment services (綠界, 歐付寶), the cheer badge on a take and
// the settings.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/cheer.dart';
import '../../services/dev_mode.dart';
import '../../services/ecpay_alert.dart';
import '../../services/opay_alert.dart';
import '../../services/settings.dart';
import '../../services/song_library.dart';
import '../../state/i18n.dart';
import '../../state/stream_privacy.dart';
import '../widgets/app_dialog.dart';
import '../widgets/private_text.dart';
import 'cheer_celebration.dart' show previewCheerCelebration;

/// 0.82 → "0.82", 0.5 → "0.5", 2.0 → "2".
String cheerPointsText(double p) => _points(p);
String _points(double p) => p.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

String _providerName(String p) => tr('cheer.provider.$p');
String _providerNames(CheerService cheer) => cheer.providers.map(_providerName).join('、');

/// An example of [provider]'s alert URL, for hints.
String _example(String provider) => provider == 'opay' ? 'https://payment.opay.tw/Broadcaster/AlertBox/…' : 'https://payment.ecpay.com.tw/Broadcaster/AlertBox/…';

/// The test 贊助成功動畫網址 filled in in 開發模式, per service ('' = none).
String _devTestUrl(String provider) => provider == 'opay' ? kOpayStageTestAlertUrl : kEcpayStageTestAlertUrl;

/// Turns 觀眾加油 on or off; with no payment service set up, asks for one
/// first. Returns whether it is on afterwards.
Future<bool> toggleCheer(BuildContext context, bool on) async {
  final settings = context.read<AppSettings>();
  final cheer = context.read<CheerService>();
  if (on && !cheer.configured) {
    final saved = await showCheerSetupDialog(context, turnOn: true);
    return saved && settings.cheerEnabled;
  }
  await settings.setCheerEnabled(on);
  return on;
}

/// The bar at the top of 直播工具: the switch, each service's connection, the
/// rate and the latest donation; in 開發模式, test tools.
class CheerBar extends StatelessWidget {
  const CheerBar({super.key});

  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final cheer = context.watch<CheerService>();
    final on = cheer.enabled;
    final title = cheer.configured ? tr('cheer.titleWith', {'providers': _providerNames(cheer)}) : tr('cheer.title');
    final last = cheer.last;
    final dev = devFeatures(settings);
    Widget status(String p) {
      final (text, color) = switch (cheer.statusOf(p)) {
        AlertStatus.off => (tr('cheer.status.off'), cs.onSurfaceVariant),
        AlertStatus.connecting => (tr('cheer.status.connecting'), cs.tertiary),
        AlertStatus.connected => (tr('cheer.status.connected'), Colors.green),
        AlertStatus.error => (tr('cheer.status.error'), cs.error),
      };
      return Tooltip(
        message: cheer.lastErrorOf(p) ?? '',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 5),
          Text(cheer.providers.length > 1 ? '${_providerName(p)} $text' : text, style: theme.textTheme.labelLarge?.copyWith(color: color)),
          const SizedBox(width: 12),
        ]),
      );
    }

    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: on ? cs.primaryContainer.withValues(alpha: 0.35) : cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5))),
      ),
      child: Row(children: [
        Icon(Icons.volunteer_activism, color: on ? cs.primary : cs.onSurfaceVariant),
        const SizedBox(width: 10),
        Tooltip(
          message: tr('cheer.hint'),
          child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 8),
        Switch(value: on, onChanged: (v) => toggleCheer(context, v)),
        const SizedBox(width: 12),
        if (on) ...[
          for (final p in cheer.providers) status(p),
          Text(tr('cheer.rate', {'n': settings.cheerTwdPerPoint}), style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: last == null || !on
              ? Text(on ? '' : tr('cheer.hint'), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant))
              : Text(
                  last.songTitle == null
                      ? tr('cheer.lastNoSong', {'name': last.donation.name, 'amount': last.donation.amount})
                      : tr('cheer.last', {'name': last.donation.name, 'amount': last.donation.amount, 'song': last.songTitle, 'points': _points(last.points)}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
        ),
        // (Set up with 設定觀眾加油 at the top right of the page.)
        if (dev) _DevTools(cheer: cheer),
      ]),
    );
  }
}

/// 開發模式: the celebration for a made-up donation (nothing credited), and
/// the test environments' pages that send real test donations.
class _DevTools extends StatelessWidget {
  const _DevTools({required this.cheer});
  final CheerService cheer;

  @override
  Widget build(BuildContext context) {
    final ecpay = cheer.ecpay, opay = cheer.opay;
    final items = <(String, String, IconData, VoidCallback)>[
      (tr('cheer.devPreview'), tr('cheer.devPreviewTip'), Icons.play_circle_outline, () => previewCheerCelebration(context)),
      if (ecpay != null && ecpay.isStage) ...[
        (tr('cheer.devAlert'), tr('cheer.devAlertTip'), Icons.bolt, () => launchUrl(Uri.parse(kEcpayStageAnimationSetup))),
        (tr('cheer.devDonate'), tr('cheer.devDonateTip'), Icons.open_in_new, () => launchUrl(Uri.parse(ecpay.donateUrl))),
      ],
      if (opay != null && opay.isStage) ...[
        (tr('cheer.devOpayOffice'), tr('cheer.devOpayOfficeTip'), Icons.bolt, () => launchUrl(Uri.parse(kOpayStageBackOffice))),
        (tr('cheer.devOpayDonate'), tr('cheer.devDonateTip'), Icons.open_in_new, () => launchUrl(Uri.parse(opay.donateUrl))),
      ],
    ];
    return PopupMenuButton<int>(
      tooltip: tr('cheer.devTools'),
      onSelected: (i) => items[i].$4(),
      itemBuilder: (_) => [
        for (final (i, e) in items.indexed)
          PopupMenuItem(value: i, child: Tooltip(message: e.$2, child: Row(children: [Icon(e.$3, size: 18), const SizedBox(width: 10), Text(e.$1)]))),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.science_outlined, size: 18, color: Theme.of(context).colorScheme.tertiary),
          const SizedBox(width: 6),
          Text(tr('cheer.devTools'), style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.tertiary)),
        ]),
      ),
    );
  }
}

/// Sets up the services' 贊助成功動畫網址 (綠界 and 歐付寶, either or both).
/// With [turnOn], saving also turns 觀眾加油 on. In 開發模式 an empty field
/// starts with that service's test URL. Returns whether something was saved.
Future<bool> showCheerSetupDialog(BuildContext context, {bool turnOn = false}) async {
  final saved = await showDialog<bool>(context: context, builder: (_) => _CheerSetupDialog(turnOn: turnOn));
  return saved == true;
}

class _CheerSetupDialog extends StatefulWidget {
  const _CheerSetupDialog({required this.turnOn});
  final bool turnOn;

  @override
  State<_CheerSetupDialog> createState() => _CheerSetupDialogState();
}

class _CheerSetupDialogState extends State<_CheerSetupDialog> {
  final _url = <String, TextEditingController>{};
  final _devFilled = <String>{};
  final _testing = <String>{};
  final _testResult = <String, (String, bool)>{};

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettings>();
    for (final p in kCheerProviders) {
      var url = settings.alertUrlOf(p);
      if (url.isEmpty && devFeatures(settings) && _devTestUrl(p).isNotEmpty) {
        url = _devTestUrl(p);
        _devFilled.add(p);
      }
      _url[p] = TextEditingController(text: url)..addListener(() => setState(() => _testResult.remove(p)));
    }
  }

  @override
  void dispose() {
    for (final c in _url.values) {
      c.dispose();
    }
    super.dispose();
  }

  AlertBox? _box(String p) => AlertBox.parse(_url[p]!.text, provider: p);
  AlertInputProblem? _problem(String p) {
    final t = _url[p]!.text.trim();
    return t.isEmpty ? null : alertInputProblem(t, p);
  }

  /// Something to save, and nothing typed wrong.
  bool get _canSave => kCheerProviders.any((p) => _box(p) != null) && kCheerProviders.every((p) => _problem(p) == null);

  Future<void> _test(String p) async {
    final box = _box(p);
    if (box == null) return;
    setState(() {
      _testing.add(p);
      _testResult.remove(p);
    });
    (String, bool) result;
    try {
      if (p == 'opay') {
        await fetchOpayPage(box);
      } else {
        await fetchAlertPage(box);
      }
      result = (tr('cheer.testOk', {'provider': _providerName(p)}), true);
    } catch (e) {
      result = (tr('cheer.testFail', {'error': e}), false);
    }
    if (!mounted) return;
    setState(() {
      _testing.remove(p);
      _testResult[p] = result;
    });
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final settings = context.read<AppSettings>();
    for (final p in kCheerProviders) {
      await settings.setAlertUrlOf(p, _box(p)?.alertUrl ?? '');
    }
    if (widget.turnOn) await settings.setCheerEnabled(true);
    if (mounted) Navigator.pop(context, true);
  }

  Widget _field(BuildContext context, String p, {bool first = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = _providerName(p);
    final other = _providerName(p == 'opay' ? 'ecpay' : 'opay');
    final result = _testResult[p];
    final testing = _testing.contains(p);
    final saved = context.watch<AppSettings>().alertUrlOf(p).isNotEmpty;
    // 直播模式: the URL is not shown (its ID lets anyone follow the donations).
    final live = StreamPrivacy.live.value;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _url[p],
        autofocus: first,
        obscureText: live,
        decoration: InputDecoration(
          labelText: tr('cheer.urlOf', {'provider': name}),
          hintText: _example(p),
          border: const OutlineInputBorder(),
          // Says what was pasted instead, a HashKey / HashIV above all.
          errorText: switch (_problem(p)) {
            null || AlertInputProblem.empty => null,
            final e => tr('cheer.err.${e.name}', {'provider': name, 'other': other, 'example': _example(p)}),
          },
          errorMaxLines: 3,
        ),
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: 6),
      Text(tr('cheer.where.$p'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      if (_devFilled.contains(p)) ...[
        const SizedBox(height: 4),
        Text(tr('cheer.devFilled', {'provider': name}), style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary, fontWeight: FontWeight.w600)),
      ],
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton.icon(
          onPressed: _box(p) == null || testing ? null : () => _test(p),
          icon: testing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.wifi_tethering, size: 18),
          label: Text(testing ? tr('cheer.testing') : tr('cheer.test')),
        ),
        const SizedBox(width: 8),
        // Removes this service's URL now (and turns 觀眾加油 off when none
        // is left).
        TextButton.icon(
          onPressed: saved || _url[p]!.text.isNotEmpty ? () => _delete(p) : null,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: Text(tr('cheer.delete')),
          style: TextButton.styleFrom(foregroundColor: cs.error),
        ),
        const SizedBox(width: 12),
        if (result != null)
          Expanded(
            child: Text(result.$1, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: result.$2 ? Colors.green : cs.error)),
          ),
      ]),
    ]);
  }

  Future<void> _delete(String p) async {
    final settings = context.read<AppSettings>();
    final cheer = context.read<CheerService>();
    _url[p]!.clear();
    _devFilled.remove(p);
    await settings.setAlertUrlOf(p, '');
    if (!cheer.configured) await settings.setCheerEnabled(false);
    if (mounted) setState(() => _testResult[p] = (tr('cheer.deleted', {'provider': _providerName(p)}), true));
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(valueListenable: StreamPrivacy.live, builder: (context, _, _) => _build(context));

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialog(
      icon: const Icon(Icons.volunteer_activism),
      title: Text(tr('cheer.setupTitle')),
      scrollable: true,
      content: SizedBox(
        width: 580,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.turnOn) ...[Text(tr('cheer.setupBody')), const SizedBox(height: 16)],
          for (final (i, p) in kCheerProviders.indexed) ...[
            if (i > 0) const Divider(height: 32),
            _field(context, p, first: i == 0),
          ],
          const SizedBox(height: 16),
          Text(tr('cheer.unofficial'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('cancel'))),
        FilledButton(onPressed: _canSave ? _save : null, child: Text(widget.turnOn ? tr('cheer.saveOn') : tr('cheer.save'))),
      ],
    );
  }
}

/// The cheer points on [take], if it has any: a small chip by the score.
class CheerBadge extends StatefulWidget {
  const CheerBadge({super.key, required this.take, this.leadingGap = 0, this.trailingGap = 0});
  final TakeInfo take;

  /// Space before and after the badge, only when it shows.
  final double leadingGap, trailingGap;

  @override
  State<CheerBadge> createState() => _CheerBadgeState();
}

class _CheerBadgeState extends State<CheerBadge> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CheerBadge old) {
    super.didUpdateWidget(old);
    if (old.take.dir != widget.take.dir) _load();
  }

  Future<void> _load() async {
    await context.read<CheerService>().cheerOf(widget.take);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Rebuilt when a donation comes in (the service notifies).
    final c = context.watch<CheerService>().cached(widget.take);
    if (c.points <= 0) return const SizedBox.shrink();
    final badge = Tooltip(
      message: tr('cheer.badgeTip', {'n': c.items.length, 'amount': c.amount}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.pink.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.pink.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.volunteer_activism, size: 14, color: Colors.pink),
          const SizedBox(width: 4),
          Text(tr('cheer.badge', {'points': _points(c.points)}), style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
    if (widget.leadingGap == 0 && widget.trailingGap == 0) return badge;
    return Padding(padding: EdgeInsets.only(left: widget.leadingGap, right: widget.trailingGap), child: badge);
  }
}

/// Settings › 直播工具：觀眾加油: the switch, each service's URL (set up,
/// change, remove) and the rate.
class CheerSettings extends StatelessWidget {
  const CheerSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final settings = context.watch<AppSettings>();
    final cheer = context.watch<CheerService>();
    Widget row(String p) {
      final box = cheer.boxOf(p);
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('cheer.urlOf', {'provider': _providerName(p)}), style: theme.textTheme.bodyLarge),
              const SizedBox(height: 2),
              box == null
                  ? Text(tr('cheer.notSet'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
                  : PrivateText(box.alertUrl, selectable: true, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 12),
          OutlinedButton(onPressed: () => showCheerSetupDialog(context), child: Text(tr('cheer.edit'))),
          if (box != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                await settings.setAlertUrlOf(p, '');
                // None left: off.
                if (!cheer.configured) await settings.setCheerEnabled(false);
              },
              child: Text(tr('cheer.remove')),
            ),
          ],
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The same switch as at the top of 直播工具 (asks for a payment
      // service first when none is set up).
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(cheer.configured ? tr('cheer.titleWith', {'providers': _providerNames(cheer)}) : tr('cheer.title')),
        subtitle: Text(tr('cheer.hint')),
        value: cheer.enabled,
        onChanged: (v) => toggleCheer(context, v),
      ),
      const SizedBox(height: 4),
      for (final p in kCheerProviders) row(p),
      const SizedBox(height: 2),
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('cheer.rateTitle'), style: theme.textTheme.bodyLarge),
            const SizedBox(height: 2),
            Text(tr('cheer.rateHint'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 24),
        SizedBox(width: 130, child: _RateField(value: settings.cheerTwdPerPoint, onChanged: settings.setCheerTwdPerPoint)),
        const SizedBox(width: 8),
        Text(tr('cheer.rateUnit')),
      ]),
    ]);
  }
}

/// A whole number of NT$, at least [AppSettings.cheerTwdPerPointMin]; saved
/// as it is typed once it is that much, and put back to the saved rate when
/// left with less.
class _RateField extends StatefulWidget {
  const _RateField({required this.value, required this.onChanged});
  final int value;
  final Future<void> Function(int) onChanged;

  @override
  State<_RateField> createState() => _RateFieldState();
}

class _RateFieldState extends State<_RateField> {
  static const _min = AppSettings.cheerTwdPerPointMin;
  late final TextEditingController _c = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) return;
      final n = int.tryParse(_c.text.trim());
      if (n == null || n < _min) setState(() => _c.text = '${widget.value}');
    });
  }

  @override
  void didUpdateWidget(_RateField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && int.tryParse(_c.text) != widget.value) _c.text = '${widget.value}';
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = int.tryParse(_c.text.trim());
    return TextField(
      controller: _c,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.end,
      decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), errorText: v == null || v < _min ? tr('cheer.rateMin', {'n': _min}) : null),
      onChanged: (s) {
        final n = int.tryParse(s.trim());
        if (n != null && n >= _min) widget.onChanged(n);
        setState(() {});
      },
    );
  }
}
