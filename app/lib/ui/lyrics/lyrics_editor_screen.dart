// Lyrics editor: one row per line with start / end / text, a player for the
// song (or its vocals) and "stamping": while it plays, Enter sets the start
// of the current line to the playback position and moves to the next one.
// Saving keeps YouTube / recognised tracks and writes an edited copy; the
// app's own tracks are edited in place. The result becomes the main lyrics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/lyrics.dart';
import 'lyrics_actions.dart';

class _Row {
  _Row(this.start, this.end, String text) : text = TextEditingController(text: text) {
    startC.text = start == null ? '' : formatLyricTime(start!);
    endC.text = end == null ? '' : formatLyricTime(end!);
  }
  double? start;
  double? end;
  final TextEditingController text;
  final startC = TextEditingController();
  final endC = TextEditingController();

  void setStart(double? v) {
    start = v;
    startC.text = v == null ? '' : formatLyricTime(v);
  }

  void setEnd(double? v) {
    end = v;
    endC.text = v == null ? '' : formatLyricTime(v);
  }

  (double?, double?, String) get snapshot => (start, end, text.text);

  void dispose() {
    text.dispose();
    startC.dispose();
    endC.dispose();
  }
}

class LyricsEditorScreen extends StatefulWidget {
  const LyricsEditorScreen({super.key, required this.song});
  final Song song;

  @override
  State<LyricsEditorScreen> createState() => _LyricsEditorScreenState();
}

class _LyricsEditorScreenState extends State<LyricsEditorScreen> {
  static const _rowHeight = 52.0;

  Lyrics? _lyrics;
  LyricTrack? _source; // the track being edited (null: new lyrics)
  final _rows = <_Row>[];
  final _undo = <List<(double?, double?, String)>>[];
  bool _dirty = false;
  int _cursor = 0; // the row Enter stamps next

  Player? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  double _pos = 0;
  double _dur = 0;
  bool _playing = false;
  bool _vocals = false;
  double _rate = 1;
  bool _hasAudio = false;

