// The scoring rules page's SSS demo songs: the two takes of 奇幻島 shown on
// the website (site/index.html, #demo), laid out the same way (song and
// singer, total, the six sub-score bars, the onset judgements and the AI
// feedback), with a download button instead of the video. A downloaded
// replay is imported into the Replays tab right away.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../services/downloader.dart';
import '../../services/replay_library.dart';
import '../../services/settings.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../replays/replays_screen.dart' show replayImportError;
import '../shell.dart';
import '../widgets/score_colors.dart';
import '../widgets/shine.dart';
import 'demo_video_dialog.dart';

/// Where the website keeps the replay files (GitHub Pages, site/assets).
const demoReplayBase = 'https://hikari-tsai.github.io/karaoke-battle/assets';

class SssDemo {
  const SssDemo({
    required this.key,
    required this.file,
    required this.video,
    required this.total,
    required this.singer,
    required this.voicebank,
    required this.bars,
    required this.judges,
  });

  /// Also the suffix of its AI feedback text (`demo.c<key>`).
  final String key;
  final String file;

  /// The take exported with the app's "Export video" (on the website).
  final String video;
  final double total;
  final String singer;
  final bool voicebank;

  /// Pitch, rhythm, stability, vibrato, expression, long notes; null: not
  /// scored (no vibrato in the song).
  final List<int?> bars;

  /// PERFECT, GREAT, GOOD, MISS.
  final List<int> judges;
}

/// The numbers are the ones on the website.
const sssDemos = [
  SssDemo(key: '992', file: 'replay-992.zip', video: 'demo-992.mp4', total: 99.2, singer: '夏語遙', voicebank: true, bars: [100, 95, 100, null, 100, 100], judges: [38, 10, 2, 0]),
  SssDemo(key: '987', file: 'replay-987.zip', video: 'demo-987.mp4', total: 98.7, singer: '家家', voicebank: false, bars: [100, 92, 100, null, 100, 100], judges: [42, 2, 4, 2]),
];

// The website's colours (site/styles.css).
const _bg = Color(0xFF131317);
const _line = Color(0x17FFFFFF);
const _muted = Color(0xFFAAA6BA);
const _lav = Color(0xFFC8BEFA);
const _magenta = Color(0xFF9E266C);
const _pink = Color(0xFFFF4FA3);
const _yellow = Color(0xFFF9D84A);
const _orange = Color(0xFFF2A93B);
const _voicebank = Color(0xFF7FD8FF);
const _judgeColors = [Color(0xFFFFD60A), Color(0xFFFF4FA3), Color(0xFF30D158), Color(0xFF8E8E93)];
const _judgeNames = ['PERFECT', 'GREAT', 'GOOD', 'MISS'];
const _barKeys = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'longTone'];
const _tabular = [FontFeature.tabularFigures()];

/// The website's entrance easing (cubic-bezier(0.16, 1, 0.3, 1)).
const _ease = Cubic(0.16, 1, 0.3, 1);

class SssDemos extends StatefulWidget {
  const SssDemos({super.key});

  @override
  State<SssDemos> createState() => _SssDemosState();
}

class _SssDemosState extends State<SssDemos> with TickerProviderStateMixin {
  final _downloader = Downloader();

  /// Demos being fetched: download fraction, or null while importing.
  final _busy = <String, double?>{};

