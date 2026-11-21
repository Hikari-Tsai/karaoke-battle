// Library: song list with prep progress, actions and takes.
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/midi_export.dart';
import '../../services/dev_mode.dart';
import '../../services/prep_pipeline.dart';
import '../../services/settings.dart';
import '../../services/song_cover.dart';
import '../../services/song_library.dart';
import '../../services/take_import.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/note_edits.dart';
import '../../state/scoring_bridge.dart';
import '../../state/sing_session.dart';
import '../lyrics/export_lyrics_dialog.dart';
import '../lyrics/lyrics_actions.dart';
import '../results/new_record_dialog.dart';
import '../results/replay_screen.dart';
import '../replays/export_replay_dialog.dart';
import '../results/export_video_dialog.dart';
import '../results/results_screen.dart';
import '../sing/sing_screen.dart';
import '../widgets/rank.dart';
import '../widgets/brand.dart';
import '../widgets/error_report.dart';
import 'add_song_dialog.dart';
import 'backing_import_dialog.dart';
import 'library_stats.dart';
import '../widgets/app_dialog.dart';
import '../widgets/reveal.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _dragging = false;
  /// A reading width, centred, with room on both sides (as the History).
  static Widget _centred(Widget child, {Key? key}) => Center(
        key: key,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 28), child: child),
        ),
      );

  Future<void> _onDrop(DropDoneDetails d) async {
    final services = context.read<AppServices>();
    for (final item in d.files) {
      if (item.path.isEmpty) continue;
      await services.pipeline.importFile(item.path, language: services.settings.defaultLanguage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragDone: (d) {
        setState(() => _dragging = false);
        _onDrop(d);
      },
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: BrandedTitle(tr('library.title')),
              actions: [
                // Songs hidden from the list; restored from here.
                Consumer2<SongLibrary, AppSettings>(builder: (context, library, settings, _) {
                  final hidden = settings.hiddenSongs;
                  final n = library.songs.where((s) => hidden.contains(s.id)).length;
                  if (n == 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => showDialog<void>(context: context, builder: (_) => const _HiddenSongsDialog()),
                      icon: const Icon(Icons.visibility_off_outlined),
                      label: Text(tr('library.hiddenSongs', {'n': n})),
                    ),
                  );
                }),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: FilledButton.icon(onPressed: () => AddSongDialog.show(context), icon: const Icon(Icons.add), label: Text(tr('library.add'))),
                ),
              ],
            ),
            body: Consumer3<SongLibrary, PrepPipeline, AppSettings>(
              builder: (context, library, pipeline, settings, _) {
                final hidden = settings.hiddenSongs;
                final songs = library.songs.where((s) => !hidden.contains(s.id)).toList();
                if (songs.isEmpty && library.songs.isNotEmpty) {
                  return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.visibility_off_outlined, size: 64, color: cs.onSurface.withValues(alpha: 0.3)),
                      const SizedBox(height: 12),
                      Text(tr('library.allHidden'), style: Theme.of(context).textTheme.bodyLarge),
                    ]),
                  );
                }
                if (songs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.queue_music, size: 64, color: cs.onSurface.withValues(alpha: 0.3)),
                        const SizedBox(height: 12),
                        Text(tr('library.empty'), style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  itemCount: songs.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) return _centred(const Padding(padding: EdgeInsets.only(bottom: 12), child: LibraryStats()));
                    final song = songs[i - 1];
                    // The first screenful comes in one after another.
                    return _centred(
                      key: ValueKey(song.id),
                      FadeSlideIn(
                        delay: Duration(milliseconds: i <= 10 ? 40 * i : 0),
                        offset: 12,
                        duration: const Duration(milliseconds: 600),
                        child: _SongCard(key: ValueKey('card-${song.id}'), song: song, status: pipeline.statusOf(song.id)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: cs.primary.withValues(alpha: 0.15),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: cs.primary, width: 2)),
                    child: Text(tr('library.dropHere'), style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SongCard extends StatefulWidget {
  const _SongCard({super.key, required this.song, required this.status});
  final Song song;
  final PrepStatus? status;

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard> {
  List<TakeInfo>? _takes;
  bool _expanded = false;
  bool _hover = false;
  late final SongLibrary _library = context.read<SongLibrary>();

  @override
  void initState() {
    super.initState();
    _loadTakes(); // the best score is shown on the card even when collapsed
    _library.takesChanged.addListener(_onTakesChanged);
    if (widget.song.stage == PrepStage.done) {
      // Songs prepared before thumbnails / subtitles existed get them lazily.
      final pipeline = context.read<AppServices>().pipeline;
      pipeline.ensureThumbnail(widget.song).then((_) => pipeline.ensureLyrics(widget.song)).then((_) => pipeline.ensureRomaji(widget.song));
      pipeline.ensureBeats(widget.song);
    }
  }

  @override
  void dispose() {
    _library.takesChanged.removeListener(_onTakesChanged);
    super.dispose();
  }

  /// A take of this song was scored somewhere (sing, sing again, re-score).
  void _onTakesChanged() {
    if (mounted && _library.takesChanged.value?.songId == widget.song.id) _loadTakes();
  }

  Future<void> _loadTakes() async {
    final library = context.read<SongLibrary>();
    final t = await library.takes(widget.song);
    if (mounted) setState(() => _takes = t);
    _rescoreOutdated(t);
  }

  /// Songs whose old takes are being re-scored (once per run).
  static final Set<String> _rescoring = {};

  /// Takes scored with older, stricter rules are scored again from their
  /// saved pitch files, so old and new scores compare fairly.
  Future<void> _rescoreOutdated(List<TakeInfo> takes) async {
    final stale = takes.where((t) => t.outdated && File(t.f0Json).existsSync() && File(t.wav).existsSync()).toList();
    if (stale.isEmpty || !_rescoring.add(widget.song.id)) return;
    final services = context.read<AppServices>();
    final files = services.library.files(widget.song);
    try {
      for (final t in stale) {
        try {
          await SingSession.scoreTake(services: services, files: files, take: t, octaveInvariant: services.settings.octaveInvariant, reuseF0: true);
        } catch (_) {}
      }
    } finally {
      _rescoring.remove(widget.song.id);
    }
    if (mounted) await _loadTakes();
  }

  /// The scored take with the highest total, if any.
  TakeInfo? get _best {
    TakeInfo? best;
    for (final t in _takes ?? const <TakeInfo>[]) {
      if (t.total == null) continue;
      if (best == null || t.total! > best.total!) best = t;
    }
    return best;
  }

  Future<void> _sing() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SingScreen(song: widget.song)));
    if (mounted) _loadTakes();
  }

  Future<void> _openResult(TakeInfo t) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ResultsScreen(song: widget.song, take: t)));
    if (mounted) _loadTakes();
  }

  Future<void> _share(TakeInfo t) async {
    final services = context.read<AppServices>();
    final score = await ScoringBridge.load(t.scoreJson);
    if (score == null || !mounted) return;
    await showShareDialog(context, song: widget.song, take: t, score: score, isBest: identical(t, _best), thumbPath: services.library.files(widget.song).shownThumb);
  }

  /// Scores a take whose scoring did not finish (e.g. a model was missing).
  Future<void> _scoreTake(TakeInfo t) async {
    final services = context.read<AppServices>();
    final progress = ValueNotifier(const TakeProcessing('sing.extractingF0', 0));
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      // Scoring cannot be stopped part way.
      builder: (_) => AppDialog(
        canClose: false,
        content: ValueListenableBuilder<TakeProcessing>(
          valueListenable: progress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(p.stage)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: p.fraction > 0 ? p.fraction : null),
          ]),
        ),
      ),
    );
    Object? error;
    StackTrace? stack;
    try {
      await SingSession.scoreTake(
        services: services,
        files: services.library.files(widget.song),
        take: t,
        octaveInvariant: services.settings.octaveInvariant,
        onProgress: (p) => progress.value = p,
      );
    } catch (e, st) {
      error = e;
      stack = st;
    } finally {
      nav.pop();
      progress.dispose();
    }
    if (!mounted) return;
    if (error != null) {
      await showErrorDialog(context, error, stack: stack, where: 'score take');
      return;
    }
    await _loadTakes();
    if (!mounted) return;
    final scored = _takes?.where((x) => x.id == t.id).firstOrNull;
    if (scored != null) await _openResult(scored);
  }

  Future<void> _reprocess() async {
    final services = context.read<AppServices>();
    final f = services.library.files(widget.song);
    for (final p in [f.vocalsWav, f.instWav, f.notesJson, origNotesPath(f.notesJson), f.refF0Json]) {
      final file = File(p);
      if (await file.exists()) await file.delete();
    }
    widget.song
      ..stage = PrepStage.pending
      ..error = null;
    await services.library.save(widget.song);
    services.pipeline.enqueue(widget.song);
  }

  /// Saves the reference melody (with the edits, the beat grid as tempo map
  /// and the lyrics) as a Standard MIDI File.
  Future<void> _exportMidi() async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await MelodyMidi.forSong(services.library.files(widget.song), title: widget.song.title);
    if (bytes == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('library.midiNoNotes'))));
      return;
    }
    final name = widget.song.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final uri = await FilePicker.saveFile(fileName: '$name.mid', bytes: bytes);
    if (uri == null) return;
    messenger.showSnackBar(SnackBar(content: Text(tr('library.midiSaved', {'path': uri.toFilePath()}))));
  }

  /// Songs from local files: pick a picture to show (and to send along with
  /// the song when a replay includes it).
  Future<void> _pickCover() async {
    final services = context.read<AppServices>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await FilePicker.pickFiles(dialogTitle: tr('library.coverPick'), type: FileType.custom, allowedExtensions: kCoverExtensions);
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null) return;
    try {
      await setSongCover(services.sidecars, services.library.files(widget.song), path);
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(tr('library.coverFailed'))));
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _removeCover() async {
    await removeSongCover(context.read<AppServices>().library.files(widget.song));
    if (mounted) setState(() {});
  }

  /// Debug builds only: imports a vocal recording as a take of this song,
  /// lined up with the song, then scores it and opens the results as after
  /// singing (or leaves it in the list to score with the Score button).
  Future<void> _importTake() async {
    // kDebugMode first: a constant false in releases, so this is compiled out.
    if (!kDebugMode || !devFeatures(context.read<AppSettings>())) return;
    final services = context.read<AppServices>();
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['wav', 'mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus']);
    final source = picked.isEmpty ? null : picked.first.path;
    if (source == null || !mounted) return;
    final options = await showDialog<(bool, bool)>(context: context, builder: (_) => _ImportTakeDialog(name: File(source).uri.pathSegments.last));
    if (options == null || !mounted) return;
    final (align, scoreNow) = options;
    final progress = ValueNotifier(const TakeProcessing('debug.importing', 0));
    final nav = Navigator.of(context);
    showDialog<void>(
      context: context,
      // Scoring cannot be stopped part way.
      builder: (_) => AppDialog(
        canClose: false,
        content: ValueListenableBuilder<TakeProcessing>(
          valueListenable: progress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(p.stage)),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: p.fraction > 0 ? p.fraction : null),
          ]),
        ),
      ),
    );
    final song = widget.song;
    final files = services.library.files(song);
    ImportedTake? imported;
    ScoreData? score;
    Object? error;
    StackTrace? stack;
    try {
      imported = await TakeImport(library: services.library, sidecars: services.sidecars, engine: services.engine, cacheDir: services.paths.cache)
          .importVocal(song, source, align: align, onProgress: (f, _) => progress.value = TakeProcessing('debug.importing', f));
      if (scoreNow) {
        score = await SingSession.scoreTake(
          services: services,
          files: files,
          take: imported.take,
          octaveInvariant: services.settings.octaveInvariant,
          onProgress: (p) => progress.value = p,
        );
      }
    } catch (e, st) {
      error = e;
      stack = st;
    } finally {
      nav.pop();
      progress.dispose();
    }
    if (!mounted) return;
    if (error != null) {
      await showErrorDialog(context, error, stack: stack, where: 'import take');
      return;
    }
    final take = imported!.take;
    if (score == null) {
      setState(() => _expanded = true);
      await _loadTakes();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('debug.imported', {'delay': imported.delay.toStringAsFixed(2)}))));
      return;
    }
    // As after singing: the best before this take decides the celebration.
    double? previousBest;
    for (final t in await services.library.takes(song)) {
      if (t.id == take.id || t.total == null) continue;
      if (previousBest == null || t.total! > previousBest) previousBest = t.total;
    }
    if (!mounted) return;
    await nav.push(MaterialPageRoute(
      builder: (_) => ResultsScreen(song: song, take: take, score: score, newRecord: previousBest == null || score!.total > previousBest, previousBest: previousBest),
    ));
    if (mounted && _expanded) await _loadTakes();
  }

  /// Deletes one take (its recording, pitch and score) after asking; it
  /// leaves the history too, and the best score moves to the next take.
  Future<void> _deleteTake(TakeInfo t, {required bool isBest}) async {
    final services = context.read<AppServices>();
    final when = t.createdAt.toLocal().toString().split('.').first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) {
        final cs = Theme.of(c).colorScheme;
        return AppDialog(
          title: Text(tr('library.deleteTakeTitle')),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '${widget.song.title}\n$when${t.total == null ? '' : ' · ${t.total!.toStringAsFixed(1)} ${t.rank ?? ''}'}'.trimRight(),
                style: Theme.of(c).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Text(tr('library.deleteTakeBody')),
              if (isBest) ...[
                const SizedBox(height: 8),
                Text(tr('library.deleteTakeBest'), style: TextStyle(color: cs.error)),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('deleteForever')),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    await services.library.deleteTakes(widget.song, [t]);
    if (!mounted) return;
    await _loadTakes();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('library.takeDeleted'))));
  }

  /// Hides the song from the list; it comes back from the hidden songs
  /// (or the snack bar's undo). Nothing is deleted.
  Future<void> _hide() async {
    final settings = context.read<AppSettings>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final song = widget.song;
    await settings.setSongHidden(song.id, true);
    messenger?.showSnackBar(SnackBar(
      content: Text(tr('library.hidden', {'title': song.title})),
      persist: false, // an action makes it stay by default
      action: SnackBarAction(label: tr('history.undo'), onPressed: () => settings.setSongHidden(song.id, false)),
    ));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AppDialog(
        title: Text(tr('deleteForever')),
        content: Text(tr('library.deleteConfirm', {'title': widget.song.title})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error, foregroundColor: Theme.of(c).colorScheme.onError),
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('deleteForever')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final services = context.read<AppServices>();
    // Wait until nothing writes into the song folder any more, or deleting
    // it can fail (Windows keeps open files) and the job could recreate it.
    await services.pipeline.cancel(widget.song.id);
    await services.library.delete(widget.song);
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final status = widget.status;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final stage = status?.stage ?? song.stage;
    final inProgress = status != null && stage != PrepStage.done && stage != PrepStage.failed;
    final ready = song.stage == PrepStage.done && !inProgress;
    // Not done and not running: it failed, or the app closed mid-way
    // (e.g. quit during separation). Either way it can pick up where it left.
    final failed = !inProgress && stage != PrepStage.done;
    final needsDownload = stage == PrepStage.failed && !inProgress && song.sourceUrl != null && (song.sourceFile == null || !File(song.sourceFile!).existsSync());
    final services = context.read<AppServices>();
    final dir = services.library.files(song).dir;
    final hasCover = song.sourceType == SourceType.file && File(services.library.files(song).coverJpg).existsSync();
    final best = _best;

    // The best take's rank colour down the left edge (grey before any).
    final accent = best != null ? rankColor(best.rank) : cs.outlineVariant;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 5),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _hover ? cs.surfaceContainerHigh : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _hover ? accent.withValues(alpha: 0.5) : cs.outlineVariant.withValues(alpha: 0.25)),
          boxShadow: [if (_hover) BoxShadow(color: accent.withValues(alpha: 0.12), blurRadius: 20)],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [accent, accent.withValues(alpha: 0.4)])),
              ),
            ),
            Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                MouseRegion(
                  cursor: ready ? SystemMouseCursors.click : SystemMouseCursors.basic,
                  child: GestureDetector(
                    onTap: ready ? _sing : null,
                    child: Tooltip(
                      message: ready ? tr('library.sing') : '',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 128,
                          height: 72,
                          child: Stack(fit: StackFit.expand, children: [
                            AnimatedScale(
                              scale: _hover ? 1.06 : 1,
                              duration: const Duration(milliseconds: 300),
                              child: _thumb(song, services.library.files(song).shownThumb, cs),
                            ),
                            if (ready)
                              Center(
                                child: Container(
                                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                  padding: const EdgeInsets.all(4),
                                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 26),
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (song.artist.isNotEmpty) Text(song.artist, style: theme.textTheme.bodySmall),
                          Text(formatDuration(song.durationSec), style: theme.textTheme.bodySmall),
                          _Badge(text: tr('source.${song.sourceType.name}'), icon: song.sourceType == SourceType.youtube ? Icons.smart_display : Icons.insert_drive_file),
                          _Badge(text: tr('lang.${song.language}')),
                          if (_hasLyrics(services.library.files(song).lyricsJson)) _Badge(text: tr('library.lyrics'), icon: Icons.subtitles),
                          if (services.library.files(song).hasUserInst) _Badge(text: tr('backing.badge'), icon: Icons.library_music),
                          _Badge(
                            text: tr('stage.${stage.name}'),
                            color: stage == PrepStage.done ? const Color(0xFF2E7D32) : (stage == PrepStage.failed ? cs.error : cs.secondaryContainer),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (best != null) ...[
                  const SizedBox(width: 12),
                  Tooltip(
                    message: tr('library.bestScore'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.emoji_events, color: trophyColor, size: 22),
                        const SizedBox(width: 4),
                        Text(
                          best.total!.toStringAsFixed(1),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: rankColor(best.rank),
                            fontFeatures: const [FontFeature.tabularFigures()],
                            shadows: [if (rankTier(best.rank) > 0) Shadow(color: rankColor(best.rank).withValues(alpha: 0.45), blurRadius: 14)],
                          ),
                        ),
                        const SizedBox(width: 6),
                        RankChip(rank: best.rank),
                      ],
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                if (failed)
                  // Picks up where it stopped: the pipeline skips every step
                  // whose output already exists.
                  FilledButton.icon(
                    onPressed: () => services.pipeline.enqueue(song),
                    icon: Icon(needsDownload ? Icons.download : Icons.refresh),
                    label: Text(tr(needsDownload ? 'library.redownload' : 'retry')),
                  )
                else
                  FilledButton.icon(onPressed: ready ? _sing : null, icon: const Icon(Icons.play_circle_outline), label: Text(tr('library.sing'))),
                const SizedBox(width: 4),
                if (inProgress)
                  IconButton(
                    tooltip: tr('library.cancelPrep'),
                    onPressed: services.pipeline.isCancelling(song.id) ? null : () => services.pipeline.cancel(song.id),
                    icon: const Icon(Icons.stop_circle_outlined),
                  )
                else ...[
                  IconButton(tooltip: tr('delete'), onPressed: _delete, icon: const Icon(Icons.delete_outline)),
                  PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'reprocess' => _reprocess(),
                      'folder' => revealPath(dir),
                      'lyricsImport' => pickAndImportLyrics(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'lyricsEdit' => openLyricsEditor(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'lyricsPaste' => pasteLyrics(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'lyricsWhisper' => recognizeLyrics(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'backingImport' => importBackingTrack(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'backingRevert' => revertBackingTrack(context, song).then((ok) => ok && mounted ? setState(() {}) : null),
                      'lyricsExport' => exportLyrics(context, song),
                      'midiExport' => _exportMidi(),
                      'coverSet' => _pickCover(),
                      'coverRemove' => _removeCover(),
                      'hide' => _hide(),
                      'importTake' => _importTake(),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'reprocess', child: ListTile(leading: const Icon(Icons.refresh), title: Text(tr('library.reprocess')))),
                      PopupMenuItem(value: 'folder', child: ListTile(leading: const Icon(Icons.folder_open), title: Text(tr('library.showFolder')))),
                      PopupMenuItem(value: 'hide', child: ListTile(leading: const Icon(Icons.visibility_off_outlined), title: Text(tr('library.hide')))),
                      if (song.sourceType == SourceType.file) ...[
                        PopupMenuItem(
                          value: 'coverSet',
                          child: ListTile(leading: const Icon(Icons.image_outlined), title: Text(tr(hasCover ? 'library.coverChange' : 'library.coverSet'))),
                        ),
                        if (hasCover) PopupMenuItem(value: 'coverRemove', child: ListTile(leading: const Icon(Icons.hide_image_outlined), title: Text(tr('library.coverRemove')))),
                      ],
                      const PopupMenuDivider(),
                      PopupMenuItem(value: 'lyricsImport', child: ListTile(leading: const Icon(Icons.file_open_outlined), title: Text(tr('lyrics.import')))),
                      PopupMenuItem(value: 'lyricsPaste', child: ListTile(leading: const Icon(Icons.content_paste), title: Text(tr('lyrics.paste')))),
                      PopupMenuItem(value: 'lyricsEdit', child: ListTile(leading: const Icon(Icons.edit_note), title: Text(tr('lyrics.edit')))),
                      PopupMenuItem(value: 'lyricsWhisper', child: ListTile(leading: const Icon(Icons.graphic_eq), title: Text(tr('lyrics.whisper')))),
                      PopupMenuItem(value: 'lyricsExport', child: ListTile(leading: const Icon(Icons.subtitles_outlined), title: Text(tr('lyrics.export')))),
                      // Needs the prepared song (its separated tracks to align with).
                      if (song.stage == PrepStage.done) ...[
                        const PopupMenuDivider(),
                        PopupMenuItem(value: 'midiExport', child: ListTile(leading: const Icon(Icons.piano_outlined), title: Text(tr('library.exportMidi')))),
                        PopupMenuItem(value: 'backingImport', child: ListTile(leading: const Icon(Icons.library_music_outlined), title: Text(tr('backing.import')))),
                        if (services.library.files(song).hasUserInst)
                          PopupMenuItem(value: 'backingRevert', child: ListTile(leading: const Icon(Icons.restore), title: Text(tr('backing.revert')))),
                        // Only in debug builds with 開發模式 on; compiled out of releases.
                        if (kDebugMode && devFeatures(context.read<AppSettings>())) ...[
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'importTake',
                            child: ListTile(leading: const Icon(Icons.bug_report_outlined), title: Text(tr('debug.importTake'))),
                          ),
                        ],
                      ],
                    ],
                  ),
                ],
                IconButton(
                  tooltip: tr('library.takes'),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () {
                    setState(() => _expanded = !_expanded);
                    if (_expanded) _loadTakes();
                  },
                ),
              ],
            ),
            if (inProgress) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: status.fraction > 0 ? status.fraction : null),
              const SizedBox(height: 4),
              Text('${tr('stage.${stage.name}')}  ${status.message}', style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (song.error != null && song.stage == PrepStage.failed) ...[
              const SizedBox(height: 6),
              SelectableText(song.error!, style: theme.textTheme.bodySmall?.copyWith(color: cs.error), maxLines: 3),
              // Logged by the pipeline when it failed.
              if (song.error != tr('library.cancelled'))
                Align(alignment: Alignment.centerLeft, child: ReportBugButton(error: song.error!, log: false)),
            ],
            if (_expanded) ...[
              const Divider(),
              if (_takes == null)
                const LinearProgressIndicator()
              else if (_takes!.isEmpty)
                Text(tr('library.noTakes'), style: theme.textTheme.bodySmall)
              else
                for (final t in _takes!)
                  _TakeRow(
                    take: t,
                    isBest: identical(t, best),
                    onView: File(t.scoreJson).existsSync() ? () => _openResult(t) : null,
                    onShare: t.total != null ? () => _share(t) : null,
                    onExport: t.total != null && File(t.f0Json).existsSync() ? () => showExportReplayDialog(context, song: song, take: t) : null,
                    onExportVideo: t.total != null && File(t.f0Json).existsSync() && File(t.wav).existsSync()
                        ? () => showExportVideoDialog(context, song: song, take: t)
                        : null,
                    onScore: t.total == null && File(t.wav).existsSync() ? () => _scoreTake(t) : null,
                    onReplay: File(t.wav).existsSync() && File(t.f0Json).existsSync()
                        ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReplayScreen(song: song, take: t)))
                        : null,
                    onDelete: () => _deleteTake(t, isBest: identical(t, best)),
                  ),
            ],
          ],
        ),
            ),
          ]),
        ),
      ),
    );
  }

  static bool _hasLyrics(String path) {
    final f = File(path);
    // An empty lyrics.json ("no subtitles") is ~60 bytes.
    return f.existsSync() && f.lengthSync() > 120;
  }

  /// Local thumbnail (YouTube image or a grabbed frame) when the prep made
  /// one, else the remote YouTube thumbnail, else a placeholder.
  Widget _thumb(Song song, String thumbPath, ColorScheme cs) {
    final file = File(thumbPath);
    if (file.existsSync()) {
      return Image.file(file, key: ValueKey(file.lastModifiedSync()), fit: BoxFit.cover, errorBuilder: (context, error, stack) => _thumbFallback(cs));
    }
    if (song.thumbnailUrl != null) {
      return Image.network(song.thumbnailUrl!, fit: BoxFit.cover, errorBuilder: (context, error, stack) => _thumbFallback(cs));
    }
    return _thumbFallback(cs);
  }

  Widget _thumbFallback(ColorScheme cs) => Container(color: cs.surfaceContainerHighest, child: Icon(Icons.music_note, color: cs.onSurface.withValues(alpha: 0.4)));
}

