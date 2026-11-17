// The AI service used by "Ask AI" on the results screen: provider, API key
// and model. Opened from Settings, and from the AI singing tips dialog when
// no key has been entered yet.
//
// The model menu lists what the key can use, fetched from the service's
// models endpoint (which also tells a wrong key at once). "Custom…" and a
// failed fetch fall back to typing a model id.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../advice/ai_advice.dart';
import '../../services/settings.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';

const _keyPages = {
  'claude': 'https://console.anthropic.com/settings/keys',
  'openai': 'https://platform.openai.com/api-keys',
};

const _serviceNames = {'claude': 'Anthropic', 'openai': 'OpenAI'};

const _customItem = '\u0000custom';

/// Returns true when it was saved with an API key for the chosen service.
/// [needKey] explains that a key is needed to go on.
Future<bool> showAiSettingsDialog(BuildContext context, {bool needKey = false}) async {
  return await showDialog<bool>(context: context, builder: (_) => _AiSettingsDialog(needKey: needKey)) ?? false;
}

class _AiSettingsDialog extends StatefulWidget {
  const _AiSettingsDialog({required this.needKey});
  final bool needKey;

  @override
  State<_AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<_AiSettingsDialog> {
  static const _providers = ['claude', 'openai'];

  late String _provider;
  final _keys = {for (final p in _providers) p: TextEditingController()};
  final _models = {for (final p in _providers) p: TextEditingController()};

  /// Models the key can use, per provider (from the last fetch, at first
  /// the one remembered in the settings).
  final _lists = {for (final p in _providers) p: <AiModelInfo>[]};
  final _fetching = {for (final p in _providers) p: false};
  final _listError = <String, AiAdviceException?>{};
  final _custom = {for (final p in _providers) p: false};

  /// Services whose key is saved in the keychain (they can be deleted).
  final _stored = <String>{};
  String? _notice;

  /// The key the list was last fetched with: it is known to work.
  final _checkedKey = <String, String>{};
  final _fetchSeq = <String, int>{};

  final _client = http.Client();
  Timer? _debounce;
  bool _loading = true;
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    _provider = services.settings.aiProvider;
    for (final p in _providers) {
      _models[p]!.text = services.settings.aiModel(p);
      _lists[p] = AiModelInfo.listFromJson(services.settings.aiModelListJson(p));
    }
    _load(services);
  }