  /// The entrance: count-up, bars, judgements, AI feedback. Played when the
  /// cards come into view, again each time the tab is opened.
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  /// The effects that keep going (badge shine, glow, sparkles), only while
  /// the cards are on screen.
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
  ScrollPosition? _position;
  ValueListenable<TickerModeData>? _tab;
  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _position) {
      _position?.removeListener(_checkSoon);
      _position = pos?..addListener(_checkSoon);
    }
    // Shown or hidden with its tab.
    final tab = TickerMode.getValuesNotifier(context);
    if (tab != _tab) {
      _tab?.removeListener(_checkSoon);
      _tab = tab..addListener(_checkSoon);
    }
    _checkSoon();
  }

  @override
  void dispose() {
    _position?.removeListener(_checkSoon);
    _tab?.removeListener(_checkSoon);
    _intro.dispose();
    _loop.dispose();
    super.dispose();
  }

  /// After the next layout, when the scrolled positions are up to date.
  void _checkSoon() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _check())
      ..ensureVisualUpdate();
  }

  void _check() {
    if (!mounted) return;
    if (!(_tab?.value.enabled ?? true)) {
      // Another tab: start over when this one is opened again.
      _played = false;
      _intro.value = 0;
      _loop.stop();
      return;
    }
    final onScreen = _onScreen();
    if (onScreen && !_played) {
      _played = true;
      _intro.forward(from: 0);
    }
    if (onScreen && !_loop.isAnimating) _loop.repeat();
    if (!onScreen && _loop.isAnimating) _loop.stop();
  }

  /// Whether the score part of the cards is in the scrolled view.
  bool _onScreen() {
    final box = context.findRenderObject() as RenderBox?;
    final view = Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || view == null || !view.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final viewTop = view.localToGlobal(Offset.zero).dy;
    return top + box.size.height * 0.4 < viewTop + view.size.height && top + box.size.height > viewTop + 80;
  }

  Future<void> _download(SssDemo d) async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy[d.key] = 0);
    final tmp = p.join(services.paths.cache, 'demo_${d.file}');
    try {
      await Directory(services.paths.cache).create(recursive: true);
      await _downloader.download(
        Uri.parse('$demoReplayBase/${d.file}'),
        tmp,
        onProgress: (pr) {
          if (mounted) setState(() => _busy[d.key] = pr.fraction);
        },
      );
      if (mounted) setState(() => _busy[d.key] = null);
      final list = await services.replays.import(tmp);
      await services.settings.setDemoReplay(d.key, list.first.id);
      messenger?.showSnackBar(SnackBar(
        content: Text(tr('demo.saved', {'title': list.first.title})),
        persist: false, // an action makes it stay by default
        action: SnackBarAction(label: tr('demo.open'), onPressed: () => AppShell.tabRequest.value = AppShell.replaysIndex),
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(tr('demo.failed', {'error': replayImportError(e)}))));
    } finally {
      try {
        await File(tmp).delete();
      } catch (_) {}
      if (mounted) setState(() => _busy.remove(d.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = context.watch<AppSettings>().demoReplays;
    final replays = context.watch<ReplayLibrary>().items;
    // Deleting the replay from the Replays tab offers the download again.
    bool inReplays(SssDemo d) => saved[d.key] != null && replays.any((r) => r.id == saved[d.key]);
    Widget card(int i) => _DemoCard(
          demo: sssDemos[i],
          index: i,
          intro: _intro,
          loop: _loop,
          busy: _busy.containsKey(sssDemos[i].key),
          fraction: _busy[sssDemos[i].key],
          inReplays: inReplays(sssDemos[i]),
          onDownload: () => _download(sssDemos[i]),
        );
    return LayoutBuilder(builder: (context, c) {
      // Not too wide: the rules page is already centred at a reading width.
      final width = c.maxWidth.clamp(0.0, 960.0);
      final Widget cards;
      if (width < 760) {
        cards = Column(children: [
          for (var i = 0; i < sssDemos.length; i++) ...[if (i > 0) const SizedBox(height: 20), card(i)],
        ]);
      } else {
        cards = IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < sssDemos.length; i++) ...[if (i > 0) const SizedBox(width: 24), Expanded(child: card(i))],
          ]),
        );
      }
      return Align(alignment: Alignment.topCenter, child: SizedBox(width: width, child: cards));
    });
  }
}

class _DemoCard extends StatefulWidget {
  const _DemoCard({
    required this.demo,
    required this.index,
    required this.intro,
    required this.loop,
    required this.busy,
    required this.fraction,
    required this.inReplays,
    required this.onDownload,
  });
  final SssDemo demo;
  final int index;
  final Animation<double> intro;
  final Animation<double> loop;
  final bool busy;
  final double? fraction;
  final bool inReplays;
  final VoidCallback onDownload;

  @override
  State<_DemoCard> createState() => _DemoCardState();
}

