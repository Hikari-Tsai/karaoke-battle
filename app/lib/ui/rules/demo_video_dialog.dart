// The rules page's SSS demo videos (the website's, exported from the app),
// streamed from the website and played in a dialog.
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../state/i18n.dart';
import '../widgets/app_dialog.dart';
import '../widgets/achievement_events.dart';

Future<void> showDemoVideo(BuildContext context, {required String url, required String title}) =>
    showDialog<void>(context: context, builder: (_) => _DemoVideoDialog(url: url, title: title));

class _DemoVideoDialog extends StatefulWidget {
  const _DemoVideoDialog({required this.url, required this.title});
  final String url;
  final String title;

  @override
  State<_DemoVideoDialog> createState() => _DemoVideoDialogState();
}

class _DemoVideoDialogState extends State<_DemoVideoDialog> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    recordAchievementEvent(context, 'basics.demo');
    _player.stream.width.listen((w) {
      if (w != null && w > 0 && mounted && !_ready) setState(() => _ready = true);
    });
    _player.stream.error.listen((e) {
      if (mounted && !_ready) setState(() => _error = e);
    });
    _player.open(Media(widget.url));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // As large as fits, 16:9, leaving room for the title and margins.
    final width = [size.width * 0.82, (size.height - 200) * 16 / 9, 1280.0].reduce((a, b) => a < b ? a : b).clamp(320.0, 1280.0);
    final theme = Theme.of(context);
    return AppDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      content: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(fit: StackFit.expand, children: [
              Video(controller: _controller),
              if (!_ready)
                Center(
                  child: _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(tr('demo.videoFailed', {'error': _error!}), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                        )
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          const CircularProgressIndicator(color: Color(0xFFF9D84A)),
                          const SizedBox(height: 12),
                          Text(tr('demo.videoLoading'), style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70)),
                        ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
