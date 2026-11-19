// "Hot songs" tab (熱門歌單): the request charts of Holiday, Cashbox, JOYSOUND
// and DAM and the KKBOX streaming charts, read from the KTV Charts site, one
// tab per source with its charts, the song's genre, BPM and chorus range, and
// links to hear it on Apple Music, Spotify or KKBOX (opened in the browser).
// A source is fetched the first time its tab is shown, and nothing before the
// "Hot songs" page itself is.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ktv_charts.dart';
import '../../services/settings.dart';
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
            Text(tr('charts.about.${vendor.name}'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
    final own = _ownRange(context);

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
              for (var i = 0; i < shown.length; i++) _EntryRow(entry: shown[i], vendor: vendor, chart: chart, own: own, shaded: i.isOdd),
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
                  child: Text(tr(vendor == KtvVendor.vtuber ? 'charts.source.vtuber' : 'charts.source', {'vendor': name}), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                if (chart?.board.sourceUrl != null)
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(chart!.board.sourceUrl!)),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(vendor == KtvVendor.vtuber ? tr('charts.openPlaylist') : tr('charts.openSite', {'vendor': name})),
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
const _rangeW = 170.0;
const _coversW = 120.0;
const _btnW = 44.0;

/// The singer's own range (MIDI keys held on the microphone), if measured.
({int low, int high})? _ownRange(BuildContext context) {
  try {
    final keys = context.watch<AppSettings>().ownRangeKeys;
    if (keys.isEmpty) return null;
    return (low: keys.reduce(math.min), high: keys.reduce(math.max));
  } catch (_) {
    return null; // no settings (tests)
  }
}

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
          Expanded(flex: 5, child: Text(tr(vendor == KtvVendor.vtuber ? 'charts.songOriginal' : 'charts.songArtist'), style: style)),
          Expanded(flex: 4, child: Text(tr('charts.tags'), style: style)),
          SizedBox(width: _rangeW, child: Text(tr('charts.rangeCol'), style: style)),
          if (vendor == KtvVendor.vtuber) SizedBox(width: _coversW, child: Text(tr('charts.covers'), style: style)),
          const SizedBox(width: _btnW * 2),
        ],
      ),
    );
  }
}

/// A model tag in the UI language (genre names stay as they are).
String _tagText(String group, String tag) {
  if (group == 'genre') return tag;
  final k = 'charts.t.$tag';
  final t = tr(k);
  return t == k ? tag : t;
}

String _voiceText(({String verdict, int key})? v) {
  if (v == null) return '—';
  final verdict = tr('charts.fit.${v.verdict}');
  if (v.key == 0) return verdict;
  return '$verdict（${tr('charts.fit.key', {'k': v.key > 0 ? '+${v.key}' : '${v.key}'})}）';
}

/// How the chorus sits in the singer's range: inside, or the key change that
/// brings it in, or wider than the singer.
enum _Fit { inside, shift, wider }

