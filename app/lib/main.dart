import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'native_licenses.dart';
import 'services/app_log.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.hookErrors();
  MediaKit.ensureInitialized();
  registerNativeLicenses();
  runApp(const KaraokeApp());
}
