import 'package:flutter/services.dart';

/// Uses the desktop system's folder picker without changing stored preferences.
class DirectoryPicker {
  static const channel = MethodChannel('idreaml_clip/directories');

  static Future<String?> choose({String? initialDirectory}) =>
      channel.invokeMethod<String>('chooseDirectory', initialDirectory);
}