  final _pageFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = context.read<AppServices>();
    final lyrics = await services.pipeline.loadLyrics(widget.song);
    if (!mounted) return;
    setState(() {
      _lyrics = lyrics;
      _setSource(lyrics.primaryTrack);
    });
    final files = services.library.files(widget.song);
    _vocals = false;
    _hasAudio = await File(files.mixWav).exists();
    if (_hasAudio) await _openAudio();
    if (mounted) setState(() {});
  }

  void _setSource(LyricTrack? t) {
    _source = t;
    for (final r in _rows) {
      r.dispose();
    }
    _rows
      ..clear()
      // The track's timing offset is baked into the times being edited.
      ..addAll([for (final l in t?.shownLines ?? const <LyricLine>[]) _Row(l.start, l.end, l.text)]);
    _undo.clear();
    _dirty = false;
    _cursor = 0;
  }

  Future<void> _openAudio() async {
    final files = context.read<AppServices>().library.files(widget.song);
    final path = _vocals && File(files.vocalsWav).existsSync() ? files.vocalsWav : files.mixWav;
    final resume = _pos;
    var p = _player;
    if (p == null) {
      p = Player();
      _player = p;
      _posSub = p.stream.position.listen((d) {
        if (!mounted) return;
        setState(() => _pos = d.inMilliseconds / 1000);
      });
      _playSub = p.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      });
      p.stream.duration.listen((d) {
        if (mounted && d > Duration.zero) setState(() => _dur = d.inMilliseconds / 1000);
      });
    }
    await p.open(Media(path), play: false);
    await p.setRate(_rate);
    if (resume > 0) await p.seek(_dur0(resume));
  }

  Duration _dur0(double s) => Duration(milliseconds: (math.max(0, s) * 1000).round());

  @override
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    _player?.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    _pageFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---- editing ---------------------------------------------------------------

  /// Records the rows for undo; call before every change.
  void _remember() {
    _undo.add([for (final r in _rows) r.snapshot]);
    if (_undo.length > 100) _undo.removeAt(0);
    _dirty = true;
  }

  void _doUndo() {
    if (_undo.isEmpty) return;
    final snap = _undo.removeLast();
    setState(() {
      for (final r in _rows) {
        r.dispose();
      }
      _rows
        ..clear()
        ..addAll([for (final s in snap) _Row(s.$1, s.$2, s.$3)]);
      _cursor = math.min(_cursor, _rows.length);
    });
  }

  void _stamp() {
    if (_cursor >= _rows.length) return;
    final t = _pos;
    setState(() {
      _remember();
      final row = _rows[_cursor];
      row.setStart(t);
      if (row.end != null && row.end! <= t) row.setEnd(null);
      if (_cursor > 0) {
        final prev = _rows[_cursor - 1];
        if (prev.end == null || prev.end! > t) prev.setEnd(t);
      }
      _cursor++;
    });
    _reveal(_cursor);
  }

  /// Shift+Enter: the line stamped last ends now (a pause follows it).
  void _stampEnd() {
    final i = _cursor - 1;
    if (i < 0 || i >= _rows.length) return;
    final t = _pos;
    if (_rows[i].start != null && t <= _rows[i].start!) return;
    setState(() {
      _remember();
      _rows[i].setEnd(t);
    });
  }

  void _reveal(int i) {
    if (!_scroll.hasClients) return;
    final top = i * _rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset || top + _rowHeight > _scroll.offset + view) {
      _scroll.animateTo(math.max(0.0, top - view / 3).clamp(0.0, _scroll.position.maxScrollExtent), duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _addLine({int? at, String text = ''}) {
    setState(() {
      _remember();
      _rows.insert(at ?? _rows.length, _Row(null, null, text));
    });
  }

  void _delete(int i) {
    setState(() {
      _remember();
      _rows.removeAt(i).dispose();
      if (_cursor > i) _cursor--;
    });
  }

  void _split(int i) {
    final r = _rows[i];
    final sel = r.text.selection;
    final at = sel.isValid && sel.baseOffset > 0 && sel.baseOffset < r.text.text.length ? sel.baseOffset : r.text.text.length ~/ 2;
    if (at <= 0) return;
    setState(() {
      _remember();
      final tail = r.text.text.substring(at).trim();
      r.text.text = r.text.text.substring(0, at).trim();
      // The new line starts halfway through the old one when it was timed.
      double? mid;
      if (r.start != null && r.end != null) mid = (r.start! + r.end!) / 2;
      final next = _Row(mid, r.end, tail);
      if (mid != null) r.setEnd(mid);
      _rows.insert(i + 1, next);
    });
  }

  void _mergeNext(int i) {
    if (i + 1 >= _rows.length) return;
    setState(() {
      _remember();
      final a = _rows[i], b = _rows.removeAt(i + 1);
      a.text.text = '${a.text.text} ${b.text.text}'.trim();
      if (b.end != null) a.setEnd(b.end);
      b.dispose();
      if (_cursor > i + 1) _cursor--;
    });
  }

  Future<void> _paste() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('lyrics.editor.paste')),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('lyrics.editor.pasteHint'), style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(controller: c, autofocus: true, maxLines: 14, minLines: 8, decoration: const InputDecoration(border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('ok'))),
        ],
      ),
    );
    c.dispose();
    final lines = (text ?? '').split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return;
    setState(() {
      _remember();
      final first = _rows.length;
      _rows.addAll([for (final l in lines) _Row(null, null, l)]);
      // Stamping continues at the first line that has no time yet.
      final untimed = _rows.indexWhere((r) => r.start == null);
      _cursor = untimed < 0 ? first : untimed;
    });
  }

  Future<void> _shift() async {
    final c = TextEditingController();
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('lyrics.editor.shift')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
          decoration: InputDecoration(helperText: tr('lyrics.editor.shiftHint'), suffixText: 's'),
          onSubmitted: (s) => Navigator.pop(ctx, double.tryParse(s.trim())),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim())), child: Text(tr('ok'))),
        ],
      ),
    );
    c.dispose();
    if (v == null || v == 0) return;
    setState(() {
      _remember();
      for (final r in _rows) {
        if (r.start != null) r.setStart(math.max(0.0, r.start! + v));
        if (r.end != null) r.setEnd(math.max(0.0, r.end! + v));
      }
    });
  }

  /// A typed time: applied when valid, else the field shows the old value.
  void _commitTime(_Row r, {required bool start}) {
    final c = start ? r.startC : r.endC;
    final old = start ? r.start : r.end;
    final v = c.text.trim().isEmpty ? null : parseLyricTime(c.text);
    if (c.text.trim().isNotEmpty && v == null || v == old) {
      c.text = old == null ? '' : formatLyricTime(old);
      return;
    }
    setState(() {
      _remember();
      start ? r.setStart(v) : r.setEnd(v);
    });
  }

  // ---- saving and export -------------------------------------------------------

  /// The rows as lyric lines, or the index of the first bad row with the
  /// message key. Empty rows are dropped; a missing end is the next start.
  ({List<LyricLine>? lines, int bad, String error}) _build() {
    final rows = _rows.where((r) => r.text.text.trim().isNotEmpty).toList();
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].start == null) return (lines: null, bad: _rows.indexOf(rows[i]), error: 'lyrics.editor.noStart');
      if (rows[i].end != null && rows[i].end! <= rows[i].start!) return (lines: null, bad: _rows.indexOf(rows[i]), error: 'lyrics.editor.badEnd');
    }
    rows.sort((a, b) => a.start!.compareTo(b.start!));
    final out = <LyricLine>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final next = i + 1 < rows.length ? rows[i + 1].start! : r.start! + 6;
      final end = r.end ?? math.min(next, r.start! + 10);
      out.add(LyricLine(r.start!, end, r.text.text.trim().replaceAll(RegExp(r'\s+'), ' ')));
    }
    return (lines: out, bad: -1, error: '');
  }

  bool _check(({List<LyricLine>? lines, int bad, String error}) b) {
    if (b.lines != null) return true;
    setState(() => _cursor = b.bad);
    _reveal(b.bad);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(b.error, {'n': '${b.bad + 1}'}))));
    return false;
  }

  Future<void> _save() async {
    final b = _build();
    if (!_check(b)) return;
    final services = context.read<AppServices>();
    final lyrics = _lyrics ?? Lyrics.empty();
    final src = _source;
    final LyricTrack track;
    if (src == null) {
      track = LyricTrack(lang: lyrics.uniqueKey('${widget.song.language}-x-manual'), auto: false, lines: b.lines!, source: LyricSource.manual);
    } else {
      final key = Lyrics.editKeyFor(src);
      final inPlace = key == src.lang;
      track = LyricTrack(
        lang: key,
        auto: false,
        lines: b.lines!,
        source: inPlace ? src.source : LyricSource.edited,
        label: inPlace ? src.label : null,
      );
    }
    lyrics.putPrimary(track);
    await services.pipeline.saveLyrics(widget.song, lyrics);
    if (!mounted) return;
    _dirty = false;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lyrics.editor.saved'))));
    Navigator.of(context).pop(true);
  }

  Future<void> _export(String ext) async {
    final b = _build();
    if (!_check(b)) return;
    final text = ext == 'srt' ? toSrt(b.lines!) : toLrc(b.lines!);
    final name = widget.song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final uri = await FilePicker.saveFile(fileName: '$name.$ext', bytes: utf8.encode(text));
    if (uri == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('lyrics.editor.exported', {'path': uri.toFilePath()}))));
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('lyrics.editor.discardTitle')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('lyrics.editor.discard'))),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---- playback ------------------------------------------------------------------

  void _togglePlay() => _player?.playOrPause();

  void _seek(double s) => _player?.seek(_dur0(_dur > 0 ? math.min(s, _dur) : s));

  int get _playingRow {
    for (var i = _rows.length - 1; i >= 0; i--) {
      final r = _rows[i];
      if (r.start != null && r.start! <= _pos) return (r.end ?? double.infinity) > _pos ? i : -1;
    }
    return -1;
  }

  // ---- keys ------------------------------------------------------------------------

  bool get _typing => FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_typing) {
      if (k == LogicalKeyboardKey.escape) {
        _pageFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (k == LogicalKeyboardKey.space && e is KeyDownEvent) {
      _togglePlay();
    } else if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && e is KeyDownEvent) {
      shift ? _stampEnd() : _stamp();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      _seek(math.max(0, _pos - 2));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _seek(_pos + 2);
    } else if (k == LogicalKeyboardKey.keyZ && (HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed)) {
      _doUndo();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---- UI ----------------------------------------------------------------------------

  static const _maxWidth = 1180.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final lyrics = _lyrics;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _dirty = false;
          Navigator.of(context).pop(false);
        }
      },
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(tr('lyrics.editor.title'), style: theme.textTheme.titleLarge),
              Text(widget.song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
            actions: [
              if (lyrics != null && lyrics.tracks.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.subtitles_outlined, size: 18, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    DropdownButton<String>(
                      value: _source?.lang ?? '',
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: [
                        for (final t in lyrics.tracks) DropdownMenuItem(value: t.lang, child: Text(lyricTrackLabel(t))),
                        DropdownMenuItem(value: '', child: Text(tr('lyrics.editor.new'))),
                      ],
                      onChanged: (v) async {
                        if (v == (_source?.lang ?? '')) return;
                        if (_dirty && !await _confirmDiscard()) return;
                        setState(() => _setSource(v == null || v.isEmpty ? null : lyrics.track(v)));
                      },
                    ),
                  ]),
                ),
                const SizedBox(width: 8),
              ],
              PopupMenuButton<String>(
                tooltip: tr('lyrics.editor.export'),
                enabled: _rows.isNotEmpty,
                icon: const Icon(Icons.ios_share),
                onSelected: _export,
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'srt', child: Text(tr('lyrics.editor.exportSrt'))),
                  PopupMenuItem(value: 'lrc', child: Text(tr('lyrics.editor.exportLrc'))),
                ],
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: Text(tr('lyrics.editor.save'))),
              ),
            ],
          ),
          body: lyrics == null
              ? const Center(child: CircularProgressIndicator())
              : GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _pageFocus.requestFocus(),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _playerCard(theme),
                          const SizedBox(height: 12),
                          _toolBar(theme),
                          const SizedBox(height: 8),
                          _keysHint(theme),
                          const SizedBox(height: 12),
                          Expanded(child: _listCard(theme)),
                        ]),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _playerCard(ThemeData theme) {
    final cs = theme.colorScheme;
    if (!_hasAudio) {
      return Card.filled(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(Icons.info_outline, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('lyrics.editor.noAudio'))),
          ]),
        ),
      );
    }
    final files = context.read<AppServices>().library.files(widget.song);
    final hasVocals = File(files.vocalsWav).existsSync();
    final mono = theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], fontWeight: FontWeight.w600);
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        child: Row(children: [
          IconButton(tooltip: '−5 s', onPressed: () => _seek(math.max(0, _pos - 5)), icon: const Icon(Icons.replay_5)),
          const SizedBox(width: 4),
          SizedBox(
            width: 52,
            height: 52,
            child: IconButton.filled(onPressed: _togglePlay, iconSize: 30, icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded)),
          ),
          const SizedBox(width: 4),
          IconButton(tooltip: '+5 s', onPressed: () => _seek(_pos + 5), icon: const Icon(Icons.forward_5)),
          const SizedBox(width: 12),
          Text(formatLyricTime(_pos), style: mono),
          Text('  /  ${formatLyricTime(_dur)}', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
              child: Slider(
                value: _dur > 0 ? _pos.clamp(0, _dur) : 0,
                max: _dur > 0 ? _dur : 1,
                onChanged: _dur > 0 ? (v) => _seek(v) : null,
              ),
            ),
          ),
          if (hasVocals) ...[
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(value: false, icon: const Icon(Icons.queue_music, size: 18), label: Text(tr('lyrics.editor.mix'))),
                ButtonSegment(value: true, icon: const Icon(Icons.mic_none, size: 18), label: Text(tr('lyrics.editor.vocals'))),
              ],
              selected: {_vocals},
              onSelectionChanged: (v) async {
                final wasPlaying = _playing;
                setState(() => _vocals = v.first);
                await _openAudio();
                if (wasPlaying) await _player?.play();
              },
            ),
            const SizedBox(width: 8),
          ],
          PopupMenuButton<double>(
            tooltip: tr('lyrics.editor.speed'),
            initialValue: _rate,
            onSelected: (r) {
              setState(() => _rate = r);
              _player?.setRate(r);
            },
            itemBuilder: (_) => [for (final r in const [0.5, 0.75, 1.0]) PopupMenuItem(value: r, child: Text('$r×'))],
            child: Chip(
              avatar: const Icon(Icons.speed, size: 18),
              label: Text('$_rate×'),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _toolBar(ThemeData theme) {
    final cs = theme.colorScheme;
    Widget tool(IconData icon, String tip, VoidCallback? onPressed) => IconButton(tooltip: tip, onPressed: onPressed, icon: Icon(icon));
    return Row(children: [
      FilledButton.icon(
        onPressed: _hasAudio && _cursor < _rows.length ? _stamp : null,
        icon: const Icon(Icons.touch_app),
        label: Row(mainAxisSize: MainAxisSize.min, children: [Text(tr('lyrics.editor.stamp')), const SizedBox(width: 8), const _Kbd('Enter', onPrimary: true)]),
      ),
      const SizedBox(width: 8),
      FilledButton.tonalIcon(
        onPressed: _hasAudio && _cursor > 0 ? _stampEnd : null,
        icon: const Icon(Icons.last_page),
        label: Row(mainAxisSize: MainAxisSize.min, children: [Text(tr('lyrics.editor.stampEnd')), const SizedBox(width: 8), const _Kbd('Shift+Enter')]),
      ),
      const Spacer(),
      DecoratedBox(
        decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant), borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            tool(Icons.undo, tr('lyrics.editor.undo'), _undo.isEmpty ? null : _doUndo),
            tool(Icons.playlist_add, tr('lyrics.editor.addLine'), () => _addLine()),
            tool(Icons.content_paste, tr('lyrics.editor.paste'), _paste),
            tool(Icons.swap_horiz, tr('lyrics.editor.shift'), _rows.isEmpty ? null : _shift),
          ]),
        ),
      ),
    ]);
  }

  Widget _keysHint(ThemeData theme) {
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget item(List<String> keys, String what) => Row(mainAxisSize: MainAxisSize.min, children: [
          for (final k in keys) ...[_Kbd(k), const SizedBox(width: 4)],
          Text(what, style: muted),
        ]);
    return Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      item(['Space'], tr('lyrics.editor.kPlay')),
      item(['Enter'], tr('lyrics.editor.kStamp')),
      item(['Shift+Enter'], tr('lyrics.editor.kEnd')),
      item(['←', '→'], tr('lyrics.editor.kSeek')),
      item(['Esc'], tr('lyrics.editor.kEsc')),
    ]);
  }

  Widget _listCard(ThemeData theme) {
    final cs = theme.colorScheme;
    if (_rows.isEmpty) {
      return Card.outlined(
        margin: EdgeInsets.zero,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lyrics_outlined, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(tr('lyrics.editor.empty'), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: Text(tr('lyrics.editor.paste'))),
                OutlinedButton.icon(onPressed: () => _addLine(), icon: const Icon(Icons.playlist_add), label: Text(tr('lyrics.editor.addLine'))),
              ]),
            ]),
          ),
        ),
      );
    }
    final head = theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant);
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: cs.surfaceContainerHigh,
          padding: const EdgeInsets.fromLTRB(16, 10, 56, 10),
          child: Row(children: [
            SizedBox(width: 36 + 40, child: Text('#', style: head)),
            SizedBox(width: 100, child: Text(tr('lyrics.editor.start'), style: head)),
            const SizedBox(width: 8),
            SizedBox(width: 100, child: Text(tr('lyrics.editor.end'), style: head)),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('lyrics.editor.text'), style: head)),
          ]),
        ),
        Expanded(child: _list(theme)),
      ]),
    );
  }

  Widget _list(ThemeData theme) {
    final cs = theme.colorScheme;
    final playing = _playingRow;
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    InputDecoration deco(String hint) => InputDecoration(
          isDense: true,
          hintText: hint,
          filled: true,
          fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: cs.primary, width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        );
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowHeight,
      itemCount: _rows.length,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemBuilder: (context, i) {
        final r = _rows[i];
        final isCursor = i == _cursor;
        final isPlaying = i == playing;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: isPlaying ? cs.primaryContainer.withValues(alpha: 0.45) : (isCursor ? cs.tertiaryContainer.withValues(alpha: 0.25) : null),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(children: [
            Tooltip(
              message: tr('lyrics.editor.nextStamp'),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _cursor = i),
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: isCursor ? cs.tertiary : cs.surfaceContainerHighest),
                  child: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(color: isCursor ? cs.onTertiary : cs.onSurfaceVariant, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: tr('lyrics.editor.playFrom'),
              visualDensity: VisualDensity.compact,
              onPressed: r.start == null || !_hasAudio
                  ? null
                  : () {
                      _seek(math.max(0, r.start! - 0.5));
                      _player?.play();
                      setState(() => _cursor = i);
                    },
              icon: Icon(Icons.play_circle_outline, size: 22, color: isPlaying ? cs.primary : null),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 100,
              child: Focus(
                onFocusChange: (f) => f ? null : _commitTime(r, start: true),
                child: TextField(controller: r.startC, style: mono, decoration: deco('--:--.--'), onSubmitted: (_) => _commitTime(r, start: true)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 100,
              child: Focus(
                onFocusChange: (f) => f ? null : _commitTime(r, start: false),
                child: TextField(controller: r.endC, style: mono, decoration: deco('--:--.--'), onSubmitted: (_) => _commitTime(r, start: false)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: r.text,
                style: theme.textTheme.bodyLarge,
                decoration: deco(tr('lyrics.editor.text')),
                onChanged: (_) {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (v) => switch (v) {
                'start' => setState(() {
                    _remember();
                    r.setStart(_pos);
                  }),
                'end' => setState(() {
                    _remember();
                    r.setEnd(_pos);
                  }),
                'insert' => _addLine(at: i + 1),
                'split' => _split(i),
                'merge' => _mergeNext(i),
                'delete' => _delete(i),
                _ => null,
              },
              itemBuilder: (_) => [
                if (_hasAudio) _menuItem('start', Icons.first_page, tr('lyrics.editor.setStart')),
                if (_hasAudio) _menuItem('end', Icons.last_page, tr('lyrics.editor.setEnd')),
                if (_hasAudio) const PopupMenuDivider(),
                _menuItem('insert', Icons.playlist_add, tr('lyrics.editor.insertBelow')),
                _menuItem('split', Icons.call_split, tr('lyrics.editor.split')),
                if (i + 1 < _rows.length) _menuItem('merge', Icons.merge, tr('lyrics.editor.mergeNext')),
                const PopupMenuDivider(),
                _menuItem('delete', Icons.delete_outline, tr('delete')),
              ],
            ),
          ]),
        );
      },
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) =>
      PopupMenuItem(value: value, child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]));
}

/// A key cap, for the keyboard hints.
class _Kbd extends StatelessWidget {
  const _Kbd(this.label, {this.onPrimary = false});
  final String label;
  final bool onPrimary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fg = onPrimary ? cs.onPrimary : cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: fg.withValues(alpha: 0.5)),
        color: onPrimary ? Colors.white.withValues(alpha: 0.12) : cs.surfaceContainerHighest,
      ),
      child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }
}
