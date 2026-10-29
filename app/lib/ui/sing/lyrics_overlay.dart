// Synced lyrics over the video / visualiser: the current line fills from left
// to right as it is sung, its translation below, and the next line dimmed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/settings.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';

class LyricsOverlay extends StatelessWidget {
  const LyricsOverlay({super.key, required this.lyrics, required this.position, this.noteOnsets, this.noteOffsets});
  final Lyrics lyrics;
  final ValueListenable<double> position;

  /// Transcribed notes (sorted by onset) that drive the wipe note by note;
  /// without them the wipe is linear over each line.
  final List<double>? noteOnsets;
  final List<double>? noteOffsets;

  static const _shadow = [Shadow(color: Colors.black, blurRadius: 6), Shadow(color: Colors.black, blurRadius: 2)];

  @override
  Widget build(BuildContext context) {
    final main = lyrics.primaryTrack;
    if (main == null) return const SizedBox.shrink();
    final trans = lyrics.secondaryTrack;
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
          return Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(16, big * 1.2, 16, big * 0.5),
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Color(0xB0000000)]),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (cur != null)
                  _WipeText(text: cur.text, fraction: frac, fontSize: big)
                else if (upcoming != null)
                  Text(upcoming.text, textAlign: TextAlign.center, style: TextStyle(fontSize: big, color: Colors.white54, fontWeight: FontWeight.w700, shadows: _shadow))
                else
                  SizedBox(height: big * 1.3),
                if (tr2 != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(tr2.text, textAlign: TextAlign.center, style: TextStyle(fontSize: small, color: Colors.white.withValues(alpha: 0.85), shadows: _shadow)),
                  ),
                if (cur != null && next != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(next.text, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: small, color: Colors.white38, shadows: _shadow)),
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
  const _WipeText({required this.text, required this.fraction, required this.fontSize});
  final String text;
  final double fraction;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, height: 1.25, shadows: LyricsOverlay._shadow);
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

/// Corner menu: show / hide lyrics, pick the lyrics track and a translation.
/// The global show flag is a setting; the track choice is saved per song.
class LyricsMenu extends StatelessWidget {
  const LyricsMenu({super.key, required this.lyrics, required this.lyricsPath, required this.onChanged});
  final Lyrics lyrics;
  final String lyricsPath;
  final VoidCallback onChanged;

  String _label(LyricTrack t) => t.auto ? '${t.lang} (${tr('sing.lyricsAuto')})' : t.lang;

  Future<void> _save() async {
    try {
      await File(lyricsPath).writeAsString(jsonEncode(lyrics.toJson()));
    } catch (_) {}
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final main = lyrics.primaryTrack?.lang;
    return PopupMenuButton<String>(
      tooltip: tr('sing.lyrics'),
      icon: Icon(settings.showLyrics ? Icons.subtitles : Icons.subtitles_off, color: Colors.white, shadows: LyricsOverlay._shadow),
      onSelected: (v) {
        if (v == 'toggle') {
          settings.setShowLyrics(!settings.showLyrics);
        } else if (v.startsWith('main:')) {
          lyrics.primary = v.substring(5);
          if (lyrics.secondary == lyrics.primary) lyrics.secondary = null;
          _save();
        } else if (v.startsWith('sec:')) {
          final k = v.substring(4);
          lyrics.secondary = k.isEmpty ? null : k;
          _save();
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'toggle', checked: settings.showLyrics, child: Text(tr('sing.lyricsShow'))),
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, height: 28, child: Text(tr('sing.lyricsMain'))),
        for (final t in lyrics.tracks) CheckedPopupMenuItem(value: 'main:${t.lang}', checked: t.lang == main, child: Text(_label(t))),
        const PopupMenuDivider(),
        PopupMenuItem(enabled: false, height: 28, child: Text(tr('sing.lyricsTranslation'))),
        CheckedPopupMenuItem(value: 'sec:', checked: lyrics.secondaryTrack == null, child: Text(tr('sing.lyricsNone'))),
        for (final t in lyrics.tracks)
          if (t.lang != main) CheckedPopupMenuItem(value: 'sec:${t.lang}', checked: t.lang == lyrics.secondaryTrack?.lang, child: Text(_label(t))),
      ],
    );
  }
}