class _DemoCardState extends State<_DemoCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.demo;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Lifts and turns gold under the pointer, as on the website.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _bg,
          border: Border.all(color: _hover ? const Color(0x59F9D84A) : _line),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            const BoxShadow(color: Color(0x59000000), blurRadius: 60, offset: Offset(0, 24)),
            if (_hover) const BoxShadow(color: Color(0x1FF9D84A), blurRadius: 40),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // --- where the website has the video: the cover and the download ---
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              AnimatedScale(
                scale: _hover ? 1.04 : 1,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                child: Image.asset('assets/images/fantasy_island.jpg', fit: BoxFit.cover),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x26000000), Color(0x99000000)]),
                ),
              ),
              // The website's play button: the video in a dialog.
              Center(
                child: _PlayButton(
                  hover: _hover,
                  onTap: () => showDemoVideo(
                    context,
                    url: '$demoReplayBase/${d.video}',
                    title: '${tr('demo.song')}・${tr('demo.singer', {'name': d.singer})}',
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Center(child: _DownloadButton(busy: widget.busy, fraction: widget.fraction, inReplays: widget.inReplays, onDownload: widget.onDownload)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
            child: AnimatedBuilder(
              animation: Listenable.merge([widget.intro, widget.loop]),
              builder: (context, _) => _score(context, d),
            ),
          ),
        ]),
      ),
    );
  }

  /// [a]..[b] of the entrance (0..1), eased; the second card a little later.
  double _at(double a, double b, [Curve curve = _ease]) {
    final t = ((widget.intro.value - a - widget.index * 0.06) / (b - a)).clamp(0.0, 1.0);
    return curve.transform(t);
  }

  Widget _score(BuildContext context, SssDemo d) {
    final theme = Theme.of(context);
    final tag = d.voicebank ? _voicebank : _pink;
    final loop = widget.loop.value;
    final count = _at(0, 0.5, Curves.easeOutCubic);
    final glow = 0.5 + 0.5 * math.sin(loop * 2 * math.pi);
    final judges = _at(0.4, 0.72);
    final ai = _at(0.62, 0.9);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // --- song, singer and total ---
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('demo.song'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, height: 1.35, color: Colors.white)),
            const SizedBox(height: 2),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
              Text(tr('demo.singer', {'name': d.singer}), style: const TextStyle(fontSize: 14, color: _muted)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: tag.withValues(alpha: 0.12),
                  border: Border.all(color: tag.withValues(alpha: 0.45)),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(tr(d.voicebank ? 'demo.vb' : 'demo.live'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: tag)),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 16),
        Stack(clipBehavior: Clip.none, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            // The final number keeps the width while counting up.
            Stack(alignment: Alignment.centerRight, children: [
              Opacity(opacity: 0, child: Text(d.total.toStringAsFixed(1), style: _totalStyle(0))),
              Text((d.total * count).toStringAsFixed(1), style: _totalStyle(glow * count)),
            ]),
            const SizedBox(width: 10),
            Transform.scale(
              scale: _at(0.42, 0.66, Curves.elasticOut),
              child: _SssBadge(shine: _shine(loop)),
            ),
          ]),
          // Sparkles around the score once it has landed.
          for (final s in _sparkles)
            Positioned(
              left: s.$1,
              top: s.$2,
              child: Sparkle(size: s.$3, value: _at(0.5, 0.7) * math.max(0, math.sin((loop + s.$4) * 2 * math.pi))),
            ),
        ]),
      ]),
      const Padding(padding: EdgeInsets.symmetric(vertical: 18), child: Divider(height: 1, thickness: 1, color: _line)),
      // --- the six sub-scores, one after another ---
      for (var i = 0; i < _barKeys.length; i++) ...[
        _Bar(
          label: tr('results.${_barKeys[i]}'),
          value: d.bars[i],
          color: subScoreColor(_barKeys[i]),
          progress: _at(0.08 + i * 0.05, 0.55 + i * 0.05),
          shine: _shine(loop, delay: 0.04 * i),
        ),
        if (i < _barKeys.length - 1) const SizedBox(height: 10),
      ],
      const SizedBox(height: 22),
      // --- onset judgements ---
      Row(children: [
        Text(tr('demo.judge'), style: const TextStyle(fontSize: 13, color: _muted)),
        const Spacer(),
        Text('${(d.judges.fold<int>(0, (a, b) => a + b) * judges).round()}', style: const TextStyle(fontSize: 13, color: _muted, fontFeatures: _tabular)),
      ]),
      const SizedBox(height: 8),
      // Laid out at full width and revealed from the left, so the gaps
      // between the colours never squeeze.
      ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: judges,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(children: [
                for (var i = 0; i < 4; i++)
                  if (d.judges[i] > 0) ...[
                    if (d.judges.take(i).any((n) => n > 0)) const SizedBox(width: 2),
                    Expanded(flex: d.judges[i], child: ColoredBox(color: _judgeColors[i], child: const SizedBox.expand())),
                  ],
              ]),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Opacity(
        opacity: judges,
        child: Wrap(spacing: 14, runSpacing: 4, children: [
          for (var i = 0; i < 4; i++)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: _judgeColors[i], borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 6),
              Text(_judgeNames[i], style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _judgeColors[i])),
              const SizedBox(width: 4),
              Text('${(d.judges[i] * judges).round()}', style: const TextStyle(fontSize: 12, color: _muted, fontFeatures: _tabular)),
            ]),
        ]),
      ),
      const SizedBox(height: 20),
      // --- AI feedback: fades in last ---
      Opacity(
        opacity: ai,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - ai)),
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0x3D9E266C), Color(0x8C24103E)]),
              border: Border.all(color: const Color(0x33C8BEFA)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Transform.rotate(
                  angle: 0.25 * math.sin(loop * 2 * math.pi),
                  child: const Icon(Icons.auto_awesome, size: 16, color: _yellow),
                ),
                const SizedBox(width: 6),
                Text(tr('demo.ai'), style: const TextStyle(fontSize: 13, color: _lav, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 8),
              Text(tr('demo.c${d.key}'), style: theme.textTheme.bodyMedium?.copyWith(fontSize: 15, height: 1.75, color: const Color(0xFFE6E1F2))),
            ]),
          ),
        ),
      ),
    ]);
  }

  /// The total in the website's style; [glow] 0..1 brightens its halo.
  static TextStyle _totalStyle(double glow) => TextStyle(
        fontSize: 52,
        fontWeight: FontWeight.w900,
        height: 1,
        color: _yellow,
        fontFeatures: _tabular,
        shadows: [Shadow(color: _yellow.withValues(alpha: 0.25 + 0.3 * glow), blurRadius: 18 + 20 * glow)],
      );

  /// Where a band of light sweeping across is (-1..2 of the width), in the
  /// first part of each loop; null in between.
  double? _shine(double loop, {double delay = 0}) {
    final t = (loop - widget.index * 0.12 - delay) % 1.0;
    if (t > 0.3 || widget.intro.value < 0.8) return null;
    return -1 + 3 * Curves.easeInOut.transform(t / 0.3);
  }

  // (left, top, size, phase) around the total and its badge.
  static const _sparkles = [(-14.0, -12.0, 14.0, 0.0), (150.0, -16.0, 12.0, 0.33), (176.0, 44.0, 10.0, 0.66)];
}

