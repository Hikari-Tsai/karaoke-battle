// "AI singing tips": two ways to get advice on a take from an AI.
//  - Copy or download a Markdown file (instructions plus the take's
//    analysis) and give it to an AI assistant of your choice.
//  - "Ask AI": send the same file to Claude or OpenAI with the API key from
//    Settings and show the answer here. Without a key the settings dialog
//    opens first and the request goes on once one is saved.
// The answer is kept in the take folder so it is not asked for twice.
import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../advice/advice_prompt.dart';
import '../../advice/ai_advice.dart';
import '../../advice/take_analysis.dart';
import '../../advice/take_analysis_loader.dart';
import '../../services/settings.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../replays/export_replay_dialog.dart' show replayBaseName;
import '../settings/ai_settings_dialog.dart';
import '../widgets/error_report.dart';

Future<void> showAiAnalysisDialog(BuildContext context, {required Song song, required TakeInfo take}) {
  return showDialog<void>(context: context, barrierDismissible: false, builder: (_) => _AiAnalysisDialog(song: song, take: take));
}

enum _View { menu, asking, result, failed }

const _providers = ['claude', 'openai'];
const _providerNames = {'claude': 'Claude', 'openai': 'OpenAI'};

class _AiAnalysisDialog extends StatefulWidget {
  const _AiAnalysisDialog({required this.song, required this.take});
  final Song song;
  final TakeInfo take;

  @override
  State<_AiAnalysisDialog> createState() => _AiAnalysisDialogState();
}

class _AiAnalysisDialogState extends State<_AiAnalysisDialog> {
  TakeAnalysis? _analysis;
  String _appVersion = '';
  bool _includeTitle = true;
  bool _busy = false;
  String? _error; // loading or saving the file

  _View _view = _View.menu;
  SavedAdvice? _saved;
  AiAdviceException? _askError;
  String _askingModel = '';
  http.Client? _client;
  bool _cancelled = false;

