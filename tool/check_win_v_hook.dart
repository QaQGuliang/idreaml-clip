import 'dart:io';

import 'package:idreaml_clip/src/services/win_v_shortcut_service.dart';

// Run with `dart run tool/check_win_v_hook.dart` on Windows. Installs the real
// hook briefly without sending any keys or modifying the user's saved settings.
Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Skipped: Windows only');
    return;
  }
  final service = WindowsWinVShortcutService();
  var failures = 0;
  try {
    for (var i = 0; i < 3; i++) {
      await service.start(() {}, () => failures++);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await service.stop();
    }
    await service.stop(); // Stopping an already stopped session is harmless.
    if (failures != 0) throw StateError('Unexpected hook failures: $failures');
    stdout.writeln('PASS: native hook installed and released for 3 cycles');
  } finally {
    await service.stop();
  }
}