/// The website's round yellow play button, pulsing gently.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.hover, required this.onTap});
  final bool hover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tr('demo.watch'),
        child: ShineTicker(builder: (context, t) {
          final pulse = t == null ? 0.0 : shinePulse(t, period: 2.0);
          return AnimatedScale(
            scale: hover ? 1.08 : 1,
            duration: const Duration(milliseconds: 200),
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _yellow,
                boxShadow: [
                  BoxShadow(color: _yellow.withValues(alpha: 0.12 + 0.12 * pulse), spreadRadius: 8 + 6 * pulse),
                  const BoxShadow(color: Color(0x80000000), blurRadius: 34, offset: Offset(0, 12)),
                ],
              ),
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.play_arrow_rounded, size: 40, color: Color(0xFF111111))),
                ),
              ),
            ),
          );
        }),
      );
}

/// The download button, at the bottom of the cover.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.busy, required this.fraction, required this.inReplays, required this.onDownload});
  final bool busy;
  final double? fraction;
  final bool inReplays;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return _Pill(
        background: const Color(0xE6131317),
        foreground: Colors.white,
        leading: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: _yellow, value: fraction == null || fraction == 0 ? null : fraction),
        ),
        title: fraction == null ? tr('demo.importing') : tr('demo.downloading', {'pct': '${(fraction! * 100).round()}'}),
      );
    }
    if (inReplays) {
      return _Pill(
        background: const Color(0xE6131317),
        foreground: Colors.white,
        border: const Color(0x8030D158),
        leading: const Icon(Icons.check_circle, color: Color(0xFF30D158)),
        title: tr('demo.inReplays'),
        subtitle: tr('demo.open'),
        onTap: () => AppShell.tabRequest.value = AppShell.replaysIndex,
      );
    }
    return _Pill(
      background: _yellow,
      foreground: const Color(0xFF111111),
      glow: true,
      leading: const Icon(Icons.download_rounded, color: Color(0xFF111111)),
      title: tr('demo.download'),
      subtitle: tr('demo.size', {'size': '1.9 MB'}),
      onTap: onDownload,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.background, required this.foreground, required this.leading, required this.title, this.subtitle, this.border, this.glow = false, this.onTap});
  final Color background;
  final Color foreground;
  final Color? border;
  final Widget leading;
  final String title;
  final String? subtitle;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          if (glow) const BoxShadow(color: Color(0x2EF9D84A), spreadRadius: 10),
          const BoxShadow(color: Color(0x80000000), blurRadius: 34, offset: Offset(0, 12)),
        ],
      ),
      child: Material(
        color: background,
        shape: StadiumBorder(side: border == null ? BorderSide.none : BorderSide(color: border!)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          mouseCursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 20, 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              leading,
              const SizedBox(width: 12),
              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: foreground)),
                if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.75))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SssBadge extends StatelessWidget {
  const _SssBadge({this.shine});

  /// Position of the sweeping light (see _DemoCardState._shine).
  final double? shine;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [BoxShadow(color: Color(0x73F9D84A), blurRadius: 18)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFF3A6), _yellow, _orange], stops: [0, 0.45, 1]),
              ),
              child: const Text('SSS', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 0.7, color: Color(0xFF111111))),
            ),
            if (shine != null) Positioned.fill(child: ShineBand(position: shine!)),
          ]),
        ),
      );
}

