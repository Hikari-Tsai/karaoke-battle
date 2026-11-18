// "Hot songs" tab (熱門歌單): the request charts of Holiday, Cashbox, JOYSOUND
// and DAM and the KKBOX streaming charts, read from the KTV Charts site, one
// tab per source with its charts, the song's genre, BPM and chorus range, and
// links to hear it on Apple Music, Spotify or KKBOX (opened in the browser).
// A source is fetched the first time its tab is shown, and nothing before the
// "Hot songs" page itself is.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ktv_charts.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/song_data.dart';
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
  VendorCharts? data;

  /// The chosen chart id; the source's first chart until one is picked.
  String? boardId;
  Object? error;
  bool loading = false;
  bool expanded = false;

  KtvChart? get chart {
    final d = data;
    if (d == null) return null;
    // By default the weekly chart where a source has several periods.
    return (boardId == null ? null : d.chart(boardId!)) ?? d.charts.firstWhere((c) => c.board.id.contains('weekly'), orElse: () => d.charts.first);
  }
}

class _ChartsScreenState extends State<ChartsScreen> with SingleTickerProviderStateMixin {
  KtvChartService? _service;
  bool _ownsService = false;
  final _vendors = {for (final v in KtvVendor.values) v: _VendorState()};
  late final _tabs = TabController(length: _vendors.length, vsync: this)..addListener(_onTab);

  KtvVendor get _current => _vendors.keys.elementAt(_tabs.index);

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
    _tabs.dispose();
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
    _loadFirst(_current);
  }

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    setState(() {});
    if (_service != null) _loadFirst(_current);
  }

  /// Each source is fetched the first time its tab is shown.
  void _loadFirst(KtvVendor vendor) {
    final s = _vendors[vendor]!;
    if (s.data == null && s.error == null && !s.loading) _load(vendor);
  }

  Future<void> _load(KtvVendor vendor, {bool force = false}) async {
    final s = _vendors[vendor]!;
    setState(() {
      s.loading = true;
      s.error = null;
    });
    try {
      final data = await _service!.load(vendor, force: force);
      if (!mounted) return;
      setState(() => s.data = data);
    } catch (e) {
      if (!mounted) return;
      setState(() => s.error = e);
    } finally {
      if (mounted) setState(() => s.loading = false);
    }
  }

  void _select(KtvVendor vendor, ChartBoard board) {
    final s = _vendors[vendor]!;
    if (s.chart?.board == board) return;
    setState(() {
      s.boardId = board.id;
      s.expanded = false;
    });
  }

  void _refresh() {
    if (_service == null) return _start();
    _load(_current, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vendor = _current;
    final state = _vendors[vendor]!;
    return Scaffold(
      appBar: AppBar(
        title: BrandedTitle(tr('charts.title')),
        actions: [
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(KtvCharts.base)),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(tr('charts.openWeb')),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(tooltip: tr('charts.refresh'), onPressed: state.loading ? null : _refresh, icon: const Icon(Icons.refresh)),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tabs: [for (final e in _vendors.entries) _VendorTab(vendor: e.key, failed: e.value.error != null)],
        ),
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(tr('charts.intro'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            _VendorSection(
              key: ValueKey(vendor),
              vendor: vendor,
              state: state,
              onSelect: (b) => _select(vendor, b),
              onRetry: () => _load(vendor, force: true),
              onToggle: () => setState(() => state.expanded = !state.expanded),
            ),
          ],
        ),
      ),
    );
  }
}

String _vendorName(KtvVendor v) => tr('charts.vendor.${v.name}');

String _region(KtvVendor v) => tr('charts.region.${KtvCharts.region(v)}');

/// Operator name and region; an error mark while its chart failed to load.
class _VendorTab extends StatelessWidget {
  const _VendorTab({required this.vendor, required this.failed});
  final KtvVendor vendor;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_vendorName(vendor), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(6)),
            child: Text(_region(vendor), style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
          if (failed) ...[
            const SizedBox(width: 6),
            Icon(Icons.error_outline, size: 16, color: cs.error),
          ],
        ],
      ),
    );
  }
}

class _VendorSection extends StatelessWidget {
  const _VendorSection({super.key, required this.vendor, required this.state, required this.onSelect, required this.onRetry, required this.onToggle});
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
    final name = _vendorName(vendor);
    final chart = state.chart;
    final data = state.data;
    final fmt = DateFormat('yyyy/MM/dd HH:mm');
    final meta = <String>[
      if (chart?.period?.isNotEmpty ?? false) tr('charts.period', {'period': chart!.period}),
      if (chart?.fetchedAt != null) tr('charts.fetched', {'time': fmt.format(chart!.fetchedAt!)}),
    ];
    final notes = <String>[
      if (data?.offline ?? false) tr('charts.offline', {'time': fmt.format(data!.downloadedAt)}),
      if (chart?.stale ?? false) tr('charts.stale', {'vendor': name}),
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final b in data?.boards ?? const <ChartBoard>[])
                  ChoiceChip(label: Text(b.label(I18n.lang)), selected: b == chart?.board, onSelected: (_) => onSelect(b)),
              ],
            ),
            const SizedBox(height: 10),
            Text(meta.join('  ·  '), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 16, color: cs.tertiary),
                    const SizedBox(width: 6),
                    Expanded(child: Text(n, style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary))),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(height: 2, child: state.loading ? const LinearProgressIndicator() : null),
            if (state.error != null)
              _ErrorRow(message: '${tr('charts.failed', {'vendor': name})}: ${chartErrorText(state.error!)}', onRetry: onRetry)
            else if (chart != null && entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(tr('charts.empty'), style: TextStyle(color: cs.onSurfaceVariant)),
              )
            else if (chart != null) ...[
              _HeaderRow(vendor: vendor, chart: chart),
              for (var i = 0; i < shown.length; i++) _EntryRow(entry: shown[i], vendor: vendor, chart: chart, shaded: i.isOdd),
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
                if (chart?.board.sourceUrl != null)
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(chart!.board.sourceUrl!)),
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
const _ytW = 44.0;

