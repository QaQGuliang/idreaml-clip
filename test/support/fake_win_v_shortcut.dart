import 'dart:async';

import 'package:idreaml_clip/src/services/win_v_shortcut_service.dart';

class FakeWinVShortcut implements WinVShortcutService {
  @override
  bool isSupported = true;
  bool active = false;
  bool failStart = false;
  bool failStop = false;
  int starts = 0;
  int stops = 0;
  Completer<void>? startGate;
  void Function()? onPressed;
  void Function()? onFailure;

  @override
  Future<void> start(void Function() pressed, void Function() failed) async {
    starts++;
    if (startGate != null) await startGate!.future;
    if (failStart) throw StateError('Hook unavailable');
    active = true;
    onPressed = pressed;
    onFailure = failed;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('Hook could not stop');
    active = false;
  }
}
