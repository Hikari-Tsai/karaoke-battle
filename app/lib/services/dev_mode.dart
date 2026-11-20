// Developer features exist only in debug builds (flutter run): kDebugMode is
// a compile-time false in release builds, so everything behind it, the
// switch included, is compiled out of what users download. In a debug build
// the sidebar's 開發模式 switch turns them off to see the app as released.
import 'package:flutter/foundation.dart' show kDebugMode;

import 'settings.dart';

/// Developer features are shown: a debug build with 開發模式 on.
bool devFeatures(AppSettings settings) => kDebugMode && settings.devMode;
