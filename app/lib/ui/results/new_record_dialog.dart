// "New record" celebration with a shareable score card. X and Threads get a
// prefilled post (text + download link) and the card on the clipboard to
// paste; Instagram has no desktop post intent, so the caption is copied and
// the card saved for upload.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../services/song_library.dart';
import '../../services/update_checker.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/scoring_bridge.dart';
import '../widgets/rank.dart';

/// Download page linked from every share ("come and play").
const kShareDownloadUrl = '${UpdateChecker.repoUrl}/releases/latest';

/// The default post text for a score ([newRecord] adds "new personal best").
String shareText(Song song, ScoreData score, {bool newRecord = true}) => tr(newRecord ? 'share.text' : 'share.textPlain', {
      'title': song.title,
      'score': score.total.toStringAsFixed(1),
      'rank': score.rank,
      'url': kShareDownloadUrl,
    });

Future<void> showNewRecordDialog(BuildContext context, {required Song song, required TakeInfo take, required ScoreData score, double? previousBest, String? thumbPath}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NewRecordDialog(song: song, take: take, score: score, previousBest: previousBest, thumbPath: thumbPath, celebrate: true, isBest: true),
  );
}

/// The same share sheet without the celebration, for any results page.
/// [isBest] marks the card as the song's personal best.
Future<void> showShareDialog(BuildContext context, {required Song song, required TakeInfo take, required ScoreData score, bool isBest = false, String? thumbPath}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NewRecordDialog(song: song, take: take, score: score, thumbPath: thumbPath, celebrate: false, isBest: isBest),
  );
}

class _NewRecordDialog extends StatefulWidget {
  const _NewRecordDialog({required this.song, required this.take, required this.score, this.previousBest, this.thumbPath, required this.celebrate, required this.isBest});
  final Song song;
  final TakeInfo take;
  final ScoreData score;
  final double? previousBest;
  final String? thumbPath;
  final bool celebrate;
  final bool isBest;

  @override
  State<_NewRecordDialog> createState() => _NewRecordDialogState();
}

class _NewRecordDialogState extends State<_NewRecordDialog> {
  final _cardKey = GlobalKey();
  String? _imagePath;
  bool _busy = false;

  String get _text => shareText(widget.song, widget.score, newRecord: widget.celebrate);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Decode the thumbnail up front so the captured card always includes it.
    final t = widget.thumbPath;
    if (t != null && File(t).existsSync()) precacheImage(FileImage(File(t)), context);
  }

  /// Renders the card at 1080x1080 and saves it next to the take.
  Future<(String, Uint8List)> _render() async {
    final boundary = _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1080 / ShareCard.size);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final bytes = data!.buffer.asUint8List();
    final path = p.join(widget.take.dir, 'share.png');
    await File(path).writeAsBytes(bytes, flush: true);
    _imagePath = path;
    return (path, bytes);
  }

  void _snack(String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } catch (e) {
      _snack('${tr('error')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareIntent(String url) => _run(() async {
        final (_, bytes) = await _render();
        await Pasteboard.writeImage(bytes);
        await launchUrl(Uri.parse(url));
        _snack(tr('share.pasteHint', {'key': Platform.isMacOS ? '⌘V' : 'Ctrl+V'}));
      });

  Future<void> _shareX() => _shareIntent('https://twitter.com/intent/tweet?text=${Uri.encodeComponent(_text)}');

  Future<void> _shareThreads() => _shareIntent('https://www.threads.net/intent/post?text=${Uri.encodeComponent(_text)}');

  Future<void> _shareInstagram() => _run(() async {
        final (path, _) = await _render();
        await Clipboard.setData(ClipboardData(text: _text));
        await revealPath(path);
        await launchUrl(Uri.parse('https://www.instagram.com/'));
        _snack(tr('share.igHint'));
      });

  Future<void> _copyImage() => _run(() async {
        final (_, bytes) = await _render();
        await Pasteboard.writeImage(bytes);
        _snack(tr('share.imageCopied'));
      });

  Future<void> _saveImage() => _run(() async {
        final (path, _) = await _render();
        await revealPath(path);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prev = widget.previousBest;
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.celebrate) ...[
              const Icon(Icons.emoji_events, size: 48, color: trophyColor),
              const SizedBox(height: 4),
              Text(tr('share.congrats'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: trophyColor)),
              const SizedBox(height: 4),
              Text(
                prev == null ? tr('share.firstRecord') : tr('share.beat', {'prev': prev.toStringAsFixed(1), 'diff': (widget.score.total - prev).toStringAsFixed(1)}),
                textAlign: TextAlign.center,
              ),
            ] else
              Text(tr('share.title'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SizedBox(
              width: 340,
              height: 340,
              child: FittedBox(
                child: RepaintBoundary(
                  key: _cardKey,
                  child: ShareCard(
                    song: widget.song,
                    score: widget.score,
                    thumbPath: widget.thumbPath,
                    date: widget.take.createdAt,
                    badge: widget.celebrate ? tr('share.newRecord') : (widget.isBest ? tr('share.personalBest') : null),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (widget.celebrate) ...[
              Text(tr('share.title'), style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
            ],
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                _BrandButton(icon: FontAwesomeIcons.xTwitter, label: 'X', color: Colors.black, onPressed: _busy ? null : _shareX),
                _BrandButton(icon: FontAwesomeIcons.instagram, label: 'Instagram', color: const Color(0xFFD62976), onPressed: _busy ? null : _shareInstagram),
                _BrandButton(icon: FontAwesomeIcons.threads, label: 'Threads', color: const Color(0xFF101010), onPressed: _busy ? null : _shareThreads),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                TextButton.icon(onPressed: _busy ? null : _copyImage, icon: const Icon(Icons.copy, size: 16), label: Text(tr('share.copyImage'))),
                TextButton.icon(onPressed: _busy ? null : _saveImage, icon: const Icon(Icons.folder_open, size: 16), label: Text(tr('share.saveImage'))),
              ],
            ),
            Text(tr('share.note'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
            if (_imagePath != null) const SizedBox(height: 2),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('close')))],
    );
  }
}

class _BrandButton extends StatelessWidget {
  const _BrandButton({required this.icon, required this.label, required this.color, required this.onPressed});
  final FaIconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
      onPressed: onPressed,
      icon: FaIcon(icon, size: 18, color: Colors.white),
      label: Text(label),
    );
  }
}

