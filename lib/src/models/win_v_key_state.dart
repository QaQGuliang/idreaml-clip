enum WinVKeyAction { pass, suppress, activate }

/// Tracks only the V press, never stores typed text. Modifier state is sampled
/// by the native hook when V arrives, so a desktop switch cannot leave Win stuck.
class WinVKeyState {
  WinVKeyState({bool vAlreadyDown = false}) : _vDown = vAlreadyDown;

  bool _vDown;
  bool _captured = false;

  WinVKeyAction handle({
    required bool isDown,
    required bool windows,
    required bool control,
    required bool alt,
    required bool shift,
  }) {
    if (!isDown) {
      final consumed = _captured;
      _vDown = false;
      _captured = false;
      return consumed ? WinVKeyAction.suppress : WinVKeyAction.pass;
    }
    if (_vDown) {
      return _captured ? WinVKeyAction.suppress : WinVKeyAction.pass;
    }
    _vDown = true;
    _captured = windows && !control && !alt && !shift;
    return _captured ? WinVKeyAction.activate : WinVKeyAction.pass;
  }
}