({_Fit fit, int shift}) _fitTo(ChartRange r, ({int low, int high}) own) {
  if (r.low >= own.low && r.high <= own.high) return (fit: _Fit.inside, shift: 0);
  if (r.high - r.low > own.high - own.low) return (fit: _Fit.wider, shift: 0);
  final shift = r.high > own.high ? own.high - r.high : own.low - r.low;
  return (fit: _Fit.shift, shift: shift);
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.vendor, required this.chart, required this.own, required this.shaded});
  final ChartEntry entry;
  final KtvVendor vendor;
  final KtvChart chart;
  final ({int low, int high})? own;
  final bool shaded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final top3 = entry.rank <= 3;
    final small = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
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
                _ArtistLine(entry: entry, style: small),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: _TagChips(entry: entry)),
          SizedBox(width: _rangeW, child: entry.range == null ? const SizedBox.shrink() : _RangeBar(range: entry.range!, own: own)),
          if (vendor == KtvVendor.vtuber) SizedBox(width: _coversW, child: _CoversMenu(entry: entry)),
          SizedBox(width: _btnW, child: _ListenMenu(entry: entry)),
          SizedBox(
            width: _btnW,
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

/// The artist, then the release year and record label when known; the
/// tooltip adds the album and the full date.
class _ArtistLine extends StatelessWidget {
  const _ArtistLine({required this.entry, required this.style});
  final ChartEntry entry;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final release = [?entry.year, ?entry.label].join(' · ');
    final tip = [
      if (entry.album != null) tr('charts.album', {'album': entry.album}),
      if (entry.released != null || entry.label != null) tr('charts.released', {'date': entry.released ?? entry.year ?? '—', 'label': entry.label ?? '—'}),
    ].join('\n');
    final line = Text.rich(
      TextSpan(children: [
        TextSpan(text: entry.artist, style: style?.copyWith(fontSize: (style?.fontSize ?? 12) + 1, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.82))),
        if (release.isNotEmpty) TextSpan(text: '  ·  $release'),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: tip.isEmpty ? line : Tooltip(message: tip, child: line),
    );
  }
}

/// Coloured tags: the genre (iTunes) and tempo, then the model tags by group
/// (genre, mood, instruments, vocals), each group in its own colour. Up to
/// [_max] are shown; the rest are in the tooltip of a "+N" chip.
class _TagChips extends StatelessWidget {
  const _TagChips({required this.entry});
  final ChartEntry entry;

  static const _max = 6;
  static const _colors = <String, Color>{
    'itunes': Color(0xFFB39DDB), // violet
    'bpm': Color(0xFF90A4AE), // grey blue
    'genre': Color(0xFF4DB6AC), // teal
    'mood': Color(0xFFFFB74D), // amber
    'instrument': Color(0xFF64B5F6), // blue
    'vocal': Color(0xFFF48FB1), // pink
  };

  @override
  Widget build(BuildContext context) {
    final tags = <(String group, String text, String tip)>[
      if (entry.genre != null) ('itunes', entry.genre!, tr('charts.tag.itunes')),
      if (entry.bpm != null) ('bpm', '${entry.bpm} BPM', tr('charts.bpmTip')),
      for (final g in const ['genre', 'mood', 'instrument', 'vocal'])
        for (final t in entry.tags[g] ?? const <String>[]) (g, _tagText(g, t), tr('charts.tag.$g')),
    ];
    // The same genre named by both sources is shown once.
    final seen = <String>{};
    final unique = [for (final t in tags) if (seen.add(t.$2.toLowerCase())) t];
    final shown = unique.take(_max).toList(), rest = unique.skip(_max).toList();
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final (g, text, tip) in shown) Tooltip(message: tip, child: _Chip(text: text, color: _colors[g]!)),
        if (rest.isNotEmpty)
          Tooltip(
            message: [for (final (_, text, tip) in rest) '$tip：$text'].join('\n'),
            child: _Chip(text: '+${rest.length}', color: _colors['bpm']!),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      border: Border.all(color: color.withValues(alpha: 0.45)),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: TextStyle(fontSize: 11.5, height: 1.3, color: color, fontWeight: FontWeight.w600)),
  );
}

/// The chorus range on a small keyboard scale (E2–C6): a pill from its
/// lowest to highest note over the singer's own range (a lighter band) when
/// it is known, coloured by how well it fits, with the notes beside it.
class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.range, required this.own});
  final ChartRange range;
  final ({int low, int high})? own;

  static const _scaleLow = 40, _scaleHigh = 84; // E2 .. C6
  static const _ok = Color(0xFF4CAF50), _shift = Color(0xFFFFB74D), _wide = Color(0xFFEF5350);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final notes = '${noteName(range.low.toDouble())}–${noteName(range.high.toDouble())}';
    final o = own;
    final fit = o == null ? null : _fitTo(range, o);
    final color = switch (fit?.fit) {
      null => cs.primary,
      _Fit.inside => _ok,
      _Fit.shift => _shift,
      _Fit.wider => _wide,
    };
    final lines = [
      tr('charts.rangeTip', {'range': notes}),
      if (o != null)
        '${tr('charts.yourRange', {'range': '${noteName(o.low.toDouble())}–${noteName(o.high.toDouble())}'})}：${switch (fit!.fit) {
          _Fit.inside => tr('charts.fitYou.inside'),
          _Fit.shift => tr('charts.fitYou.shift', {'k': fit.shift > 0 ? '+${fit.shift}' : '${fit.shift}'}),
          _Fit.wider => tr('charts.fitYou.wider'),
        }}',
      tr('charts.rangeVoices', {'m': _voiceText(range.male), 'f': _voiceText(range.female)}),
    ];
    return Tooltip(
      message: lines.join('\n'),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            height: 14,
            child: CustomPaint(
              painter: _RangePainter(
                low: range.low,
                high: range.high,
                own: o,
                color: color,
                track: cs.onSurface.withValues(alpha: 0.12),
                band: cs.onSurface.withValues(alpha: 0.22),
                scaleLow: _scaleLow,
                scaleHigh: _scaleHigh,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(notes, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant))),
        ],
      ),
    );
  }
}

