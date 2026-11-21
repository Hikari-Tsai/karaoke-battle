// Records an action for the achievements (an export, the first preview…).
// Quietly does nothing where the app's services are not there (tests that
// build a screen on its own).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../state/app_services.dart';

void recordAchievementEvent(BuildContext context, String event) {
  try {
    unawaited(context.read<AppServices>().achievements.recordEvent(event));
  } catch (_) {}
}

/// Screens that the unlock celebration must not cover (singing, the score
/// reveal): unlocks wait until none is holding.
abstract final class AchievementHold {
  static final _owners = <Object>{};
  static final notifier = ValueNotifier<int>(0);

  static bool get active => _owners.isNotEmpty;

  static void add(Object owner) {
    if (_owners.add(owner)) notifier.value = _owners.length;
  }

  static void remove(Object owner) {
    if (_owners.remove(owner)) notifier.value = _owners.length;
  }
}
