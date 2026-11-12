// Runs lyrics recognition (Whisper) or timing of pasted lyrics with
// progress: asks to download the Whisper model the first time (with its
// size), waits for the song's preparation when the vocals or notes are not
// ready yet, then runs with a cancel button.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/lyrics_recognizer.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../../state/setup_controller.dart';
import '../startup/setup_rows.dart';

/// What to do: recognise with Whisper, or time [pasted] lyrics (with
/// Whisper when [useWhisper], else from the notes).
class RecognizeRequest {
  const RecognizeRequest.recognize()
      : pasted = null,
        useWhisper = true,
        language = null;
  const RecognizeRequest.align(String this.pasted, {required this.useWhisper, this.language});
  final String? pasted;
  final bool useWhisper;

  /// Language the song is sung in (see [LyricsRecognizer.languages]); null
  /// detects it.
  final String? language;
}

/// Choice chips for the song's language: "detect" (null) or one of
/// [LyricsRecognizer.languages].
class LanguageChips extends StatelessWidget {
  const LanguageChips({super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 6, children: [
        ChoiceChip(
          avatar: const Icon(Icons.auto_awesome, size: 18),
          label: Text(tr('recognize.langAuto')),
          selected: value == null,
          onSelected: (_) => onChanged(null),
        ),
        for (final l in LyricsRecognizer.languages)
          ChoiceChip(label: Text(tr('lang.$l')), selected: value == l, onSelected: (_) => onChanged(l)),
      ]);
}

/// Shows the dialog; true when new lyrics were saved.
Future<bool> showRecognizeDialog(BuildContext context, Song song, RecognizeRequest request) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RecognizeDialog(song: song, request: request),
  );
  return ok ?? false;
}

enum _Phase { choose, checking, needModel, downloading, waitingPrep, running, failed }

class _RecognizeDialog extends StatefulWidget {
  const _RecognizeDialog({required this.song, required this.request});
  final Song song;
  final RecognizeRequest request;

  @override
  State<_RecognizeDialog> createState() => _RecognizeDialogState();
}

