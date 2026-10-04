import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'quick_paste_service.dart';
import 'restoring_quick_paste_target.dart';
import 'windows_automation_focus.dart';

class WindowsQuickPasteService implements QuickPasteService {
  WindowsQuickPasteService({this.onDiagnostic});

  /// Optional developer diagnostics: window metadata and outcomes only, never
  /// clipboard contents or the text of the destination editor.
  final void Function(String)? onDiagnostic;

  @override
  Future<QuickPasteTarget?> captureTarget() async {
    // Capture HWNDs synchronously, before any await can change the foreground.
    final native = _captureNativeTarget(onDiagnostic);
    if (native == null) return null;
    final java = isJavaPasteWindow(native.windowClass, native.focusClass);
    onDiagnostic?.call('capture java=$java nativeCaret=${native.nativeCaret}');
    WindowsAutomationCapture? automation;
    if (native.explorer || (!native.nativeCaret && !java)) {
      try {
        automation =
            await Isolate.run(
              () => captureAutomationFocus(
                native.window,
                native.processId,
                retainSelection: native.explorer,
              ),
            ).timeout(
              const Duration(milliseconds: 650),
              onTimeout: () => const WindowsAutomationCapture(false, null),
            );
      } catch (_) {
        automation = null;
      }
    }
    if (GetForegroundWindow() != native.window) return null;
    if (!native.nativeCaret && !java && automation?.editable != true) {
      onDiagnostic?.call('capture rejected: no editable target');
      return null;
    }
    return RestoringQuickPasteTarget(
      _WindowsPasteRestoration(native, automation?.focus, onDiagnostic),
    );
  }
}

class _NativeTarget {
  const _NativeTarget(
    this.window,
    this.focus,
    this.processId,
    this.focusThread,
    this.windowClass,
    this.focusClass,
    this.nativeCaret,
    this.selection,
  );
  final int window, focus, processId, focusThread;
  final String windowClass, focusClass;
  final bool nativeCaret;
  final (int, int)? selection;
  bool get explorer =>
      windowClass == 'CabinetWClass' || windowClass == 'ExploreWClass';
}

_NativeTarget? _captureNativeTarget(void Function(String)? trace) =>
    using((arena) {
      final window = GetForegroundWindow();
      if (window == 0) return null;
      final pid = arena<Uint32>();
      final thread = GetWindowThreadProcessId(window, pid);
      if (pid.value == GetCurrentProcessId() || pid.value == 0) return null;
      final info = arena<GUITHREADINFO>()..ref.cbSize = sizeOf<GUITHREADINFO>();
      final guiFound = GetGUIThreadInfo(thread, info);
      trace?.call(
        'capture window=$window class=${_windowClass(window)} '
        'pid=${pid.value} thread=$thread gui=$guiFound flags=${info.ref.flags} '
        'focus=${info.ref.hwndFocus} class=${_windowClass(info.ref.hwndFocus)}',
      );
      if (guiFound == 0 ||
          info.ref.hwndFocus == 0 ||
          info.ref.flags &
                  (GUI_INMENUMODE | GUI_POPUPMENUMODE | GUI_SYSTEMMENUMODE) !=
              0) {
        return null;
      }
      final focus = info.ref.hwndFocus;
      if (focus != window && IsChild(window, focus) == 0) return null;
      final focusPid = arena<Uint32>();
      final focusThread = GetWindowThreadProcessId(focus, focusPid);
      if (focusPid.value != pid.value) return null;
      final focusClass = _windowClass(focus);
      (int, int)? selection;
      if (_isNativeEdit(focusClass)) {
        final start = arena<Uint32>();
        final end = arena<Uint32>();
        final result = arena<IntPtr>();
        if (SendMessageTimeout(
              focus,
              EM_GETSEL,
              start.address,
              end.address,
              SMTO_ABORTIFHUNG | SMTO_BLOCK,
              80,
              result,
            ) !=
            0) {
          selection = (start.value, end.value);
        }
      }
      return _NativeTarget(
        window,
        focus,
        pid.value,
        focusThread,
        _windowClass(window),
        focusClass,
        info.ref.hwndCaret != 0,
        selection,
      );
    });

String _windowClass(int window) => using((arena) {
  final buffer = arena<Uint16>(256).cast<Utf16>();
  final length = GetClassName(window, buffer, 256);
  return length > 0 ? buffer.toDartString(length: length) : '';
});

bool _isNativeEdit(String name) =>
    name.toLowerCase() == 'edit' || name.toLowerCase().startsWith('richedit');

class _WindowsPasteRestoration implements QuickPasteRestoration {
  _WindowsPasteRestoration(this.target, this.automation, this.trace);
  final _NativeTarget target;
  final WindowsAutomationFocus? automation;
  final void Function(String)? trace;
  int _restoredFocus = 0;

  @override
  bool get valid => using((arena) {
    if (IsWindow(target.window) == 0) return false;
    final pid = arena<Uint32>();
    GetWindowThreadProcessId(target.window, pid);
    if (pid.value != target.processId ||
        pid.value == GetCurrentProcessId() ||
        _windowClass(target.window) != target.windowClass) {
      return false;
    }
    // XAML can recreate its input host when the Explorer address bar collapses.
    return automation != null || _originalFocusValid;
  });

