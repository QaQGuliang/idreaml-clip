import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/windows_app_instance.dart';
import 'package:win32/win32.dart';

void main() {
  test('path identity ignores case, separators and dot segments', () {
    expect(
      windowsExecutableKey(r'C:\Apps\Idreaml\idreaml_clip.exe'),
      windowsExecutableKey('c:/apps/other/../idreaml/IDREAML_CLIP.EXE'),
    );
    expect(
      windowsExecutableKey(r'C:\Apps\中文\idreaml_clip.exe'),
      isNot(windowsExecutableKey(r'C:\Apps\another\idreaml_clip.exe')),
    );
  });

  group('Windows native instance guard', skip: !Platform.isWindows, () {
    late String namespace;
    setUp(() {
      namespace =
          'Local\\Idreaml.Clip.Test.$pid.${DateTime.now().microsecondsSinceEpoch}';
    });

    test(
      'two folders share an instance and queue activation before UI is ready',
      () async {
        final first = WindowsAppInstance.acquire(
          namespace: namespace,
          executable: r'C:\one\idreaml_clip.exe',
        );
        addTearDown(first.dispose);
        expect(first.launch, InstanceLaunch.primary);
        final second = WindowsAppInstance.acquire(
          namespace: namespace,
          executable: r'C:\two\idreaml_clip.exe',
        );
        expect(second.launch, InstanceLaunch.secondary);
        var activated = 0;
        first.listen(
          onActivate: () async {
            activated++;
          },
          onShutdown: () async {},
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(activated, 1);
      },
    );

    test('shutdown is scoped to the exact installed executable', () async {
      const executable = r'C:\one\idreaml_clip.exe';
      final first = WindowsAppInstance.acquire(
        namespace: namespace,
        executable: executable,
      );
      addTearDown(first.dispose);
      var stopped = 0;
      first.listen(
        onActivate: () async {},
        onShutdown: () async {
          stopped++;
        },
      );
      using((arena) {
        final wrong = OpenEvent(
          EVENT_MODIFY_STATE,
          FALSE,
          '$namespace.Shutdown.${windowsExecutableKey(r'C:\two\idreaml_clip.exe')}'
              .toNativeUtf16(allocator: arena),
        );
        expect(wrong, 0);
        final event = OpenEvent(
          EVENT_MODIFY_STATE,
          FALSE,
          '$namespace.Shutdown.${windowsExecutableKey(executable)}'
              .toNativeUtf16(allocator: arena),
        );
        expect(event, isNot(0));
        SetEvent(event);
        CloseHandle(event);
      });
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(stopped, 1);
      // Shutdown must retain the lock until the owning process actually exits.
      expect(
        WindowsAppInstance.acquire(
          namespace: namespace,
          executable: executable,
        ).launch,
        InstanceLaunch.secondary,
      );
      first.dispose();
      final next = WindowsAppInstance.acquire(
        namespace: namespace,
        executable: executable,
      );
      addTearDown(next.dispose);
      expect(next.launch, InstanceLaunch.primary);
    });

    test('maintenance blocks only the copy whose files are being replaced', () {
      const executable = r'C:\one\idreaml_clip.exe';
      final event = using(
        (arena) => CreateEvent(
          nullptr,
          TRUE,
          TRUE,
          '$namespace.Maintenance.${windowsExecutableKey(executable)}'
              .toNativeUtf16(allocator: arena),
        ),
      );
      addTearDown(() => CloseHandle(event));
      expect(event, isNot(0));
      expect(
        WindowsAppInstance.acquire(
          namespace: namespace,
          executable: executable,
        ).launch,
        InstanceLaunch.maintenance,
      );
      final other = WindowsAppInstance.acquire(
        namespace: namespace,
        executable: r'C:\two\idreaml_clip.exe',
      );
      addTearDown(other.dispose);
      expect(other.launch, InstanceLaunch.primary);
    });
  });
}