  Future<void> _load(AppServices services) async {
    try {
      for (final p in _providers) {
        final key = await services.aiKeys.read(p);
        _keys[p]!.text = key ?? '';
        if (key != null) _stored.add(p);
      }
    } catch (e) {
      _error = tr('ai.keyError', {'error': '$e'});
    }
    if (!mounted) return;
    setState(() => _loading = false);
    for (final p in _providers) {
      _fetchModels(p);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _client.close();
    for (final c in [..._keys.values, ..._models.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Lists the models the key of [p] can use. Returns the failure, if any.
  Future<AiAdviceException?> _fetchModels(String p) async {
    final key = _keys[p]!.text.trim();
    if (key.isEmpty) return null;
    final seq = _fetchSeq[p] = (_fetchSeq[p] ?? 0) + 1;
    setState(() => _fetching[p] = true);
    AiAdviceException? failure;
    List<AiModelInfo>? list;
    try {
      list = await listModels(provider: AiProvider.byName(p), apiKey: key, client: _client);
    } on AiAdviceException catch (e) {
      failure = e;
    } catch (e) {
      failure = AiAdviceException('network', '$e');
    }
    // Closed, or a newer fetch is under way: leave the state to it.
    if (!mounted || _fetchSeq[p] != seq) return failure;
    // The key was edited while waiting: this answer is for the old one.
    if (_keys[p]!.text.trim() != key) {
      setState(() => _fetching[p] = false);
      return failure;
    }
    setState(() {
      _fetching[p] = false;
      _listError[p] = failure;
      if (list != null) {
        _lists[p] = list;
        _checkedKey[p] = key;
      }
    });
    if (list != null) {
      unawaited(context.read<AppServices>().settings.setAiModelListJson(p, AiModelInfo.listToJson(list)));
    }
    return failure;
  }

  /// Asks, then removes the saved key of [p] from the keychain at once
  /// (not on Save). The other service, if it has a key, becomes the default.
  Future<void> _deleteKey(String p) async {
    final name = tr('ai.provider.$p');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('ai.deleteConfirm.title')),
        content: SizedBox(width: 400, child: Text(tr('ai.deleteConfirm.body', {'provider': name, 'service': _serviceNames[p]}))),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('ai.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final services = context.read<AppServices>();
    _debounce?.cancel();
    try {
      await services.aiKeys.write(p, null);
      await services.settings.setAiModelListJson(p, '');
      final other = _providers.firstWhere((x) => x != p);
      if (services.settings.aiProvider == p && _stored.contains(other)) {
        await services.settings.setAiProvider(other);
      }
      if (!mounted) return;
      setState(() {
        _stored.remove(p);
        _keys[p]!.clear();
        _lists[p] = [];
        _checkedKey.remove(p);
        _listError[p] = null;
        _custom[p] = false;
        _error = null;
        _notice = tr('ai.deleted', {'provider': name});
        if (_stored.contains(other)) _provider = other;
      });
    } catch (e) {
      if (mounted) setState(() => _error = tr('ai.keyError', {'error': '$e'}));
    }
  }

  void _keyChanged(String p) {
    _debounce?.cancel();
    setState(() => _listError[p] = null);
    _debounce = Timer(const Duration(milliseconds: 900), () {
      if (mounted) _fetchModels(p);
    });
  }

  Future<void> _save() async {
    final services = context.read<AppServices>();
    _debounce?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // A key that has not listed its models yet is checked first; only a
      // key the service rejects stops the save (being offline does not).
      final key = _keys[_provider]!.text.trim();
      if (key.isNotEmpty && _checkedKey[_provider] != key) {
        final failure = await _fetchModels(_provider);
        if (!mounted) return;
        if (failure?.kind == 'auth') {
          setState(() => _busy = false);
          return;
        }
      }
      for (final p in _providers) {
        await services.aiKeys.write(p, _keys[p]!.text);
        // The default is not pinned, so a newer default applies later.
        final model = _models[p]!.text.trim();
        await services.settings.setAiModel(p, model == AppSettings.aiDefaultModels[p] ? '' : model);
      }
      await services.settings.setAiProvider(_provider);
      if (mounted) {
        Navigator.of(context).pop(_keys[_provider]!.text.trim().isNotEmpty);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('ai.keyError', {'error': '$e'});
        });
      }
    }
  }

  String _currentModel(String p) {
    final v = _models[p]!.text.trim();
    return v.isEmpty ? AppSettings.aiDefaultModels[p]! : v;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final enabled = !_loading && !_busy;
    final p = _provider;
    return AlertDialog(
      title: Text(tr('ai.dialogTitle')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.needKey) ...[
                Text(tr('ai.needKey'), style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
              ],
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'claude', label: Text(tr('ai.provider.claude'))),
                  ButtonSegment(value: 'openai', label: Text(tr('ai.provider.openai'))),
                ],
                selected: {p},
                showSelectedIcon: false,
                onSelectionChanged: enabled ? (s) => setState(() => _provider = s.first) : null,
              ),
              const SizedBox(height: 16),
              TextField(
                key: ValueKey('ai-key-$p'),
                controller: _keys[p],
                enabled: enabled,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => _keyChanged(p),
                decoration: InputDecoration(
                  labelText: tr('ai.key'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => launchUrl(Uri.parse(_keyPages[p]!)),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(tr('ai.getKey')),
                  ),
                  const Spacer(),
                  // Removes the saved key of this service from the keychain.
                  if (_stored.contains(p))
                    TextButton.icon(
                      onPressed: enabled ? () => _deleteKey(p) : null,
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(tr('ai.deleteKey')),
                    ),
                ],
              ),
              // No key: sign up for one, or use the file instead.
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 4, bottom: 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.help_outline, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(child: Text(tr('ai.noKey', {'service': _serviceNames[p]}), style: muted)),
                ]),
              ),
              Row(
                children: [
                  Expanded(child: _modelField(p, enabled)),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: tr('ai.models.refresh'),
                    onPressed: enabled && !_fetching[p]! && _keys[p]!.text.trim().isNotEmpty ? () => _fetchModels(p) : null,
                    icon: _fetching[p]! ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12, top: 6),
                child: _modelStatus(p, theme, muted),
              ),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.send_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(child: Text(tr('ai.privacy'), style: muted)),
              ]),
              const SizedBox(height: 12),
              // How the key is stored on this platform, and its limits.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(tr('ai.store.title'), style: theme.textTheme.labelLarge),
                    ]),
                    const SizedBox(height: 6),
                    for (final key in [Platform.isWindows ? 'ai.store.windows' : 'ai.store.macos', 'ai.store.never', 'ai.store.tip'])
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('•  ', style: muted),
                          Expanded(child: Text(tr(key), style: muted)),
                        ]),
                      ),
                  ],
                ),
              ),
              if (_notice != null && _error == null) ...[
                const SizedBox(height: 8),
                Text(_notice!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        // Opened by "Ask AI" without a key: back to its download and copy buttons.
        if (widget.needKey) TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(tr('ai.noKey.useFile'))),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: Text(tr('cancel'))),
        FilledButton(onPressed: enabled ? _save : null, child: Text(tr('ai.save'))),
      ],
    );
  }

  /// A menu of the models the key can use; a text field while there is no
  /// list or after "Custom…".
  Widget _modelField(String p, bool enabled) {
    final list = _lists[p]!;
    final current = _currentModel(p);
    if (_custom[p]! || list.isEmpty) {
      return TextField(
        key: ValueKey('ai-model-$p'),
        controller: _models[p],
        enabled: enabled,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: tr('ai.model'),
          hintText: AppSettings.aiDefaultModels[p],
          helperText: tr('ai.modelHelp.$p'),
          border: const OutlineInputBorder(),
          suffixIcon: list.isEmpty
              ? null
              : IconButton(
                  tooltip: tr('ai.models.useList'),
                  icon: const Icon(Icons.list),
                  onPressed: () => setState(() => _custom[p] = false),
                ),
        ),
      );
    }
    final listed = list.any((m) => m.id == current);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: tr('ai.model'),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey('ai-model-menu-$p'),
          value: current,
          isExpanded: true,
          menuMaxHeight: 420,
          onChanged: enabled
              ? (v) => setState(() {
                    if (v == _customItem) {
                      _custom[p] = true;
                    } else if (v != null) {
                      _models[p]!.text = v;
                    }
                  })
              : null,
          items: [
            if (!listed) DropdownMenuItem(value: current, child: Text(tr('ai.models.unlisted', {'model': current}), overflow: TextOverflow.ellipsis)),
            for (final m in list) DropdownMenuItem(value: m.id, child: Text(m.label, overflow: TextOverflow.ellipsis)),
            DropdownMenuItem(value: _customItem, child: Text(tr('ai.models.custom'))),
          ],
        ),
      ),
    );
  }

  Widget _modelStatus(String p, ThemeData theme, TextStyle? muted) {
    final failure = _listError[p];
    if (_fetching[p]!) return Text(tr('ai.models.loading'), style: muted);
    if (failure != null) {
      if (failure.kind == 'auth') return Text(tr('ai.keyInvalid'), style: TextStyle(color: theme.colorScheme.error, fontSize: muted?.fontSize));
      final reason = failure.kind == 'network' ? tr('advice.err.network') : (failure.detail.isEmpty ? failure.kind : failure.detail);
      return Text(tr('ai.models.failed', {'reason': reason}), style: muted);
    }
    if (_keys[p]!.text.trim().isEmpty) return Text(tr('ai.models.needKey'), style: muted);
    if (_lists[p]!.isNotEmpty && !_custom[p]!) return Text(tr('ai.models.count', {'n': _lists[p]!.length}), style: muted);
    return const SizedBox.shrink();
  }
}