String _songNoLabel(KtvVendor v) => switch (v) {
  KtvVendor.dam => tr('charts.songNo.dam'),
  KtvVendor.joysound => tr('charts.songNo.joysound'),
  _ => tr('charts.songNo'),
};

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.vendor, required this.chart});
  final KtvVendor vendor;
  final KtvChart chart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: _rankW, child: Text(tr('charts.rank'), style: style)),
          if (chart.hasMovement) const SizedBox(width: _moveW),
          Expanded(flex: 5, child: Text(tr('charts.song'), style: style)),
          Expanded(flex: 4, child: Text(tr('charts.artist'), style: style)),
          if (chart.hasSongNo) SizedBox(width: _noW, child: Text(_songNoLabel(vendor), style: style, textAlign: TextAlign.end)),
          const SizedBox(width: _ytW * 2),
        ],
      ),
    );
  }
}

/// `C4–D5`, with a tooltip on how it suits male and female voices.
String _rangeText(ChartRange r) => '${noteName(r.low.toDouble())}–${noteName(r.high.toDouble())}';

String _voiceText(({String verdict, int key})? v) {
  if (v == null) return '—';
  final verdict = tr('charts.fit.${v.verdict}');
  if (v.key == 0) return verdict;
  return '$verdict（${tr('charts.fit.key', {'k': v.key > 0 ? '+${v.key}' : '${v.key}'})}）';
}

/// A model tag in the UI language (genre names stay as they are).
String _tagText(String group, String tag) {
  if (group == 'genre') return tag;
  final k = 'charts.t.$tag';
  final t = tr(k);
  return t == k ? tag : t;
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.vendor, required this.chart, required this.shaded});
  final ChartEntry entry;
  final KtvVendor vendor;
  final KtvChart chart;
  final bool shaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final top3 = entry.rank <= 3;
    final small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final range = entry.range;
    final details = <Widget>[
      if (entry.genre != null) Text(entry.genre!, style: small),
      if (entry.bpm != null) Tooltip(message: tr('charts.bpmTip'), child: Text('${entry.bpm} BPM', style: small)),
      if (range != null)
        Tooltip(
          message: tr('charts.rangeTip', {'m': _voiceText(range.male), 'f': _voiceText(range.female)}),
          child: Text(tr('charts.range', {'range': _rangeText(range)}), style: small),
        ),
      if (entry.tags.isNotEmpty)
        Tooltip(
          message: [
            for (final e in entry.tags.entries) '${tr('charts.tag.${e.key}')}：${e.value.map((t) => _tagText(e.key, t)).join('、')}',
          ].join('\n'),
          child: Icon(Icons.sell_outlined, size: 14, color: cs.onSurfaceVariant),
        ),
    ];
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
          if (chart.hasMovement) SizedBox(width: _moveW, child: _Movement(entry: entry)),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                if (details.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: details),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(entry.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
          if (chart.hasSongNo)
            SizedBox(
              width: _noW,
              child: Text(entry.songNo, textAlign: TextAlign.end, style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ),
          SizedBox(width: _ytW, child: _ListenMenu(entry: entry, region: KtvCharts.region(vendor))),
          SizedBox(
            width: _ytW,
            child: IconButton(
              tooltip: tr('charts.youtube'),
              icon: const Icon(Icons.smart_display_outlined, size: 20),
              visualDensity: VisualDensity.compact,
              color: cs.onSurfaceVariant,
              onPressed: () => launchUrl(entry.youtubeSearchUrl),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where to hear the song: the services' own pages, opened in the browser
/// (an exact match when the site found one, else a search there).
class _ListenMenu extends StatelessWidget {
  const _ListenMenu({required this.entry, required this.region});
  final ChartEntry entry;
  final String region;

  static const _names = {ListenService.apple: 'Apple Music', ListenService.spotify: 'Spotify', ListenService.kkbox: 'KKBOX'};

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final exact = ListenService.values.where(entry.hasListen).toList();
    return PopupMenuButton<ListenService>(
      tooltip: tr('charts.listen'),
      icon: Icon(exact.isEmpty ? Icons.headphones_outlined : Icons.headphones, size: 20, color: exact.isEmpty ? cs.onSurfaceVariant : cs.primary),
      onSelected: (s) => launchUrl(entry.listenUrl(s, region: region)),
      itemBuilder: (_) => [
        for (final s in ListenService.values)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                Icon(entry.hasListen(s) ? Icons.play_circle_outline : Icons.search, size: 18),
                const SizedBox(width: 10),
                Text(tr(entry.hasListen(s) ? 'charts.listenOn' : 'charts.searchOn', {'service': _names[s]})),
              ],
            ),
          ),
      ],
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
