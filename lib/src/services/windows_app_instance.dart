import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

// Must match scripts/windows-process-lifecycle.iss. Local scopes the guard to
// the Windows login session; installed and portable copies share one instance.
const windowsInstanceNamespace =
    r'Local\Idreaml.Clip.B2D7B7E4-6F2C-40AB-9A66-3F9E8A5C8A6E';

final _createMutex = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<
      IntPtr Function(Pointer<SECURITY_ATTRIBUTES>, Int32, Pointer<Utf16>),
      int Function(Pointer<SECURITY_ATTRIBUTES>, int, Pointer<Utf16>)
    >('CreateMutexW');

String windowsExecutableKey(String executable) {
  final normalized = path.windows.normalize(executable).toLowerCase();
  // Inno Setup's GetSHA256OfUnicodeString hashes UTF-16LE, without a BOM.
  return sha256.convert([
    for (final unit in normalized.codeUnits) ...[unit & 255, unit >> 8],
  ]).toString();
}

enum InstanceLaunch { primary, secondary, maintenance }

class WindowsAppInstance {
  WindowsAppInstance._(
    this.launch,
    this._handles,
    this._activation,
    this._shutdown,
  );

  final InstanceLaunch launch;
  final List<int> _handles;
  final int _activation;
  final int _shutdown;
  Timer? _poll;
  bool _activating = false;
  bool _closed = false;

  /// Called before opening SQLite, registering hotkeys or creating a tray icon.
  static WindowsAppInstance acquire({
    String namespace = windowsInstanceNamespace,
    String? executable,
  }) {
    final key = windowsExecutableKey(executable ?? Platform.resolvedExecutable);
    final handles = <int>[];
    try {
      bool maintenance() => using((arena) {
        final event = OpenEvent(
          SYNCHRONIZE,
          FALSE,
          '$namespace.Maintenance.$key'.toNativeUtf16(allocator: arena),
        );
        if (event == 0) {
          // An elevated installer can deny access. Do not start through it.
          return GetLastError() == ERROR_ACCESS_DENIED;
        }
        CloseHandle(event);
        return true;
      });
      if (maintenance()) {
        return WindowsAppInstance._(InstanceLaunch.maintenance, handles, 0, 0);
      }
      int event(String name) => using((arena) {
        final handle = CreateEvent(
          nullptr,
          FALSE,
          FALSE,
          name.toNativeUtf16(allocator: arena),
        );
        if (handle == 0) throw WindowsException(GetLastError());
        handles.add(handle);
        return handle;
      });
      // Create before claiming the mutex so a concurrent secondary can queue a
      // request even while the winner is still initializing Flutter/SQLite.
      final activation = event('$namespace.Activate');
      final (mutex, error) = using((arena) {
        final handle = _createMutex(
          nullptr,
          FALSE,
          '$namespace.Instance'.toNativeUtf16(allocator: arena),
        );
        return (handle, GetLastError());
      });
      if (mutex != 0) handles.add(mutex);
      if (error == ERROR_ALREADY_EXISTS || error == ERROR_ACCESS_DENIED) {
        SetEvent(activation);
        final result = WindowsAppInstance._(
          InstanceLaunch.secondary,
          handles,
          0,
          0,
        );
        result.dispose();
        return result;
      }
      if (mutex == 0) throw WindowsException(error);
      if (maintenance()) {
        final result = WindowsAppInstance._(
          InstanceLaunch.maintenance,
          handles,
          0,
          0,
        );
        result.dispose();
        return result;
      }
      final shutdown = event('$namespace.Shutdown.$key');
      return WindowsAppInstance._(
        InstanceLaunch.primary,
        handles,
        activation,
        shutdown,
      );
    } catch (_) {
      for (final handle in handles.reversed) {
        CloseHandle(handle);
      }
      rethrow;
    }
  }

  void listen({
    required Future<void> Function() onActivate,
    required Future<void> Function() onShutdown,
  }) {
    if (launch != InstanceLaunch.primary || _closed || _poll != null) return;
    _poll = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (WaitForSingleObject(_shutdown, 0) == WAIT_OBJECT_0) {
        stopListening();
        await onShutdown();
      } else if (!_activating &&
          WaitForSingleObject(_activation, 0) == WAIT_OBJECT_0) {
        _activating = true;
        try {
          await onActivate();
        } finally {
          _activating = false;
        }
      }
    });
  }

  /// Keep the instance mutex alive throughout shutdown, until the process exits.
  void stopListening() {
    _poll?.cancel();
    _poll = null;
  }

  /// For aborted startup and integration-test cleanup. Normal app exit leaves
  /// handles to Windows so another instance cannot start during final teardown.
  void dispose() {
    if (_closed) return;
    _closed = true;
    stopListening();
    for (final handle in _handles.reversed) {
      CloseHandle(handle);
    }
    _handles.clear();
  }
}
