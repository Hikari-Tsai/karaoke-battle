// 直播模式: while a streaming app (OBS, Streamlabs, XSplit, …) is running,
// what the screen shows may be on stream, so private details are masked:
// file paths (the home folder and the account / computer name in them)
// and the 觀眾加油 alert URLs' IDs. [StreamPrivacy.live] is set by
// StreamingWatch (services/streaming_apps.dart); tr() masks its arguments
// with [StreamPrivacy.mask], and PrivateText masks what it shows.
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class StreamPrivacy {
  /// A streaming app is running: mask private details.
  static final live = ValueNotifier<bool>(false);

  /// 開發模式: act as if one were (see StreamingWatch).
  static final simulate = ValueNotifier<bool>(false);

  /// [s] as it may be shown: unchanged unless [live].
  static String mask(String s) => live.value ? maskPrivate(s) : s;
}

/// The details of this computer masked in [s] (whatever the mode).
String maskPrivate(String s, {String? home, String? user, String? host}) {
  home ??= Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  user ??= Platform.environment['USER'] ?? Platform.environment['USERNAME'];
  try {
    host ??= Platform.localHostname;
  } catch (_) {}
  var out = s;
  // The home folder first, so what is under it still reads as a path.
  if (home != null && home.length > 2) {
    out = out.replaceAll(RegExp(RegExp.escape(home), caseSensitive: !Platform.isWindows), Platform.isWindows ? '%USERPROFILE%' : '~');
  }
  // The longer name first (a computer name often holds the account name).
  final names = [?user, ?host?.replaceFirst(RegExp(r'\.local$'), '')]..sort((a, b) => b.length - a.length);
  for (final name in names) {
    if (name.length >= 3) {
      out = out.replaceAll(RegExp(RegExp.escape(name), caseSensitive: false), '•••');
    }
  }
  // 觀眾加油: an alert URL's ID lets anyone follow the donations.
  out = out.replaceAllMapped(RegExp(r'(Broadcaster/(?:AlertBox|Donate)/)[0-9A-Fa-f]{32}'), (m) => '${m[1]}••••••••');
  return out;
}