/// The 1:1 score card (laid out at [size] logical px, rendered at 1080 px).
class ShareCard extends StatelessWidget {
  const ShareCard({super.key, required this.song, required this.score, required this.thumbPath, required this.date, this.badge, this.badgeIcon = Icons.emoji_events});
  final Song song;
  final ScoreData score;
  final String? thumbPath;
  final DateTime date;

  /// Gold pill in the top right ("NEW RECORD" / "Personal best"); none when null.
  final String? badge;
  final IconData badgeIcon;

  static const double size = 540;
  static const _order = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];
  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  @override
  Widget build(BuildContext context) {
    final rc = rankColor(score.rank);
    final thumb = thumbPath != null && File(thumbPath!).existsSync() ? File(thumbPath!) : null;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: const Color(0xFF0E0B1F),
        child: Stack(
          children: [
            if (thumb != null)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.28,
                  child: ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: Image.file(thumb, fit: BoxFit.cover)),
                ),
              ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [const Color(0xCC1A1240), rc.withValues(alpha: 0.35), const Color(0xEE07060F)],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.mic_external_on, color: Colors.white, size: 26),
                    const SizedBox(width: 8),
                    const Text('Karaoke Battle', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    const Spacer(),
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: trophyColor, borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(badgeIcon, size: 16, color: Colors.black),
                          const SizedBox(width: 4),
                          Text(badge!, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 13)),
                        ]),
                      ),
                  ]),
                  const SizedBox(height: 22),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (thumb != null)
                      ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(thumb, width: 128, height: 72, fit: BoxFit.cover)),
                    if (thumb != null) const SizedBox(width: 14),
                    Expanded(
                      child: Text(song.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, height: 1.25)),
                    ),
                  ]),
                  const Spacer(),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomLeft,
                        child: Text(score.total.toStringAsFixed(1), style: TextStyle(color: rc, fontSize: 104, fontWeight: FontWeight.w900, height: 0.95, shadows: [Shadow(color: rc.withValues(alpha: 0.6), blurRadius: 24)])),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Padding(padding: const EdgeInsets.only(bottom: 14), child: RankChip(rank: score.rank, fontSize: 30)),
                  ]),
                  const SizedBox(height: 18),
                  for (final k in _order)
                    if (score.subScores[k] != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(children: [
                          SizedBox(width: 92, child: Text(tr('results.${_camel(k)}'), style: const TextStyle(color: Colors.white70, fontSize: 13))),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: (score.subScores[k]! / 100).clamp(0.0, 1.0),
                                minHeight: 7,
                                color: rc,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                          ),
                          SizedBox(width: 40, child: Text('${score.subScores[k]!.round()}', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700))),
                        ]),
                      ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Text(
                      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const Spacer(),
                    Text(tr('share.cardFooter'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ]),
                ],
              ),
            ),
            // A few sparkles for flavour.
            for (var i = 0; i < 7; i++)
              Positioned(
                left: 40.0 + (i * 71) % 460,
                top: 90.0 + (i * 53) % 200,
                child: Icon(Icons.auto_awesome, size: 10.0 + (i % 3) * 5, color: Colors.white.withValues(alpha: 0.12 + 0.04 * math.min(i, 3))),
              ),
          ],
        ),
      ),
    );
  }
}
