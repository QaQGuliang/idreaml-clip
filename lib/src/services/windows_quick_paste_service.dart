import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

import 'quick_paste_service.dart';
import 'restoring_quick_paste_target.dart';
import 'windows_automation_focus.dart';

class WindowsQuickPasteService implements QuickPasteService {
  WindowsQuickPasteService({this.onDiagnostic})
    : _capture = _captureNativeTarget;

  @visibleForTesting
  WindowsQuickPasteService.withCapture(this._capture, {this.onDiagnostic});

  final WindowsPasteCapture? Function(void Function(String)? trace) _capture;
  final _automationCapture = _NativePasteOperation();

  /// Optional developer diagnostics: window metadata and outcomes only, never
  /// clipboard contents or the text of the destination editor.
  final void Function(String)? onDiagnostic;

  @override
  Future<QuickPasteTarget?> captureTarget() async {
    // Capture HWNDs synchronously, before any await can change the foreground.
    final native = _capture(onDiagnostic);
    if (native == null) return null;
    // Desktop/taskbar surfaces are not application input targets. Explorer
    // remains edit-only so choosing text cannot trigger a folder paste action.
    if (const {
      'Progman',
      'WorkerW',
      'Shell_TrayWnd',
      'Shell_SecondaryTrayWnd',
    }.contains(native.windowClass)) {
      return null;
    }
    final explorer =
        native.windowClass == 'CabinetWClass' ||
        native.windowClass == 'ExploreWClass';
    WindowsAutomationCapture? automation;
    if (explorer) {
      try {
        automation = await _automationCapture.run(
          native.captureAutomation,
          const Duration(milliseconds: 650),
          const WindowsAutomationCapture(false, null),
        );
      } catch (_) {
        automation = null;
      }
    }
    if (!native.foreground) return null;
    if (explorer && automation?.editable != true) {
      onDiagnostic?.call('capture rejected: no Explorer editor');
      return null;
    }
    // Custom editors (Qt, Chromium, AWT, etc.) may draw their own caret and
    // expose no UIA Edit/Value pattern. Retain their keyboard focus owner and
    // let the app route Ctrl+V, just as it routes the user's manual shortcut.
    onDiagnostic?.call(
      'capture accepted: ${explorer ? 'Explorer editor' : 'application focus'}',
    );
    return RestoringQuickPasteTarget(
      native.restoration(automation?.focus, onDiagnostic),
    );
  }
}

/// A timeout releases the caller, but an external UIA provider or window can
/// still be blocking its worker. Only start another once that worker returns.
class _NativePasteOperation {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() action, Duration timeout, T fallback) {
    if (_running) return Future.value(fallback);
    _running = true;
    Future<T> perform() async {
      try {
        return await action();
      } finally {
        _running = false;
      }
    }

    return perform().timeout(timeout, onTimeout: () => fallback);
  }
}

/// Capture and restoration are separate: the panel takes focus between them.
/// This boundary also lets regression tests exercise capture without sending
/// keyboard input to applications on the user's desktop.
abstract class WindowsPasteCapture {
  String get windowClass;
  bool get foreground;
  Future<WindowsAutomationCapture> captureAutomation();
  QuickPasteRestoration restoration(
    WindowsAutomationFocus? automation,
    void Function(String)? trace,
  );
}

class _NativeTarget implements WindowsPasteCapture {
  const _NativeTarget(
    this.window,
    this.focus,
    this.processId,
    this.focusProcessId,
    this.focusThread,
    this.windowClass,
    this.focusClass,
    this.selection,
  );
  final int window, focus, processId, focusProcessId, focusThread;
  @override
  final String windowClass;
  final String focusClass;
  final (int, int)? selection;

  @override
  bool get foreground => GetForegroundWindow() == window;

  bool get originalFocusValid => using((arena) {
    if (IsWindow(focus) == 0 ||
        (focus != window && IsChild(window, focus) == 0)) {
      return false;
    }
    final pid = arena<Uint32>();
    final thread = GetWindowThreadProcessId(focus, pid);
    return thread == focusThread &&
        pid.value == focusProcessId &&
        _windowClass(focus) == focusClass;
  });

  @override
  Future<WindowsAutomationCapture> captureAutomation() {
    final hwnd = window;
    final pid = processId;
    return Isolate.run(
      () => captureAutomationFocus(hwnd, pid, retainSelection: true),
    );
  }