  bool get _originalFocusValid => using((arena) {
    if (IsWindow(target.focus) == 0 ||
        (target.focus != target.window &&
            IsChild(target.window, target.focus) == 0)) {
      return false;
    }
    final pid = arena<Uint32>();
    final thread = GetWindowThreadProcessId(target.focus, pid);
    return thread == target.focusThread &&
        pid.value == target.processId &&
        _windowClass(target.focus) == target.focusClass;
  });

  @override
  bool get canActivate => using((arena) {
    final current = GetForegroundWindow();
    if (current == 0 || current == target.window) return true;
    final pid = arena<Uint32>();
    GetWindowThreadProcessId(current, pid);
    return pid.value == GetCurrentProcessId();
  });

  @override
  bool get foreground => GetForegroundWindow() == target.window;

  int get _focusedWindow => using((arena) {
    final info = arena<GUITHREADINFO>()..ref.cbSize = sizeOf<GUITHREADINFO>();
    return GetGUIThreadInfo(0, info) != 0 ? info.ref.hwndFocus : 0;
  });

  @override
  bool get focused =>
      foreground &&
      _restoredFocus != 0 &&
      IsWindow(_restoredFocus) != 0 &&
      _focusedWindow == _restoredFocus;

  @override
  bool get keysReleased => const [
    VK_CONTROL,
    VK_SHIFT,
    VK_MENU,
    VK_LWIN,
    VK_RWIN,
    VK_RETURN,
    VK_LBUTTON,
  ].every((key) => GetAsyncKeyState(key) & 0x8000 == 0);

  @override
  int get clipboardSequence => GetClipboardSequenceNumber();

  @override
  void activate() {
    if (valid && canActivate) {
      final result = SetForegroundWindow(target.window);
      trace?.call(
        'activate result=$result foreground=${GetForegroundWindow()} '
        'focused=$_focusedWindow target=${target.window}/${target.focus}',
      );
    }
  }

  @override
  Future<bool> restoreFocus() async {
    if (!valid || !foreground || !keysReleased) return false;
    final saved = automation;
    if (saved != null) {
      final window = target.window;
      final processId = target.processId;
      final deadline = DateTime.now().millisecondsSinceEpoch + 1000;
      final restored = await Isolate.run(
        () => restoreAutomationFocus(window, processId, saved, deadline),
      ).timeout(const Duration(milliseconds: 1100), onTimeout: () => false);
      if (!restored || !valid || !foreground) return false;
      _restoredFocus = _focusedWindow;
      return _restoredFocus == target.window ||
          IsChild(target.window, _restoredFocus) != 0;
    }
    if (!_originalFocusValid) return false;
    if (_focusedWindow != target.focus) {
      final ownThread = GetCurrentThreadId();
      final attached = ownThread != target.focusThread;
      if (attached &&
          AttachThreadInput(ownThread, target.focusThread, TRUE) == 0) {
        return false;
      }
      try {
        if (!foreground || !_originalFocusValid) return false;
        SetFocus(target.focus);
      } finally {
        if (attached) AttachThreadInput(ownThread, target.focusThread, FALSE);
      }
    }
    if (!foreground || _focusedWindow != target.focus) return false;
    final selection = target.selection;
    if (selection != null) {
      final restored = using(
        (arena) =>
            SendMessageTimeout(
              target.focus,
              EM_SETSEL,
              selection.$1,
              selection.$2,
              SMTO_ABORTIFHUNG | SMTO_BLOCK,
              80,
              arena<IntPtr>(),
            ) !=
            0,
      );
      if (!restored) return false;
    }
    _restoredFocus = target.focus;
    return true;
  }

  @override
  bool sendPaste() {
    if (!valid || !focused || !keysReleased) return false;
    return using((arena) {
      final inputs = arena<INPUT>(4);
      for (var i = 0; i < 4; i++) {
        inputs[i].type = INPUT_KEYBOARD;
        inputs[i].ki.wVk = i == 0 || i == 3 ? VK_CONTROL : 0x56;
        inputs[i].ki.dwFlags = i >= 2 ? KEYEVENTF_KEYUP : 0;
      }
      final sent = SendInput(4, inputs, sizeOf<INPUT>());
      trace?.call(
        'paste sent=$sent error=${GetLastError()} '
        'foreground=${GetForegroundWindow()} focused=$_focusedWindow',
      );
      if (sent > 0 && sent < 4) {
        // Release only keys introduced by this incomplete synthetic chord.
        final release = arena<INPUT>(2);
        release[0].type = INPUT_KEYBOARD;
        release[0].ki.wVk = VK_CONTROL;
        release[0].ki.dwFlags = KEYEVENTF_KEYUP;
        release[1].type = INPUT_KEYBOARD;
        release[1].ki.wVk = 0x56;
        release[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(sent == 2 ? 2 : 1, release, sizeOf<INPUT>());
      }
      return sent == 4;
    });
  }
}

int _wakeOwnWindow(int hwnd, int unused) {
  return using((arena) {
    final pid = arena<Uint32>();
    GetWindowThreadProcessId(hwnd, pid);
    if (pid.value == GetCurrentProcessId()) PostMessage(hwnd, WM_NULL, 0, 0);
    return 1;
  });
}

void finishWindowsTrayMenu() {
  // TrackPopupMenu requires a benign posted message after dismissal so the
  // next tray menu does not immediately disappear (Microsoft's documented fix).
  EnumWindows(Pointer.fromFunction<WNDENUMPROC>(_wakeOwnWindow, 0), 0);
}
