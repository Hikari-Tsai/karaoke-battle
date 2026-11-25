import 'package:flutter/widgets.dart';

/// A text controller owned by the widget tree: made with the widget and
/// disposed with it. For dialogs, whose fields still build while the route
/// fades out after `showDialog` has returned, so a controller disposed by the
/// caller would be used after being disposed.
class WithTextController extends StatefulWidget {
  const WithTextController({super.key, this.text, required this.builder});
  final String? text;
  final Widget Function(BuildContext context, TextEditingController controller) builder;

  @override
  State<WithTextController> createState() => _WithTextControllerState();
}

class _WithTextControllerState extends State<WithTextController> {
  late final _c = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _c);
}
