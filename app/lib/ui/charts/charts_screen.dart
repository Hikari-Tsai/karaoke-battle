// "KTV charts" tab: the weekly request charts of Holiday, Cashbox, JOYSOUND
// and DAM, one section per operator with its own boards, errors and a link to
// the chart on the operator's website. Nothing is fetched until the tab is
// first shown.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ktv_charts.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../widgets/brand.dart';

/// Localized reason for a failed chart load.
String chartErrorText(Object e) {
  if (e is ChartException) return tr('charts.err.${e.kind.name}', {'detail': e.detail});
  return '$e';
}

class ChartsScreen extends StatefulWidget {
  const ChartsScreen({super.key, this.active = true, this.service});

  /// Whether the tab is showing; the first load waits for it.
  final bool active;

  /// Injected in tests; otherwise one is made with the app's cache folder.
  final KtvChartService? service;

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _VendorState {
  _VendorState(this.board);
  ChartBoard board;
  KtvChart? chart;
  Object? error;
  bool loading = false;
  bool expanded = false;
}

class _ChartsScreenState extends State<ChartsScreen> {
  KtvChartService? _service;
  bool _ownsService = false;
  final _vendors = {for (final e in KtvCharts.boards.entries) e.key: _VendorState(e.value.first)};

  @override
  void initState() {
    super.initState();
    if (widget.active) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didUpdateWidget(ChartsScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _start();
  }

  @override
  void dispose() {
    if (_ownsService) _service?.dispose();
    super.dispose();
  }

  void _start() {
    if (_service != null || !mounted) return;
    _service = widget.service;
    if (_service == null) {
      _service = KtvChartService(cacheDir: context.read<AppServices>().paths.cache);
      _ownsService = true;
    }
    for (final v in _vendors.keys) {
      _load(v);
    }
  }

  Future<void> _load(KtvVendor vendor, {bool force = false}) async {
    final s = _vendors[vendor]!;
    final board = s.board;
    setState(() {
      s.loading = true;
      s.error = null;
    });
    try {
      final chart = await _service!.load(board, force: force);
      if (!mounted || s.board != board) return;
      setState(() => s.chart = chart);
    } catch (e) {
      if (!mounted || s.board != board) return;
      setState(() => s.error = e);
    } finally {
      if (mounted && s.board == board) setState(() => s.loading = false);
    }
  }

  void _select(KtvVendor vendor, ChartBoard board) {
    final s = _vendors[vendor]!;
    if (s.board == board) return;
    setState(() {
      s.board = board;
      s.chart = null;
      s.expanded = false;
    });
    _load(vendor);
  }

  void _refreshAll() {
    if (_service == null) return _start();
    for (final v in _vendors.keys) {
      _load(v, force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _vendors.values.any((s) => s.loading);
    return Scaffold(
      appBar: AppBar(
        title: BrandedTitle(tr('charts.title')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(tooltip: tr('charts.refresh'), onPressed: busy ? null : _refreshAll, icon: const Icon(Icons.refresh)),
          ),
        ],
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(tr('charts.intro'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            for (final e in _vendors.entries) ...[
              _VendorSection(
                vendor: e.key,
                state: e.value,
                onSelect: (b) => _select(e.key, b),
                onRetry: () => _load(e.key, force: true),
                onToggle: () => setState(() => e.value.expanded = !e.value.expanded),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _VendorSection extends StatelessWidget {
  const _VendorSection({required this.vendor, required this.state, required this.onSelect, required this.onRetry, required this.onToggle});
  final KtvVendor vendor;
  final _VendorState state;
  final ValueChanged<ChartBoard> onSelect;
  final VoidCallback onRetry;
  final VoidCallback onToggle;

  static const _collapsed = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = tr('charts.vendor.${vendor.name}');
    final region = vendor == KtvVendor.holiday || vendor == KtvVendor.cashbox ? 'tw' : 'jp';
    final chart = state.chart;
    final meta = <String>[
      if (chart?.period?.isNotEmpty ?? false) tr('charts.period', {'period': chart!.period}),
      if (chart?.updated?.isNotEmpty ?? false) tr('charts.updated', {'date': chart!.updated}),
      if (chart != null) tr('charts.fetched', {'time': DateFormat('yyyy/MM/dd HH:mm').format(chart.fetchedAt)}),
    ];
    final entries = chart?.entries ?? const <ChartEntry>[];
    final shown = state.expanded ? entries : entries.take(_collapsed).toList();

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(6)),
                  child: Text(tr('charts.region.$region'), style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    meta.join('  ·  '),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in KtvCharts.boards[vendor]!)
                  ChoiceChip(label: Text(tr(b.labelKey)), selected: b == state.board, onSelected: (_) => onSelect(b)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(height: 2, child: state.loading ? const LinearProgressIndicator() : null),
            if (state.error != null)
              _ErrorRow(message: '${tr('charts.failed', {'vendor': name})}: ${chartErrorText(state.error!)}', onRetry: onRetry)
            else if (chart != null && entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(tr('charts.empty'), style: TextStyle(color: cs.onSurfaceVariant)),
              )
            else if (chart != null) ...[
              _HeaderRow(vendor: vendor),
              for (var i = 0; i < shown.length; i++) _EntryRow(entry: shown[i], vendor: vendor, shaded: i.isOdd),
              if (entries.length > _collapsed)
                Align(
                  child: TextButton(
                    onPressed: onToggle,
                    child: Text(state.expanded ? tr('charts.showLess') : tr('charts.showAll', {'n': entries.length})),
                  ),
                ),
            ] else
              const SizedBox(height: 48),
            const Divider(height: 16),
            Row(
              children: [
                Icon(Icons.public, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(tr('charts.source', {'vendor': name}), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                if (!KtvCharts.hasMovement(vendor))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(tr('charts.noMovement'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(state.board.officialUrl)),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(tr('charts.openSite', {'vendor': name})),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.error),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: cs.error))),
          OutlinedButton(onPressed: onRetry, child: Text(tr('retry'))),
        ],
      ),
    );
  }
}

// Column widths shared by the header and the rows.
const _rankW = 44.0;
const _moveW = 64.0;
const _noW = 96.0;

String _songNoLabel(KtvVendor v) => switch (v) {
  KtvVendor.dam => tr('charts.songNo.dam'),
  KtvVendor.joysound => tr('charts.songNo.joysound'),
  _ => tr('charts.songNo'),
};

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.vendor});
  final KtvVendor vendor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: _rankW, child: Text(tr('charts.rank'), style: style)),
          if (KtvCharts.hasMovement(vendor)) const SizedBox(width: _moveW),
          Expanded(flex: 5, child: Text(tr('charts.song'), style: style)),
          Expanded(flex: 4, child: Text(tr('charts.artist'), style: style)),
          SizedBox(width: _noW, child: Text(_songNoLabel(vendor), style: style, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.vendor, required this.shaded});
  final ChartEntry entry;
  final KtvVendor vendor;
  final bool shaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final top3 = entry.rank <= 3;
    return Container(
      color: shaded ? cs.surfaceContainerHighest.withValues(alpha: 0.35) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: _rankW,
            child: Text(
              '${entry.rank}',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: top3 ? Brand.magenta : null),
            ),
          ),
          if (KtvCharts.hasMovement(vendor)) SizedBox(width: _moveW, child: _Movement(entry: entry)),
          Expanded(
            flex: 5,
            child: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(entry.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
          SizedBox(
            width: _noW,
            child: Text(entry.songNo, textAlign: TextAlign.end, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }
}

class _Movement extends StatelessWidget {
  const _Movement({required this.entry});
  final ChartEntry entry;

  static const _up = Color(0xFF4CAF50);
  static const _down = Color(0xFFEF5350);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.labelMedium;
    if (entry.isNew) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(color: Brand.violet.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: Text(tr('charts.new'), style: small?.copyWith(color: Brand.violet, fontWeight: FontWeight.w700)),
        ),
      );
    }
    final m = entry.movement;
    if (m == null) return const SizedBox.shrink();
    final (IconData? icon, Color color, String tip) = m > 0
        ? (Icons.arrow_drop_up, _up, tr('charts.up', {'n': m}))
        : m < 0
        ? (Icons.arrow_drop_down, _down, tr('charts.down', {'n': -m}))
        : (null, cs.onSurfaceVariant, tr('charts.same'));
    return Tooltip(
      message: '$tip · ${tr('charts.lastWeek', {'n': entry.lastRank})}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) Icon(icon, color: color, size: 22) else SizedBox(width: 22, child: Text('–', textAlign: TextAlign.center, style: small?.copyWith(color: color))),
          if (m != 0) Text('${m.abs()}', style: small?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
