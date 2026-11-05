// Synced lyrics over the video / visualiser: the current line fills from left
// to right as it is sung, its translation below, and the next line dimmed.
// On each new line the next line flips up into the current slot while the
// sung line slides up and fades out.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import '../lyrics/lyrics_actions.dart';

class LyricsOverlay extends StatelessWidget {
  const LyricsOverlay({super.key, required this.lyrics, required this.position, this.noteOnsets, this.noteOffsets, this.showRomaji = true});
  final Lyrics lyrics;

  /// Show the romanised reading under Japanese lines when available.
  final bool showRomaji;
  final ValueListenable<double> position;

  /// Transcribed notes (sorted by onset) that drive the wipe note by note;
  /// without them the wipe is linear over each line.
  final List<double>? noteOnsets;
  final List<double>? noteOffsets;

  static const _shadow = [Shadow(color: Colors.black, blurRadius: 6), Shadow(color: Colors.black, blurRadius: 2)];

  /// Seconds a line takes to flip up from the small next-line slot to the
  /// current one, while the line before it slides up and fades out. Driven
  /// by the playback position, so it follows seeks and pauses.
  static const flipSeconds = 0.35;

  static double _ease(double x) => Curves.easeOutCubic.transform(x.clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final display = lyrics.shifted(); // the user's timing offsets
    final main = display.primaryTrack;
    if (main == null) return const SizedBox.shrink();
    final trans = display.secondaryTrack;
    return LayoutBuilder(builder: (context, c) {
      // Scale with the video height so it reads the same at any window size.
      final big = (c.maxHeight * 0.075).clamp(16.0, 40.0);
      final small = big * 0.62;
      return ValueListenableBuilder<double>(
        valueListenable: position,
        builder: (context, t, _) {
          final i = main.indexAt(t);
          final cur = i >= 0 ? main.lines[i] : null;
          final nextIdx = i >= 0 ? (i + 1 < main.lines.length ? i + 1 : -1) : main.nextAfter(t);
          final next = nextIdx >= 0 ? main.lines[nextIdx] : null;
          // Between lines, show the upcoming line (dimmed) up to 4 s ahead.
          final upcoming = cur == null && next != null && next.start - t <= 4 ? next : null;
          final tr2 = cur == null ? null : trans?.lineAt((cur.start + cur.end) / 2);
          final frac = cur == null
              ? 0.0
              : (noteOnsets != null && noteOffsets != null
                  ? noteWipeFraction(cur, noteOnsets!, noteOffsets!, t)
                  : ((t - cur.start) / (cur.end - cur.start).clamp(0.2, 1e9)).clamp(0.0, 1.0));

          // The line that was current before this one.
          final prevIdx = i >= 0 ? i - 1 : (nextIdx >= 0 ? nextIdx - 1 : main.lines.length - 1);
          final prev = prevIdx >= 0 ? main.lines[prevIdx] : null;
          bool romaji(LyricLine? l) => showRomaji && l?.romaji != null && l!.romaji!.isNotEmpty;

          // Main slot: the current line, or the upcoming one dimmed.
          final shown = cur ?? upcoming;
          Widget slot;
          if (cur != null) {
            slot = Column(mainAxisSize: MainAxisSize.min, children: [
              _WipeText(text: cur.text, fraction: frac, fontSize: big),
              if (romaji(cur)) _WipeText(text: cur.romaji!, fraction: frac, fontSize: small * 0.95, weight: FontWeight.w600),
            ]);
          } else if (upcoming != null) {
            slot = Column(mainAxisSize: MainAxisSize.min, children: [
              Text(upcoming.text, textAlign: TextAlign.center, style: TextStyle(fontSize: big, color: Colors.white54, fontWeight: FontWeight.w700, shadows: _shadow)),
              if (romaji(upcoming))
                Text(upcoming.romaji!, textAlign: TextAlign.center, style: TextStyle(fontSize: small * 0.95, color: Colors.white38, shadows: _shadow)),
            ]);
          } else {
            slot = SizedBox(height: big * 1.3);
          }

          // In: a line straight after the previous one was the small next
          // line, so it grows and rises from there; otherwise it was shown
          // dimmed from when the previous line ended (or 4 s ahead) and
          // fades in there.
          if (shown != null) {
            final flipped = cur != null && prev != null && cur.start - prev.end < flipSeconds;
            final inAt = flipped ? cur.start : math.max(prev?.end ?? double.negativeInfinity, shown.start - 4);
            final fromNext = flipped || (prev != null && prev.end > shown.start - 4);
            final p = _ease((t - inAt) / flipSeconds);
            if (p < 1) {
              // Distance from the next-line slot up to the main slot.
              final rise = big * 1.25 + (romaji(shown) ? small * 1.2 : 0) + (tr2 != null ? small * 1.2 + 2 : 0) + 4;
              slot = Opacity(
                opacity: fromNext ? 0.4 + 0.6 * p : p,
                child: Transform.translate(
                  offset: Offset(0, (1 - p) * (fromNext ? rise : big * 0.5)),
                  child: Transform.scale(scale: fromNext ? small / big + (1 - small / big) * p : 1, child: slot),
                ),
              );
            }
          }

          // Out: the previous line, fully sung, slides up and fades.
          if (prev != null) {
            final outAt = math.min(prev.end, cur?.start ?? double.infinity);
            final p = (t - outAt) / flipSeconds;
            if (p >= 0 && p < 1) {
              final e = _ease(p);
              slot = SizedBox(
                width: double.infinity,
                child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
                  slot,
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Opacity(
                      opacity: 1 - e,
                      child: Transform.translate(
                        offset: Offset(0, -e * big * 0.9),
                        child: Transform.scale(scale: 1 - 0.15 * e, child: Center(child: _WipeText(text: prev.text, fraction: 1, fontSize: big))),
                      ),
                    ),
                  ),
                ]),
              );
            }
          }

          // The translation and the next line come in with the current line.
          final pNext = cur == null ? 1.0 : _ease((t - cur.start) / flipSeconds);
          return Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(16, big * 1.2, 16, big * 0.5),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xB0000000)]),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                slot,
                if (tr2 != null)
                  Opacity(
                    opacity: pNext,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(tr2.text, textAlign: TextAlign.center, style: TextStyle(fontSize: small, color: Colors.white.withValues(alpha: 0.85), shadows: _shadow)),
                    ),
                  ),
                if (cur != null && next != null)
                  Opacity(
                    opacity: pNext,
                    child: Transform.translate(
                      offset: Offset(0, (1 - pNext) * small),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(next.text, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: small, color: Colors.white38, shadows: _shadow)),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    });
  }
}