/// One take: score and rank up front, sub-scores in the subtitle; the best
/// take of the song is highlighted.
/// Debug builds only: how to import a vocal file as a take. Pops
/// (line it up, score it now) or null.
class _ImportTakeDialog extends StatefulWidget {
  const _ImportTakeDialog({required this.name});
  final String name;

  @override
  State<_ImportTakeDialog> createState() => _ImportTakeDialogState();
}

class _ImportTakeDialogState extends State<_ImportTakeDialog> {
  bool _align = true;
  bool _score = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialog(
      icon: const Icon(Icons.bug_report_outlined),
      title: Text(tr('debug.importTake')),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.name, style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(tr('debug.importBody'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _align,
            onChanged: (v) => setState(() => _align = v ?? true),
            title: Text(tr('debug.importAlign')),
            subtitle: Text(tr('debug.importAlignHint')),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _score,
            onChanged: (v) => setState(() => _score = v ?? true),
            title: Text(tr('debug.importScore')),
            subtitle: Text(tr('debug.importScoreHint')),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, (_align, _score)), child: Text(tr('debug.importGo'))),
      ],
    );
  }
}

/// The songs hidden from the library, each with a button to show it again.
class _HiddenSongsDialog extends StatelessWidget {
  const _HiddenSongsDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final library = context.watch<SongLibrary>();
    final settings = context.watch<AppSettings>();
    final hidden = settings.hiddenSongs;
    final songs = library.songs.where((s) => hidden.contains(s.id)).toList();
    return AppDialog(
      title: Text(tr('library.hiddenTitle')),
      content: SizedBox(
        width: 520,
        child: songs.isEmpty
            ? Text(tr('library.hiddenNone'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(tr('library.hiddenHint'), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: ListView(shrinkWrap: true, children: [
                    for (final song in songs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 64,
                            height: 36,
                            child: File(library.files(song).shownThumb).existsSync()
                                ? Image.file(File(library.files(song).shownThumb), fit: BoxFit.cover)
                                : ColoredBox(color: cs.surfaceContainerHighest, child: Icon(Icons.music_note, size: 18, color: cs.onSurfaceVariant)),
                          ),
                        ),
                        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: TextButton.icon(
                          onPressed: () => settings.setSongHidden(song.id, false),
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: Text(tr('library.unhide')),
                        ),
                      ),
                  ]),
                ),
              ]),
      ),
      actions: [
        if (songs.length > 1)
          TextButton(
            onPressed: () async {
              for (final s in songs) {
                await settings.setSongHidden(s.id, false);
              }
            },
            child: Text(tr('library.unhideAll')),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('close'))),
      ],
    );
  }
}

