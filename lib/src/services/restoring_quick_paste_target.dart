import 'quick_paste_service.dart';

/// Native operations are kept behind this interface so focus changes, held
/// modifiers and clipboard races can be exercised without injecting real input.
abstract class QuickPasteRestoration {
  bool get valid;
  bool get canActivate;
  bool get foreground;
  bool get focused;
  bool get keysReleased;
  int get clipboardSequence;
  void activate();
  Future<bool> restoreFocus();
  bool sendPaste();
}

class RestoringQuickPasteTarget implements QuickPasteTarget {
  RestoringQuickPasteTarget(this.restoration);
  final QuickPasteRestoration restoration;
  bool _used = false;

  @override
  Future<bool> paste({int? clipboardSequence}) async {
    if (_used) return false;
    _used = true;
    final target = restoration;
    bool unchanged() =>
        target.valid &&
        (clipboardSequence == null ||
            target.clipboardSequence == clipboardSequence);

    // AttachThreadInput resets keyboard state. Wait for the user's shortcut
    // and mouse button to be released BEFORE attaching input queues.
    for (var i = 0; !target.keysReleased && i < 40; i++) {
      if (!unchanged() || !target.canActivate) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!unchanged() || !target.canActivate || !target.keysReleased) {
      return false;
    }
    target.activate();
    for (var i = 0; !target.foreground && i < 40; i++) {
      if (!unchanged() || !target.canActivate) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!unchanged() || !target.foreground || !target.keysReleased) {
      return false;
    }
    if (!await target.restoreFocus()) return false;

    // AWT and XAML dispatch focus asynchronously. Give their editor a chance to
    // regain its caret/selection, checking that the user has not switched apps.
    var stable = 0;
    for (var i = 0; i < 40; i++) {
      if (!unchanged() || !target.foreground) return false;
      stable = target.focused && target.keysReleased ? stable + 1 : 0;
      if (stable == 3) return target.sendPaste();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }
}

/// Swing editors draw their own caret and often expose no UIA Edit element.
/// In that case let the focused AWT window route Ctrl+V to its focus owner.
bool isJavaPasteWindow(String windowClass, String focusClass) =>
    const {'SunAwtFrame', 'SunAwtDialog'}.contains(windowClass) &&
    const {
      'SunAwtFrame',
      'SunAwtDialog',
      'SunAwtCanvas',
      'SunAwtWindow',
    }.contains(focusClass);