/// A line drawn twice: white underneath and the sung part in gold on top,
/// clipped to [fraction] of the text width.
class _WipeText extends StatelessWidget {
  const _WipeText({required this.text, required this.fraction, required this.fontSize, this.weight = FontWeight.w800});
  final String text;
  final double fraction;
  final double fontSize;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, fontWeight: weight, height: 1.25, shadows: LyricsOverlay._shadow);
    return Stack(
      children: [
        Text(text, textAlign: TextAlign.center, style: base.copyWith(color: Colors.white)),
        ClipRect(
          clipper: _FractionClipper(fraction),
          child: Text(text, textAlign: TextAlign.center, style: base.copyWith(color: const Color(0xFFFFD60A))),
        ),
      ],
    );
  }
}

class _FractionClipper extends CustomClipper<Rect> {
  _FractionClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(_FractionClipper old) => old.fraction != fraction;
}

/// Corner menu over the stage: show / hide lyrics and romaji, pick the
/// lyrics track and a translation, shift the lyrics' timing, and import or
/// edit lyrics. The global show flags are settings; the track choice and
/// the timing offset are saved per song. Also shown for a song without
/// lyrics, so they can be added from here.
class LyricsMenu extends StatefulWidget {
  const LyricsMenu({
    super.key,
    required this.lyrics,
    required this.lyricsPath,
    required this.onChanged,
    this.onImport,
    this.onEdit,
    this.onWhisper,
    this.onPaste,
  });
  final Lyrics lyrics;
  final String lyricsPath;

  /// After a change saved to [lyricsPath] (track choice, offset).
  final VoidCallback onChanged;

  /// Import a subtitle file / open the editor; null disables them (while
  /// recording).
  final VoidCallback? onImport;
  final VoidCallback? onEdit;

  /// Recognise the lyrics with Whisper.
  final VoidCallback? onWhisper;

  /// Paste the lyrics as text and have them timed.
  final VoidCallback? onPaste;

  @override
  State<LyricsMenu> createState() => _LyricsMenuState();
}

class _LyricsMenuState extends State<LyricsMenu> {
  final _controller = MenuController();
  Timer? _saveLater;

  Lyrics get lyrics => widget.lyrics;

  Future<void> _save() async {
    try {
      await File(widget.lyricsPath).writeAsString(jsonEncode(lyrics.toJson()));
    } catch (_) {}
  }

  void _changed({bool now = true}) {
    widget.onChanged();
    _saveLater?.cancel();
    // Offset clicks come in bursts: write once they stop.
    _saveLater = Timer(Duration(milliseconds: now ? 0 : 400), _save);
    setState(() {});
  }

  @override
  void dispose() {
    if (_saveLater?.isActive ?? false) {
      _saveLater!.cancel();
      _save();
    }
    super.dispose();
  }

