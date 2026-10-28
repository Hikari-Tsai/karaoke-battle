// Root widget: theme, bootstrap, providers, error page.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'services/backend_manager.dart';
import 'services/prep_pipeline.dart';
import 'services/settings.dart';
import 'services/song_library.dart';
import 'state/app_services.dart';
import 'state/i18n.dart';
import 'state/setup_controller.dart';
import 'ui/shell.dart';

class KaraokeApp extends StatefulWidget {
  const KaraokeApp({super.key});

  @override
  State<KaraokeApp> createState() => _KaraokeAppState();
}

class _KaraokeAppState extends State<KaraokeApp> {
  late Future<AppServices> _bootstrap;

  @override
  void initState() {
    super.initState();
    _bootstrap = bootstrapServices();
  }

  void _retry() => setState(() => _bootstrap = bootstrapServices());

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: I18n.notifier,
      builder: (context, lang, child) => MaterialApp(
        title: tr('app.title'),
        debugShowCheckedModeBanner: false,
        // Material/Cupertino widget strings follow the UI language too.
        locale: switch (lang) { 'en' => const Locale('en'), 'ja' => const Locale('ja'), _ => const Locale('zh', 'TW') },
        supportedLocales: const [Locale('zh', 'TW'), Locale('en'), Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: ThemeMode.dark,
        home: FutureBuilder<AppServices>(
          future: _bootstrap,
          builder: (context, snap) {
            if (snap.hasError) return StartupErrorPage(error: snap.error!, onRetry: _retry);
            final s = snap.data;
            if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            return MultiProvider(
              providers: [
                Provider<AppServices>.value(value: s),
                ChangeNotifierProvider<AppSettings>.value(value: s.settings),
                ChangeNotifierProvider<BackendManager>.value(value: s.backend),
                ChangeNotifierProvider<SongLibrary>.value(value: s.library),
                ChangeNotifierProvider<PrepPipeline>.value(value: s.pipeline),
                ChangeNotifierProvider<SetupController>(create: (_) => SetupController(s.models, s.sidecars)),
              ],
              // Keyed on the language so every screen (including const subtrees) is rebuilt.
              child: AppShell(key: ValueKey('shell-$lang')),
            );
          },
        ),
      ),
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorSchemeSeed: const Color(0xFF7C5CFF),
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    cardTheme: base.cardTheme.copyWith(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    sliderTheme: base.sliderTheme.copyWith(trackHeight: 3),
  );
}

class StartupErrorPage extends StatelessWidget {
  const StartupErrorPage({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = error;
    final isEngine = e is EngineLoadError;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.error_outline, color: theme.colorScheme.error, size: 32),
                    const SizedBox(width: 12),
                    Text(isEngine ? tr('engine.loadFailed') : tr('startup.failed'), style: theme.textTheme.headlineSmall),
                  ]),
                  const SizedBox(height: 16),
                  if (isEngine) ...[
                    Text(tr('engine.triedPath'), style: theme.textTheme.labelLarge),
                    SelectableText(e.path, style: const TextStyle(fontFamily: 'monospace')),
                    const SizedBox(height: 12),
                    Text(tr('engine.hint')),
                    const SizedBox(height: 12),
                    SelectableText('${e.cause}', style: theme.textTheme.bodySmall),
                  ] else
                    SelectableText('$e'),
                  const SizedBox(height: 20),
                  Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: Text(tr('retry')))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