class _RangePainter extends CustomPainter {
  _RangePainter({required this.low, required this.high, required this.own, required this.color, required this.track, required this.band, required this.scaleLow, required this.scaleHigh});
  final int low, high, scaleLow, scaleHigh;
  final ({int low, int high})? own;
  final Color color, track, band;

  double _x(int midi, Size size) => (midi.clamp(scaleLow, scaleHigh) - scaleLow) / (scaleHigh - scaleLow) * size.width;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromLTRBR(0, mid - 2, size.width, mid + 2, const Radius.circular(2)), Paint()..color = track);
    final o = own;
    if (o != null) {
      canvas.drawRRect(RRect.fromLTRBR(_x(o.low, size), 1, _x(o.high, size), size.height - 1, r), Paint()..color = band);
    }
    final a = _x(low, size), b = math.max(_x(high, size), a + 3);
    canvas.drawRRect(RRect.fromLTRBR(a, mid - 4, b, mid + 4, const Radius.circular(4)), Paint()..color = color);
    // C4 tick, for orientation.
    final c4 = _x(60, size);
    canvas.drawLine(Offset(c4, size.height - 2), Offset(c4, size.height), Paint()..color = track.withValues(alpha: 0.6)..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_RangePainter old) => old.low != low || old.high != high || old.own != own || old.color != color;
}

/// Where to hear the song: the services that have it, opened in the browser.
/// Hidden when none does.
class _ListenMenu extends StatelessWidget {
  const _ListenMenu({required this.entry});
  final ChartEntry entry;

  static const _names = {ListenService.apple: 'Apple Music', ListenService.spotify: 'Spotify', ListenService.kkbox: 'KKBOX'};

  @override
  Widget build(BuildContext context) {
    final services = entry.listenServices;
    if (services.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<ListenService>(
      tooltip: tr('charts.listen'),
      icon: Icon(Icons.headphones, size: 20, color: Theme.of(context).colorScheme.primary),
      onSelected: (s) => launchUrl(entry.listenUrl(s)!),
      itemBuilder: (_) => [
        for (final s in services)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                const Icon(Icons.play_circle_outline, size: 18),
                const SizedBox(width: 10),
                Text(tr('charts.listenOn', {'service': _names[s]})),
              ],
            ),
          ),
      ],
    );
  }
}

/// VTuber chart: the cover count, opening a list of who sang it (each one's
/// video on YouTube).
class _CoversMenu extends StatelessWidget {
  const _CoversMenu({required this.entry});
  final ChartEntry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = entry.covers ?? entry.performers.length;
    if (entry.performers.isEmpty) return Text(tr('charts.coverCount', {'n': n}));
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<String>(
        tooltip: tr('charts.coversTip'),
        onSelected: (id) => launchUrl(ChartEntry.youtubeVideo(id)),
        itemBuilder: (_) => [
          for (final p in entry.performers)
            PopupMenuItem(
              value: p.video,
              child: Row(
                children: [
                  const Icon(Icons.smart_display_outlined, size: 18),
                  const SizedBox(width: 10),
                  Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('charts.coverCount', {'n': n}), style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
              Icon(Icons.arrow_drop_down, color: cs.primary),
            ],
          ),
        ),
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