class _RecognizeDialogState extends State<_RecognizeDialog> {
  late final AppServices _services = context.read<AppServices>();
  late final LyricsRecognizer _recognizer = LyricsRecognizer(
    library: _services.library,
    models: _services.models,
    backend: _services.backend,
    pipeline: _services.pipeline,
  );
  late _Phase _phase = widget.request.pasted == null ? _Phase.choose : _Phase.checking;
  String? _language; // for recognition; null = detect
  double _fraction = 0;
  String _stage = '';
  String _error = '';
  final _cancel = Completer<void>();
  final _clock = Stopwatch();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _services.pipeline.addListener(_onPipeline);
    if (_phase != _Phase.choose) _next();
  }

  @override
  void dispose() {
    _services.pipeline.removeListener(_onPipeline);
    _tick?.cancel();
    super.dispose();
  }

  bool get _needsWhisper => widget.request.useWhisper;

  bool get _songReady => _needsWhisper ? _recognizer.audioFor(widget.song) != null && !_preparing : _recognizer.hasNotes(widget.song);

  bool get _preparing => _services.pipeline.isQueued(widget.song.id);

  void _onPipeline() {
    if (_phase == _Phase.waitingPrep && mounted) {
      if (_songReady) {
        _next();
      } else if (!_preparing) {
        _fail(tr('recognize.notPrepared'));
      } else {
        setState(() {});
      }
    }
  }

  /// Moves to the next step that is needed.
  Future<void> _next() async {
    if (_needsWhisper && !await _recognizer.modelInstalled) {
      if (!mounted) return;
      final setup = context.read<SetupController>();
      setState(() => _phase = setup.stateOf(_recognizer.model).downloading ? _Phase.downloading : _Phase.needModel);
      return;
    }
    if (!_songReady) {
      if (!mounted) return;
      if (_preparing) {
        setState(() => _phase = _Phase.waitingPrep);
      } else {
        _fail(tr('recognize.notPrepared'));
      }
      return;
    }
    await _run();
  }

  Future<void> _download() async {
    final setup = context.read<SetupController>();
    setState(() => _phase = _Phase.downloading);
    await setup.install(_recognizer.model);
    if (!mounted) return;
    final s = setup.stateOf(_recognizer.model);
    if (s.installed) {
      await _next();
    } else {
      setState(() => _phase = _Phase.needModel); // cancelled or failed; the row shows the error
    }
  }

  Future<void> _run() async {
    setState(() {
      _phase = _Phase.running;
      _stage = 'load';
    });
    _clock.start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    void progress(double f, String stage) {
      if (mounted) {
        setState(() {
          _fraction = f;
          _stage = stage;
        });
      }
    }

    try {
      final req = widget.request;
      final track = req.pasted == null
          ? await _recognizer.recognize(widget.song, language: _language, onProgress: progress, cancel: _cancel)
          : await _recognizer.align(widget.song, req.pasted!, useWhisper: req.useWhisper, language: req.language, onProgress: progress, cancel: _cancel);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(SnackBar(content: Text(tr(req.pasted == null ? 'recognize.doneWhisper' : 'recognize.doneAlign', {'n': '${track.lines.length}'}))));
    } on NothingRecognized {
      _fail(tr('recognize.noneFound'));
    } catch (e) {
      if (_cancel.isCompleted) {
        if (mounted) Navigator.of(context).pop(false);
        return;
      }
      _fail('$e');
    } finally {
      _tick?.cancel();
      _clock.stop();
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = message;
    });
  }

  String get _title => widget.request.pasted != null ? tr('recognize.titleAlign') : tr('recognize.titleWhisper');

  String _elapsed() {
    final s = _clock.elapsed.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final model = _recognizer.model;
    final List<Widget> body;
    List<Widget> actions;
    switch (_phase) {
      case _Phase.choose:
        body = [
          Text(tr('recognize.chooseLang'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          LanguageChips(value: _language, onChanged: (v) => setState(() => _language = v)),
          const SizedBox(height: 10),
          Text(tr('recognize.langHint'), style: muted),
        ];
        actions = [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('cancel'))),
          FilledButton.icon(
            onPressed: () {
              setState(() => _phase = _Phase.checking);
              _next();
            },
            icon: const Icon(Icons.auto_awesome),
            label: Text(tr('recognize.start')),
          ),
        ];
      case _Phase.checking:
        body = [const LinearProgressIndicator()];
        actions = [];
      case _Phase.needModel:
      case _Phase.downloading:
        body = [
          Text(tr('recognize.needModel', {'size': formatBytes(model.totalBytes)})),
          // The row shows the download's progress (and an error, if any).
          if (_phase == _Phase.downloading || context.watch<SetupController>().stateOf(model).error != null) ...[
            const SizedBox(height: 12),
            ModelRow(spec: model),
          ],
        ];
        actions = [
          TextButton(
            onPressed: () {
              if (_phase == _Phase.downloading) context.read<SetupController>().cancel(model);
              Navigator.of(context).pop(false);
            },
            child: Text(tr('cancel')),
          ),
          if (_phase == _Phase.needModel)
            FilledButton.icon(onPressed: _download, icon: const Icon(Icons.download), label: Text(tr('recognize.download', {'size': formatBytes(model.totalBytes)}))),
        ];
      case _Phase.waitingPrep:
        final st = _services.pipeline.statusOf(widget.song.id);
        body = [
          Text(tr('recognize.waitingPrep')),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: st != null && st.fraction > 0 ? st.fraction : null),
          if (st != null) ...[
            const SizedBox(height: 4),
            Text(tr('stage.${st.stage.name}'), style: muted),
          ],
        ];
        actions = [TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('cancel')))];
      case _Phase.running:
        final stageText = switch (_stage) {
          'load' || 'decode' => tr('recognize.loading'),
          'align' => tr('recognize.aligning'),
          _ => tr('recognize.running', {'pct': '${(_fraction * 100).round()}'}),
        };
        body = [
          Text(stageText),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _stage == 'recognize' && _fraction > 0 ? _fraction : null),
          const SizedBox(height: 6),
          Text('${tr('recognize.elapsed')} ${_elapsed()}', style: muted),
          if (_needsWhisper) ...[
            const SizedBox(height: 8),
            Text(tr('recognize.slowHint'), style: muted),
          ],
        ];
        actions = [
          TextButton(
            // Closes at once: the engine stops at its next step in the
            // background and nothing is saved.
            onPressed: () {
              if (!_cancel.isCompleted) _cancel.complete();
              Navigator.of(context).pop(false);
            },
            child: Text(tr('cancel')),
          ),
        ];
      case _Phase.failed:
        body = [SelectableText(_error, style: TextStyle(color: theme.colorScheme.error))];
        actions = [TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('close')))];
    }
    return AlertDialog(
      icon: Icon(widget.request.pasted != null ? Icons.format_align_left : Icons.graphic_eq),
      title: Text(_title),
      content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: body)),
      actions: actions,
    );
  }
}