class _TakeRow extends StatelessWidget {
  const _TakeRow({required this.take, required this.isBest, required this.onView, this.onReplay, this.onShare, this.onExport, this.onExportVideo, this.onScore, this.onDelete});
  final TakeInfo take;
  final bool isBest;
  final VoidCallback? onView;
  final VoidCallback? onReplay;
  final VoidCallback? onShare;
  final VoidCallback? onExport;
  final VoidCallback? onExportVideo;
  final VoidCallback? onScore;
  final VoidCallback? onDelete;

  static const _order = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];
  static String _camel(String k) => k == 'long_tone' ? 'longTone' : k;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = take;
    final date = t.createdAt.toLocal().toString().split('.').first;
    final color = rankColor(t.rank);
    final parts = <String>[
      for (final k in _order)
        if (t.subScores.containsKey(k)) '${tr('results.${_camel(k)}')} ${t.subScores[k] == null ? '—' : t.subScores[k]!.round()}',
    ];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: isBest
          ? BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.7)),
            )
          : null,
      // Its own Material, so the best take's highlight does not hide the ink.
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
        dense: true,
        onTap: onView,
        leading: t.total == null
            ? Icon(Icons.graphic_eq, color: cs.onSurfaceVariant)
            : SizedBox(
                width: 110,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t.total!.toStringAsFixed(1), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: color)),
                    const SizedBox(width: 6),
                    RankChip(rank: t.rank, fontSize: 12),
                  ],
                ),
              ),
        title: Row(
          children: [
            Text(date, style: theme.textTheme.bodyMedium),
            if (isBest) ...[
              const SizedBox(width: 8),
              const Icon(Icons.emoji_events, size: 16, color: trophyColor),
              const SizedBox(width: 2),
              Text(tr('library.bestTake'), style: theme.textTheme.labelMedium?.copyWith(color: trophyColor, fontWeight: FontWeight.w700)),
            ],
          ],
        ),
        subtitle: t.total == null ? Text(tr('library.notScored'), style: theme.textTheme.bodySmall) : Text(parts.join(' · '), style: theme.textTheme.bodySmall),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (onReplay != null)
            IconButton(tooltip: tr('replay.button'), onPressed: onReplay, icon: const Icon(Icons.play_circle_outline)),
          if (onShare != null)
            IconButton(tooltip: tr('share.button'), onPressed: onShare, icon: const Icon(Icons.share)),
          if (onExport != null)
            IconButton(tooltip: tr('export.button'), onPressed: onExport, icon: const Icon(Icons.ios_share)),
          if (onExportVideo != null)
            IconButton(tooltip: tr('video.button'), onPressed: onExportVideo, icon: const Icon(Icons.movie_outlined)),
          if (onDelete != null)
            IconButton(tooltip: tr('library.deleteTake'), onPressed: onDelete, icon: Icon(Icons.delete_outline, color: cs.onSurfaceVariant)),
          if (onScore != null)
            TextButton(onPressed: onScore, child: Text(tr('library.scoreTake')))
          else
            TextButton(onPressed: onView, child: Text(tr('library.viewResult'))),
        ]),
      )),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.icon, this.color});
  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = color ?? cs.surfaceContainerHighest;
    final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : Colors.black87;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 3)],
          Text(text, style: TextStyle(fontSize: 11, color: fg)),
        ],
      ),
    );
  }
}