  @override
  QuickPasteRestoration restoration(
    WindowsAutomationFocus? automation,
    void Function(String)? trace,
  ) => _WindowsPasteRestoration(this, automation, trace);
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
        'focus=${info.ref.hwndFocus} class=${_windowClass(info.ref.hwndFocus)} '
        'nativeCaret=${info.ref.hwndCaret != 0}',
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
      // Hosted HWNDs (including embedded WebViews) can belong to a different
      // process. Pin the identity of both the host and its focused descendant.
      if (focusThread == 0 ||
          focusPid.value == 0 ||
          focusPid.value == GetCurrentProcessId()) {
        return null;
      }
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
        focusPid.value,
        focusThread,
        _windowClass(window),
        focusClass,
        selection,
      );
    });

String _windowClass(int window) => using((arena) {
  final buffer = arena<Uint16>(256).cast<Utf16>();
  final length = GetClassName(window, buffer, 256);
  return length > 0 ? buffer.toDartString(length: length) : '';
});

bool _isNativeEdit(String name) => const {
  'edit',
  'richedit',
  'richedit20a',
  'richedit20w',
  'richedit50w',
  'richeditd2d',
  'richeditd2dpt',
}.contains(name.toLowerCase());

/// Called with the verified focus owner after selection restoration. Null lets
/// the app handle a non-native editor or non-text format through its shortcut.
/// After dispatch, even a timeout must never fall through to a second paste.
bool? pasteTextIntoWindowsEdit(int hwnd) {
  if (!_isNativeEdit(_windowClass(hwnd)) ||
      IsClipboardFormatAvailable(CF_UNICODETEXT) == 0) {
    return null;
  }
  if (IsWindowEnabled(hwnd) == 0 ||
      GetWindowLongPtr(hwnd, GWL_STYLE) & ES_READONLY != 0) {
    return false;
  }
  return using(
    (arena) =>
        SendMessageTimeout(
          hwnd,
          WM_PASTE,
          0,
          0,
          SMTO_ABORTIFHUNG | SMTO_BLOCK,
          100,
          arena<IntPtr>(),
        ) !=
        0,
  );
}

class _WindowsPasteRestoration implements QuickPasteRestoration {
  _WindowsPasteRestoration(this.target, this.automation, this.trace);
  final _NativeTarget target;
  final WindowsAutomationFocus? automation;
  final void Function(String)? trace;
  int _restoredFocus = 0;
  static final _focusOperation = _NativePasteOperation();

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
    return automation != null || target.originalFocusValid;
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
    final native = target;
    final deadline = DateTime.now().millisecondsSinceEpoch + 1000;
    const timeout = Duration(milliseconds: 1100);
    if (saved != null) {
      final restored = await _focusOperation.run(
        () => Isolate.run(
          () => restoreAutomationFocus(
            native.window,
            native.processId,
            saved,
            deadline,
          ),
        ),
        timeout,
        false,
      );
      if (!restored || !valid || !foreground) return false;
      _restoredFocus = _focusedWindow;
      return _restoredFocus == target.window ||
          IsChild(target.window, _restoredFocus) != 0;
    }
    if (_focusedWindow != target.focus) {
      final restored = await _focusOperation.run(
        () => Isolate.run(() => _focusNativeChild(native, deadline)),
        timeout,
        false,
      );
      if (!restored || !valid || !keysReleased) return false;
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
    final delivered = pasteTextIntoWindowsEdit(_restoredFocus);
    if (delivered != null) return delivered;
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

bool _focusNativeChild(_NativeTarget target, int deadline) => using((arena) {
  // AttachThreadInput requires a message queue on both threads. A fresh Dart
  // worker may not have one yet. SetFocus can wait on a hung target thread.
  PeekMessage(arena<MSG>(), 0, 0, 0, PM_NOREMOVE);
  final thread = GetCurrentThreadId();
  final attached = thread != target.focusThread;
  if (attached && AttachThreadInput(thread, target.focusThread, TRUE) == 0) {
    return false;
  }
  try {
    final pid = arena<Uint32>();
    GetWindowThreadProcessId(target.window, pid);
    if (DateTime.now().millisecondsSinceEpoch >= deadline ||
        !target.foreground ||
        pid.value != target.processId ||
        !target.originalFocusValid) {
      return false;
    }
    SetFocus(target.focus);
    return GetFocus() == target.focus;
  } finally {
    if (attached) AttachThreadInput(thread, target.focusThread, FALSE);
  }
});

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