  void _close(VoidCallback? then) {
    _controller.close();
    then?.call();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final theme = Theme.of(context);
    final main = lyrics.primaryTrack;
    Widget check(bool on) => SizedBox(width: 24, child: on ? const Icon(Icons.check, size: 18) : null);
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
          child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        );
    return MenuAnchor(
      controller: _controller,
      alignmentOffset: const Offset(-300, 4),
      menuChildren: [
        if (main == null)
          header(tr('lyrics.noneYet'))
        else ...[
          CheckboxMenuButton(value: settings.showLyrics, onChanged: (_) => settings.setShowLyrics(!settings.showLyrics), child: Text(tr('sing.lyricsShow'))),
          if (main.hasRomaji)
            CheckboxMenuButton(value: settings.showRomaji, onChanged: (_) => settings.setShowRomaji(!settings.showRomaji), child: Text(tr('sing.lyricsRomaji'))),
          const Divider(height: 8),
          header(tr('sing.lyricsMain')),
          for (final t in lyrics.tracks)
            MenuItemButton(
              leadingIcon: check(t.lang == main.lang),
              onPressed: () {
                lyrics.primary = t.lang;
                if (lyrics.secondary == lyrics.primary) lyrics.secondary = null;
                _changed();
              },
              child: Text(lyricTrackLabel(t)),
            ),
          if (lyrics.tracks.length > 1) ...[
            const Divider(height: 8),
            header(tr('sing.lyricsTranslation')),
            MenuItemButton(
              leadingIcon: check(lyrics.secondaryTrack == null),
              onPressed: () {
                lyrics.secondary = null;
                _changed();
              },
              child: Text(tr('sing.lyricsNone')),
            ),
            for (final t in lyrics.tracks)
              if (t.lang != main.lang)
                MenuItemButton(
                  leadingIcon: check(t.lang == lyrics.secondaryTrack?.lang),
                  onPressed: () {
                    lyrics.secondary = t.lang;
                    _changed();
                  },
                  child: Text(lyricTrackLabel(t)),
                ),
          ],
          const Divider(height: 8),
          _OffsetRow(
            offset: main.offset,
            onChanged: (v) {
              main.offset = v;
              _changed(now: false);
            },
          ),
        ],
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.file_open_outlined, size: 20),
          onPressed: widget.onImport == null ? null : () => _close(widget.onImport),
          child: Text(tr('lyrics.import')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.content_paste, size: 20),
          onPressed: widget.onPaste == null ? null : () => _close(widget.onPaste),
          child: Text(tr('lyrics.paste')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_note, size: 20),
          onPressed: widget.onEdit == null ? null : () => _close(widget.onEdit),
          child: Text(tr('lyrics.edit')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.graphic_eq, size: 20),
          onPressed: widget.onWhisper == null ? null : () => _close(widget.onWhisper),
          child: Text(tr('lyrics.whisper')),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: tr('sing.lyrics'),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(main != null && settings.showLyrics ? Icons.subtitles : Icons.subtitles_off, color: Colors.white, shadows: LyricsOverlay._shadow),
      ),
    );
  }
}

/// Rewind / forward buttons for the main track's timing, like a player's:
/// ◀ moves the lyrics earlier, ▶ moves them later (double triangles by
/// 0.5 s, single ones by 0.1 s). Stays open while clicking, so the effect
/// can be watched as it plays.
class _OffsetRow extends StatelessWidget {
  const _OffsetRow({required this.offset, required this.onChanged});
  final double offset;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void step(double by) => onChanged(((offset + by) * 100).round() / 100);
    Widget btn(IconData icon, double by) => IconButton(
          tooltip: tr(by > 0 ? 'lyrics.offsetLaterBy' : 'lyrics.offsetEarlierBy', {'s': by.abs().toStringAsFixed(1)}),
          visualDensity: VisualDensity.compact,
          onPressed: () => step(by),
          icon: Icon(icon, size: 22),
        );
    final secs = offset.abs().toStringAsFixed(2);
    final value = offset > 0 ? tr('lyrics.offsetLater', {'s': secs}) : offset < 0 ? tr('lyrics.offsetEarlier', {'s': secs}) : tr('lyrics.offsetNone');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.schedule, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(tr('lyrics.offset'), style: theme.textTheme.bodyMedium),
          const SizedBox(width: 8),
          btn(Icons.fast_rewind, -0.5),
          btn(Icons.arrow_left, -0.1),
          SizedBox(
            width: 104,
            child: Text(value, textAlign: TextAlign.center, maxLines: 1, softWrap: false, style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          btn(Icons.arrow_right, 0.1),
          btn(Icons.fast_forward, 0.5),
          IconButton(
            tooltip: tr('lyrics.offsetReset'),
            visualDensity: VisualDensity.compact,
            onPressed: offset == 0 ? null : () => onChanged(0),
            icon: const Icon(Icons.restart_alt, size: 18),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: Text(tr('lyrics.offsetHint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}