/// The Settings card: which service is set up, and a button to change it.
class AiSettingsSummary extends StatefulWidget {
  const AiSettingsSummary({super.key});

  @override
  State<AiSettingsSummary> createState() => _AiSettingsSummaryState();
}

class _AiSettingsSummaryState extends State<AiSettingsSummary> {
  /// Services with a saved key; null while reading the keychain.
  Set<String>? _withKey;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final services = context.read<AppServices>();
    final found = <String>{};
    for (final p in const ['claude', 'openai']) {
      try {
        if (await services.aiKeys.read(p) != null) found.add(p);
      } catch (_) {}
    }
    if (mounted) setState(() => _withKey = found);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = context.watch<AppSettings>();
    final withKey = _withKey;
    final icon = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('ai.sectionHint'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (withKey == null) const Text('…'),
                  if (withKey != null && withKey.isEmpty)
                    Row(children: [
                      Icon(Icons.key_off_outlined, size: 18, color: icon),
                      const SizedBox(width: 8),
                      Expanded(child: Text(tr('ai.status.unset'))),
                    ]),
                  if (withKey != null)
                    for (final p in const ['claude', 'openai'])
                      if (withKey.contains(p))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(children: [
                            Icon(Icons.check_circle_outline, size: 18, color: icon),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                tr('ai.status.set', {'provider': tr('ai.provider.$p'), 'model': settings.aiModel(p)}) +
                                    (withKey.length > 1 && settings.aiProvider == p ? tr('ai.status.default') : ''),
                              ),
                            ),
                          ]),
                        ),
                  if (withKey != null && withKey.length > 1) Text(tr('ai.bothKeys'), style: theme.textTheme.bodySmall?.copyWith(color: icon)),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await showAiSettingsDialog(context);
                await _refresh();
              },
              icon: const Icon(Icons.key),
              label: Text(tr('ai.configure')),
            ),
          ],
        ),
      ],
    );
  }
}