/// One sub-score in its colour (the same everywhere in the app), striped when
/// not scored. [progress] 0..1 fills it (the entrance); full bars glint when
/// [shine] passes.
class _Bar extends StatelessWidget {
  const _Bar({required this.label, required this.value, required this.color, this.progress = 1, this.shine});
  final String label;
  final int? value;

  /// The sub-score's colour (score_colors.dart), as everywhere in the app.
  final Color color;
  final double progress;
  final double? shine;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final full = v == 100;
    return Row(children: [
      SizedBox(width: 72, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: _muted))),
      const SizedBox(width: 12),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: v == null
                ? Opacity(opacity: progress.clamp(0.0, 1.0), child: const CustomPaint(painter: _Stripes()))
                : ColoredBox(
                    color: const Color(0x14FFFFFF),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (v / 100 * progress).clamp(0.0, 1.0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(fit: StackFit.expand, children: [
                          DecoratedBox(
                            decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withValues(alpha: 0.55), color])),
                          ),
                          if (full && shine != null) ShineBand(position: shine!, strength: 0.9),
                        ]),
                      ),
                    ),
                  ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      SizedBox(
        width: 34,
        child: Text(
          v == null ? '—' : '${(v * progress).round()}',
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 14,
            fontWeight: v == null ? FontWeight.w400 : FontWeight.w800,
            color: v == null ? _muted : (full && progress >= 1 ? color : Colors.white),
            fontFeatures: _tabular,
          ),
        ),
      ),
    ]);
  }
}

/// Diagonal stripes for a sub-score the song does not score.
class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0FFFFFFF)
      ..strokeWidth = 4;
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width + size.height; x += 8) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}