  /// Services with a saved API key, and the one "Ask AI" will use (the
  /// user picks when both have one).
  Set<String> _available = const {};
  String _askProvider = 'claude';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final services = context.read<AppServices>();
      final input = await loadTakeAnalysisInput(
        library: services.library,
        song: widget.song,
        take: widget.take,
        ownRangeKeys: services.settings.ownRangeKeys,
      );
      final analysis = analyzeTake(input);
      var version = '';
      try {
        version = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      // An earlier answer in this language is shown straight away.
      SavedAdvice? saved = await SavedAdvice.load(widget.take.adviceJson);
      if (saved != null && saved.lang == I18n.lang) {
        try {
          saved = SavedAdvice(advice: validateAdvice(saved.advice, analysis), provider: saved.provider, model: saved.model, lang: saved.lang, createdAt: saved.createdAt);
        } on AiAdviceException {
          saved = null;
        }
      } else {
        saved = null;
      }
      final available = await _availableProviders(services);
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _appVersion = version;
        _saved = saved;
        _available = available;
        _askProvider = _pick(services.settings.aiProvider, available);
        if (saved != null) _view = _View.result;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _markdown() => buildAdvicePrompt(_analysis!, lang: I18n.lang, includeTitle: _includeTitle, appVersion: _appVersion);

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: _markdown()));
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger?.showSnackBar(SnackBar(content: Text(tr('advice.copied'))));
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final base = replayBaseName(_includeTitle ? widget.song.title : 'Karaoke Battle', widget.take.total);
      final uri = await FilePicker.saveFile(
        dialogTitle: tr('advice.saveTitle'),
        fileName: '$base AI.md',
        bytes: Uint8List.fromList(utf8.encode(_markdown())),
        mimeType: 'text/markdown',
      );
      if (!mounted) return;
      if (uri == null) {
        setState(() => _busy = false);
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(tr('advice.saved', {'path': uri.toFilePath()}))));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  static Future<Set<String>> _availableProviders(AppServices services) async {
    final out = <String>{};
    for (final p in _providers) {
      try {
        if (await services.aiKeys.read(p) != null) out.add(p);
      } catch (_) {}
    }
    return out;
  }

  /// [preferred] when it has a key (or nothing has), else the one that has.
  static String _pick(String preferred, Set<String> available) => available.contains(preferred) || available.isEmpty ? preferred : available.first;

  /// Asks an AI service that has a key: [provider] or the one chosen in the
  /// dialog. Without any key the settings dialog comes first and the
  /// request goes on once one is saved.
  Future<void> _ask({String? provider}) async {
    final services = context.read<AppServices>();
    var available = await _availableProviders(services);
    if (available.isEmpty) {
      if (!mounted || !await showAiSettingsDialog(context, needKey: true)) return;
      available = await _availableProviders(services);
      if (available.isEmpty || !mounted) return;
      provider = _pick(services.settings.aiProvider, available);
    }
    final chosen = _pick(provider ?? _askProvider, available);
    String? key;
    try {
      key = await services.aiKeys.read(chosen);
    } catch (_) {}
    if (key == null || !mounted) return;
    // Remembered as the default for next time.
    if (services.settings.aiProvider != chosen) unawaited(services.settings.setAiProvider(chosen));
    final model = services.settings.aiModel(chosen);
    _available = available;
    _askProvider = chosen;
    final analysis = _analysis!;
    final lang = I18n.lang;
    final client = http.Client();
    _client = client;
    _cancelled = false;
    setState(() {
      _view = _View.asking;
      _askingModel = model;
      _askError = null;
    });
    try {
      final raw = await requestAdvice(provider: AiProvider.byName(chosen), apiKey: key, model: model, prompt: _markdown(), lang: lang, client: client);
      final saved = SavedAdvice(advice: validateAdvice(raw, analysis), provider: chosen, model: model, lang: lang, createdAt: DateTime.now());
      try {
        await saved.save(widget.take.adviceJson);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _view = _View.result;
      });
    } on AiAdviceException catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _askError = e;
        _view = _View.failed;
      });
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _askError = AiAdviceException('badResponse', '$e');
        _view = _View.failed;
      });
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  void _cancelAsk() {
    _cancelled = true;
    _client?.close();
    setState(() => _view = _View.menu);
  }

  Future<void> _copyAdvice() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: _saved!.advice.toPlainText()));
    messenger?.showSnackBar(SnackBar(content: Text(tr('advice.textCopied'))));
  }

  Future<void> _editKeyAndRetry() async {
    final saved = await showAiSettingsDialog(context);
    if (!mounted) return;
    final services = context.read<AppServices>();
    final available = await _availableProviders(services);
    if (!mounted) return;
    setState(() => _available = available);
    if (saved) await _ask(provider: services.settings.aiProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('advice.title')),
      content: SizedBox(
        width: 560,
        child: switch (_view) {
          _View.menu => _menu(context),
          _View.asking => _asking(context),
          _View.result => _result(context),
          _View.failed => _failed(context),
        },
      ),
      actions: switch (_view) {
        _View.menu => [
            if (_error != null && !_busy) ReportBugButton(error: _error!, where: 'ai analysis'),
            TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(tr('cancel'))),
            OutlinedButton.icon(onPressed: _ready ? _copy : null, icon: const Icon(Icons.copy), label: Text(tr('advice.copy'))),
            OutlinedButton.icon(
              onPressed: _ready ? _save : null,
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
              label: Text(tr('advice.save')),
            ),
            FilledButton.icon(onPressed: _ready ? () => _ask() : null, icon: const Icon(Icons.auto_awesome), label: Text(tr('advice.ask'))),
          ],
        _View.asking => [TextButton(onPressed: _cancelAsk, child: Text(tr('cancel')))],
        _View.result => [
            OutlinedButton.icon(onPressed: _copyAdvice, icon: const Icon(Icons.copy), label: Text(tr('advice.copyText'))),
            // Back to the first view, to pick the service and ask again (or copy / download).
            OutlinedButton.icon(onPressed: () => setState(() => _view = _View.menu), icon: const Icon(Icons.refresh), label: Text(tr('advice.regenerate'))),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('advice.close'))),
          ],
        _View.failed => [
            TextButton(onPressed: () => setState(() => _view = _View.menu), child: Text(tr('advice.back'))),
            if (_askError?.kind == 'auth' || _askError?.kind == 'badRequest')
              OutlinedButton.icon(onPressed: _editKeyAndRetry, icon: const Icon(Icons.key), label: Text(tr('advice.editKey'))),
            FilledButton.icon(onPressed: () => _ask(), icon: const Icon(Icons.refresh), label: Text(tr('advice.retry'))),
          ],
      },
    );
  }

  bool get _ready => _analysis != null && !_busy;

  String _providerLabel(String p) => '${_providerNames[p]} · ${context.read<AppSettings>().aiModel(p)}';

  /// Which service "Ask AI" uses: a choice when both have a key, a note
  /// when one has, nothing when none has (the settings dialog will ask).
  List<Widget> _providerChoice(BuildContext context) {
    final theme = Theme.of(context);
    if (_available.isEmpty) return const [];
    if (_available.length == 1) {
      return [
        const SizedBox(height: 6),
        Text(tr('advice.askWithOne', {'service': _providerLabel(_available.first)}), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ];
    }
    return [
      const SizedBox(height: 10),
      Row(
        children: [
          Text(tr('advice.askWith'), style: theme.textTheme.bodyMedium),
          const SizedBox(width: 12),
          Expanded(
            child: SegmentedButton<String>(
              segments: [for (final p in _providers) ButtonSegment(value: p, label: Text(_providerLabel(p), overflow: TextOverflow.ellipsis))],
              selected: {_askProvider},
              showSelectedIcon: false,
              onSelectionChanged: _busy ? null : (s) => setState(() => _askProvider = s.first),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _menu(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('advice.steps'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
        const SizedBox(height: 10),
        Text(tr('advice.direct'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.6)),
        ..._providerChoice(context),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(child: Text(tr('advice.tokens'), style: muted)),
        ]),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _includeTitle,
          onChanged: _busy ? null : (v) => setState(() => _includeTitle = v ?? true),
          title: Text(tr('advice.includeTitle')),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
        ),
        if (_analysis == null && _error == null) const LinearProgressIndicator(),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _asking(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('advice.asking', {'model': _askingModel}), style: theme.textTheme.bodyLarge),
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        Text(tr('advice.askingHint'), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final theme = Theme.of(context);
    final e = _askError!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(tr('advice.err.${e.kind}', {'detail': e.detail}), style: theme.textTheme.bodyMedium)),
        ]),
        if (e.detail.isNotEmpty && e.kind != 'badRequest') ...[
          const SizedBox(height: 8),
          SelectableText(e.detail, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final saved = _saved!;
    final analysis = _analysis!;
    final muted = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final findings = {for (final f in analysis.findings) f.id: f};
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.62),
      child: SingleChildScrollView(
        child: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (saved.advice.summary.isNotEmpty) Text(saved.advice.summary, style: theme.textTheme.bodyLarge?.copyWith(height: 1.5)),
              const SizedBox(height: 12),
              for (final t in saved.advice.tips)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      // The numbers come from the analysis, not from the AI's text.
                      for (final id in t.findingIds)
                        if (findings[id] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('[$id] ${findingTitle(findings[id]!, saved.lang)} — ${describeFinding(findings[id]!, analysis, saved.lang)}', style: muted),
                          ),
                      if (t.advice.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(t.advice, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
                      ],
                      if (t.exercise.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${tr('advice.exercise')}　', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700)),
                            TextSpan(text: t.exercise),
                          ]),
                          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              if (saved.advice.closing.isNotEmpty) Text(saved.advice.closing, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
              const SizedBox(height: 10),
              Text(tr('advice.from', {'model': saved.model, 'time': DateFormat('yyyy-MM-dd HH:mm').format(saved.createdAt)}), style: muted),
            ],
          ),
        ),
      ),
    );
  }
}
