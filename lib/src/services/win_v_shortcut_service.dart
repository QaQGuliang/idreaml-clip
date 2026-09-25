import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../models/win_v_key_state.dart';

abstract interface class WinVShortcutService {
  bool get isSupported;
  Future<void> start(void Function() onPressed, void Function() onFailure);
  Future<void> stop();
}

/// Uses the existing Win32 FFI dependency. The hook and its synchronous message
/// loop stay on one isolate thread; Flutter only receives activation messages.
class WindowsWinVShortcutService implements WinVShortcutService {
  _HookSession? _session;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<void> start(
    void Function() onPressed,
    void Function() onFailure,
  ) async {
    if (!isSupported) throw UnsupportedError('Win + V requires Windows');
    await stop();
    final session = _HookSession(onPressed, onFailure);
    _session = session;
    try {
      await session.start();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    await session.stop();
    if (identical(_session, session)) _session = null;
  }
}

const _stopHookMessage = WM_APP + 0x431;
const _menuMaskTag = 0x49444356;

class _HookSession {
  _HookSession(this.onPressed, this.onFailure);

  final void Function() onPressed;
  final void Function() onFailure;
  final _events = ReceivePort();
  final _ready = Completer<void>();
  final _stopped = Completer<void>();
  int? _thread;
  bool _stopping = false;
  bool _failed = false;

  Future<void> start() async {
    _events.listen((event) {
      if (event case ('thread', int thread)) {
        _thread = thread;
        if (_stopping) PostThreadMessage(thread, _stopHookMessage, 0, 0);
      } else if (event == 'ready') {
        if (!_ready.isCompleted) _ready.complete();
      } else if (event == 'pressed') {
        if (!_stopping && !_failed) onPressed();
      } else if (event == null) {
        // onExit is delivered after the worker's finally block has unhooked.
        _fail();
        _events.close();
        if (!_stopped.isCompleted) _stopped.complete();
      } else if (event is List || event == 'failed') {
        _fail();
      }
    });
    // Attach the error handler before spawning; startup errors can arrive before
    // Isolate.spawn completes. Never kill a worker with an installed callback.
    final ready = _ready.future.timeout(const Duration(seconds: 5));
    try {
      await Future.wait<void>([
        Isolate.spawn(
          _runKeyboardHook,
          _events.sendPort,
          onExit: _events.sendPort,
          onError: _events.sendPort,
          debugName: 'Win+V keyboard hook',
        ).then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            _fail(error, stack);
            _events.close();
            if (!_stopped.isCompleted) _stopped.complete();
          },
        ),
        ready,
      ]);
    } catch (_) {
      _stopping = true;
      if (_thread case final thread?) {
        PostThreadMessage(thread, _stopHookMessage, 0, 0);
      }
      rethrow;
    }
  }

  void _fail([Object? error, StackTrace? stack]) {
    if (_failed) return;
    _failed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(error ?? StateError('Keyboard hook failed'), stack);
    } else if (!_stopping) {
      onFailure();
    }
  }

  Future<void> stop() async {
    _stopping = true;
    if (!_stopped.isCompleted) {
      if (_thread case final thread?) {
        PostThreadMessage(thread, _stopHookMessage, 0, 0);
      }
    }
    await _stopped.future.timeout(const Duration(seconds: 3));
  }
}

void _runKeyboardHook(SendPort events) {
  final message = calloc<MSG>();
  final mask = calloc<INPUT>(2);
  NativeCallable<HOOKPROC>? callback;
  var hook = 0;
  try {
    // Create this thread's queue before publishing its ID for stop requests.
    PeekMessage(message, 0, 0, 0, PM_NOREMOVE);
    events.send(('thread', GetCurrentThreadId()));
    final keys = WinVKeyState(
      vAlreadyDown: GetAsyncKeyState(0x56) & 0x8000 != 0,
    );
    for (var i = 0; i < 2; i++) {
      mask[i].type = INPUT_KEYBOARD;
      mask[i].ki.wVk = 0xE8; // Unassigned VK: mark Win as used, without typing.
      mask[i].ki.dwFlags = i == 0 ? 0 : KEYEVENTF_KEYUP;
      mask[i].ki.dwExtraInfo = _menuMaskTag;
    }
    callback = NativeCallable<HOOKPROC>.isolateLocal((
      int code,
      int event,
      int address,
    ) {
      if (code < 0) return CallNextHookEx(0, code, event, address);
      final key = Pointer<KBDLLHOOKSTRUCT>.fromAddress(address).ref;
      if (key.dwExtraInfo == _menuMaskTag || key.vkCode != 0x56) {
        return CallNextHookEx(0, code, event, address);
      }
      final down = event == WM_KEYDOWN || event == WM_SYSKEYDOWN;
      final up = event == WM_KEYUP || event == WM_SYSKEYUP;
      if (!down && !up) return CallNextHookEx(0, code, event, address);
      bool pressed(int key) => GetAsyncKeyState(key) & 0x8000 != 0;
      // Only sample OTHER keys: the current V event has not yet updated the
      // asynchronous key state when Windows calls this hook.
      final action = keys.handle(
        isDown: down,
        windows: pressed(VK_LWIN) || pressed(VK_RWIN),
        control: pressed(VK_CONTROL),
        alt: pressed(VK_MENU),
        shift: pressed(VK_SHIFT),
      );
      if (action == WinVKeyAction.pass) {
        return CallNextHookEx(0, code, event, address);
      }
      if (action == WinVKeyAction.activate) {
        // Avoid the Start menu appearing when Win is released after swallowed V.
        SendInput(2, mask, sizeOf<INPUT>());
        events.send('pressed');
      }
      return 1;
    }, exceptionalReturn: 0);
    hook = SetWindowsHookEx(
      WH_KEYBOARD_LL,
      callback.nativeFunction,
      GetModuleHandle(nullptr),
      0,
    );
    if (hook == 0) throw StateError('Unable to install keyboard hook');
    events.send('ready');
    // No await or Dart event-loop yield here: isolateLocal callbacks must run
    // on the same OS thread on which they were created and installed.
    while (true) {
      final result = GetMessage(message, 0, 0, 0);
      if (result == -1) throw StateError('Keyboard message loop failed');
      if (result == 0 || message.ref.message == _stopHookMessage) break;
      TranslateMessage(message);
      DispatchMessage(message);
    }
  } catch (_) {
    events.send('failed');
  } finally {
    if (hook != 0) UnhookWindowsHookEx(hook);
    callback?.close();
    calloc.free(mask);
    calloc.free(message);
  }
}
