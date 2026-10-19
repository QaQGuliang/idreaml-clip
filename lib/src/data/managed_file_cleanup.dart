import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Called only after the storage manager has verified ownership of a directory.
/// Git marks objects read-only on Windows; remove that flag on retired copies
/// before deleting them, without following links outside the managed tree.
Future<void> removeManagedEntity(FileSystemEntity entity) async {
  if (entity is Directory) {
    await for (final child in entity.list(followLinks: false)) {
      await removeManagedEntity(child);
    }
  } else if (entity is File && Platform.isWindows) {
    using((arena) {
      final name = entity.path.toNativeUtf16(allocator: arena);
      final attributes = win32.GetFileAttributes(name);
      if (attributes != 0xffffffff &&
          attributes & win32.FILE_ATTRIBUTE_READONLY != 0 &&
          win32.SetFileAttributes(
                name,
                attributes & ~win32.FILE_ATTRIBUTE_READONLY,
              ) ==
              0) {
        throw FileSystemException(
          '无法清理只读文件',
          entity.path,
          OSError('Windows 文件属性修改失败', win32.GetLastError()),
        );
      }
    });
  }
  await entity.delete();
}
