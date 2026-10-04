import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'startup_service.dart';
import 'windows_startup_service.dart';

/// Current-user registration only. Tests use an isolated HKCU subtree.
class WindowsRegistryStartupStore implements WindowsStartupStore {
  WindowsRegistryStartupStore({
    this.runKey = r'Software\Microsoft\Windows\CurrentVersion\Run',
    this.approvalKey = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
    this.preferenceKey = r'Software\Idreaml\Clip\Startup',
    this.folderApprovalKey = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
    this.valueName = 'Idreaml Clip',
  });

  final String runKey;
  final String approvalKey;
  final String preferenceKey;
  final String folderApprovalKey;
  final String valueName;

  void _check(int code) {
    if (code == ERROR_SUCCESS) return;
    throw StartupException(
      code == ERROR_ACCESS_DENIED
          ? 'Windows 拒绝访问开机启动设置，请检查当前账户权限或系统管理策略。'
          : '无法访问 Windows 开机启动设置（错误码 $code）。',
    );
  }

  T? _withKey<T>(String key, bool create, T Function(int) operation) =>
      using((arena) {
        final handle = arena<IntPtr>();
        final name = key.toNativeUtf16(allocator: arena);
        final code = create
            ? RegCreateKeyEx(
                HKEY_CURRENT_USER,
                name,
                0,
                nullptr,
                REG_OPTION_NON_VOLATILE,
                KEY_QUERY_VALUE | KEY_SET_VALUE,
                nullptr,
                handle,
                nullptr,
              )
            : RegOpenKeyEx(HKEY_CURRENT_USER, name, 0, KEY_QUERY_VALUE, handle);
        if (!create &&
            (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND)) {
          return null;
        }
        _check(code);
        try {
          return operation(handle.value);
        } finally {
          RegCloseKey(handle.value);
        }
      });

  Object? _readValue(
    String key,
    String name,
    int expectedType,
  ) => _withKey<Object?>(
    key,
    false,
    (handle) => using<Object?>((arena) {
      final valueName = name.toNativeUtf16(allocator: arena);
      final type = arena<Uint32>();
      final length = arena<Uint32>();
      var code = RegQueryValueEx(
        handle,
        valueName,
        nullptr,
        type,
        nullptr,
        length,
      );
      if (code == ERROR_FILE_NOT_FOUND) return null;
      _check(code);
      // Bound memory allocation and retry if another startup manager races us.
      for (var attempt = 0; attempt < 3; attempt++) {
        if (length.value > 65536) throw const StartupException('开机启动记录格式异常。');
        final capacity = length.value;
        final bytes = arena<Uint8>(capacity + 2);
        code = RegQueryValueEx(handle, valueName, nullptr, type, bytes, length);
        if (code == ERROR_FILE_NOT_FOUND) return null;
        if (code == ERROR_MORE_DATA) continue;
        _check(code);
        if (type.value != expectedType ||
            (expectedType == REG_SZ && length.value.isOdd)) {
          throw const StartupException('开机启动记录类型异常，无法确认原设置。');
        }
        if (expectedType == REG_BINARY) {
          return List<int>.from(bytes.asTypedList(length.value));
        }
        final units = List<int>.from(
          bytes.cast<Uint16>().asTypedList(length.value ~/ 2),
        );
        while (units.isNotEmpty && units.last == 0) {
          units.removeLast();
        }
        return String.fromCharCodes(units);
      }
      throw const StartupException('开机启动记录正在被其他程序修改，请稍后重试。');
    }),
  );

  void _writeValue(String key, String name, Object? value) {
    if (value == null) {
      // Avoid creating empty keys when removing an absent value.
      using((arena) {
        final handle = arena<IntPtr>();
        final code = RegOpenKeyEx(
          HKEY_CURRENT_USER,
          key.toNativeUtf16(allocator: arena),
          0,
          KEY_SET_VALUE,
          handle,
        );
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) {
          return;
        }
        _check(code);
        try {
          final result = RegDeleteValue(
            handle.value,
            name.toNativeUtf16(allocator: arena),
          );
          if (result != ERROR_FILE_NOT_FOUND) _check(result);
        } finally {
          RegCloseKey(handle.value);
        }
      });
      return;
    }
    _withKey(
      key,
      true,
      (handle) => using((arena) {
        final List<int> data = value is String
            ? [
                for (final unit in value.codeUnits) ...[unit & 255, unit >> 8],
                0,
                0,
              ]
            : value as List<int>;
        final bytes = arena<Uint8>(data.length + 1)
          ..asTypedList(data.length).setAll(0, data);
        _check(
          RegSetValueEx(
            handle,
            name.toNativeUtf16(allocator: arena),
            0,
            value is String ? REG_SZ : REG_BINARY,
            bytes,
            data.length,
          ),
        );
      }),
    );
  }

  @override
  WindowsStartupRegistration read() => WindowsStartupRegistration(
    command: _readValue(runKey, valueName, REG_SZ) as String?,
    approval: _readValue(approvalKey, valueName, REG_BINARY) as List<int>?,
    owner: _readValue(preferenceKey, 'Executable', REG_SZ) as String?,
    folderApproval: _readValue(
      folderApprovalKey,
      '$valueName.lnk',
      REG_BINARY,
    ) as List<int>?,
  );

  @override
  void write(WindowsStartupRegistration value) {
    final previous = read();
    if (value.command != previous.command) {
      _writeValue(runKey, valueName, value.command);
    }
    if (value.approval?.join(',') != previous.approval?.join(',')) {
      _writeValue(approvalKey, valueName, value.approval);
    }
    if (value.owner != previous.owner) {
      _writeValue(preferenceKey, 'Executable', value.owner);
    }
    if (value.folderApproval?.join(',') != previous.folderApproval?.join(',')) {
      _writeValue(folderApprovalKey, '$valueName.lnk', value.folderApproval);
    }
  }
}
