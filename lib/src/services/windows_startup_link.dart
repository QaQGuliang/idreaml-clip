import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';

import 'startup_service.dart';

class StartupLink {
  const StartupLink(
    this.bytes,
    this.target,
    this.arguments,
    this.workingDirectory,
  );
  final List<int> bytes;
  final String target;
  final String arguments;
  final String workingDirectory;
}

abstract interface class WindowsStartupLinkStore {
  StartupLink? read();
  void save(String executable);
  void restore(List<int>? bytes);
}

/// Uses the user's actual shell folder, including redirected profile folders.
/// Tests inject a temporary directory, never the real Startup directory.
class WindowsStartupLinkFile implements WindowsStartupLinkStore {
  WindowsStartupLinkFile({this.directory});
  final String? directory;

  String get filename =>
      path.windows.join(directory ?? _startupDirectory(), 'Idreaml Clip.lnk');

  void _check(int result) {
    if (FAILED(result)) {
      throw StartupException(
        '无法访问 Windows 启动快捷方式（错误码 ${result.toUnsigned(32).toRadixString(16)}）。',
      );
    }
  }

  String _startupDirectory() => using((arena) {
    final id = GUIDFromString(FOLDERID_Startup, allocator: arena);
    final out = arena<Pointer<Utf16>>();
    // KF_FLAG_DONT_VERIFY also works when the user's Startup folder is missing.
    _check(SHGetKnownFolderPath(id, 0x4000, 0, out));
    try {
      return out.value.toDartString();
    } finally {
      CoTaskMemFree(out.value);
    }
  });

  T _withLink<T>(T Function(IShellLink, IPersistFile, Arena) action) {
    final initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) {
      _check(initialized);
    }
    IShellLink? link;
    IPersistFile? file;
    try {
      link = ShellLink.createInstance()..detach();
      file = IPersistFile.from(link)..detach();
      return using((arena) => action(link!, file!, arena));
    } finally {
      if (file != null) {
        file.release();
        calloc.free(file.ptr);
      }
      if (link != null) {
        link.release();
        calloc.free(link.ptr);
      }
      if (SUCCEEDED(initialized)) CoUninitialize();
    }
  }

  @override
  StartupLink? read() {
    final source = File(filename);
    if (!source.existsSync()) return null;
    final bytes = source.readAsBytesSync();
    return _withLink((link, file, arena) {
      _check(file.load(source.path.toNativeUtf16(allocator: arena), STGM_READ));
      final target = arena<Uint16>(32768).cast<Utf16>();
      final arguments = arena<Uint16>(32768).cast<Utf16>();
      final workingDirectory = arena<Uint16>(32768).cast<Utf16>();
      // Never resolve a missing target by searching for another executable.
      const rawPath = 0x4; // SLGP_RAWPATH from shobjidl_core.h.
      _check(link.getPath(target, 32768, nullptr, rawPath));
      _check(link.getArguments(arguments, 32768));
      _check(link.getWorkingDirectory(workingDirectory, 32768));
      return StartupLink(
        bytes,
        target.toDartString(),
        arguments.toDartString(),
        workingDirectory.toDartString(),
      );
    });
  }

  void _replace(void Function(File) write) {
    final destination = File(filename);
    destination.parent.createSync(recursive: true);
    final temporary = File(
      '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      write(temporary);
      // Windows atomically replaces the destination; the temporary has no .lnk extension.
      using((arena) {
        if (MoveFileEx(
              temporary.path.toNativeUtf16(allocator: arena),
              destination.path.toNativeUtf16(allocator: arena),
              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            ) ==
            0) {
          throw StartupException('无法保存开机启动快捷方式（错误码 ${GetLastError()}）。');
        }
      });
    } finally {
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }

  @override
  void save(String executable) => _replace((temporary) {
    _withLink((link, file, arena) {
      _check(link.setPath(executable.toNativeUtf16(allocator: arena)));
      _check(link.setArguments(''.toNativeUtf16(allocator: arena)));
      _check(
        link.setWorkingDirectory(
          path.windows.dirname(executable).toNativeUtf16(allocator: arena),
        ),
      );
      _check(
        link.setDescription('Idreaml Clip'.toNativeUtf16(allocator: arena)),
      );
      _check(
        link.setIconLocation(executable.toNativeUtf16(allocator: arena), 0),
      );
      _check(link.setShowCmd(SW_SHOWNORMAL));
      _check(file.save(temporary.path.toNativeUtf16(allocator: arena), TRUE));
    });
  });

  @override
  void restore(List<int>? bytes) {
    if (bytes == null) {
      final file = File(filename);
      if (file.existsSync()) file.deleteSync();
    } else {
      _replace((temporary) => temporary.writeAsBytesSync(bytes, flush: true));
    }
  }
}
