import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:win32/win32.dart';
import 'package:idreaml_clip/src/services/startup_service.dart';
import 'package:idreaml_clip/src/services/windows_folder_startup_service.dart';
import 'package:idreaml_clip/src/services/windows_startup_service.dart';
import 'package:idreaml_clip/src/services/windows_startup_link.dart';
import 'package:idreaml_clip/src/services/windows_startup_store.dart';

class _Registry implements WindowsStartupStore {
  WindowsStartupRegistration value = const WindowsStartupRegistration();
  int writes = 0;
  bool failOnce = false;
  @override
  WindowsStartupRegistration read() => value;
  @override
  void write(WindowsStartupRegistration next) {
    writes++;
    value = next;
    if (failOnce) {
      failOnce = false;
      throw const StartupException('保存失败');
    }
  }
}

class _Links implements WindowsStartupLinkStore {
  List<int>? bytes;
  int saves = 0;
  @override
  StartupLink? read() {
    if (bytes == null) return null;
    final parts = jsonDecode(utf8.decode(bytes!)) as List;
    return StartupLink(bytes!, parts[0], parts[1], parts[2]);
  }

  @override
  void save(String executable) {
    saves++;
    bytes = utf8.encode(
      jsonEncode([executable, '', path.windows.dirname(executable)]),
    );
  }

  @override
  void restore(List<int>? value) => bytes = value;
}

void main() {
  const executable = r'C:\Program Files\理梦剪藏\idreaml_clip.exe';
  final enabledMarker = [2, ...List.filled(11, 0)];
  late _Registry registry;
  late _Links links;
  late WindowsFolderStartupService service;
  setUp(() {
    registry = _Registry();
    links = _Links();
    service = WindowsFolderStartupService(
      registry: registry,
      links: links,
      executable: executable,
      exists: (_) => true,
      settle: () async {},
    );
  });

  test('首次启动不开启；显式开启只创建一个快捷方式；关闭后不再恢复', () async {
    expect((await service.initialize()).enabled, isFalse);
    expect((await service.setEnabled(true)).enabled, isTrue);
    expect(links.read()!.target, executable);
    expect(links.read()!.arguments, isEmpty);
    expect(links.read()!.workingDirectory, path.windows.dirname(executable));
    expect(registry.value.command, isNull);
    expect(registry.value.approval, isNull);
    expect(registry.value.owner, executable);
    await service.setEnabled(false);
    expect(links.read(), isNull);
    expect(registry.value.sameAs(const WindowsStartupRegistration()), isTrue);
    expect((await service.initialize()).enabled, isFalse);
  });

  test('复现笔记本：Run 缺失、Executable 和批准标记存在，自动迁移', () async {
    registry.value = WindowsStartupRegistration(
      owner: executable,
      approval: enabledMarker,
    );
    expect((await service.initialize()).enabled, isTrue);
    expect(links.saves, 1);
    expect(registry.value.command, isNull);
    expect(registry.value.approval, isNull);
    final writes = registry.writes;
    await service.initialize();
    expect(links.saves, 1);
    expect(registry.writes, writes);
  });

  test('旧 Run 正常时迁移并删除旧入口，孤立批准标记不代表用户开启', () async {
    registry.value = WindowsStartupRegistration(approval: enabledMarker);
    expect((await service.initialize()).enabled, isFalse);
    registry.value = WindowsStartupRegistration(
      command: '"$executable"',
      approval: enabledMarker,
    );
    expect((await service.initialize()).enabled, isTrue);
    expect(registry.value.command, isNull);
  });

  for (final disabled in [3, 7, 99]) {
    test('保留 Windows 禁用状态 $disabled，显式开启后才恢复', () async {
      final marker = [disabled, ...List.filled(11, 0)];
      registry.value = WindowsStartupRegistration(
        owner: executable,
        approval: marker,
      );
      expect((await service.initialize()).enabled, isFalse);
      expect(links.saves, 0);
      await service.setEnabled(true);
      registry.value = WindowsStartupRegistration(
        owner: executable,
        folderApproval: marker,
      );
      expect((await service.initialize()).enabled, isFalse);
      expect(links.saves, 1);
      expect((await service.setEnabled(true)).enabled, isTrue);
    });
  }

  test('保存后延迟检查能发现快捷方式被删除，失败回滚而不显示开启', () async {
    final checked = WindowsFolderStartupService(
      registry: registry,
      links: links,
      executable: executable,
      exists: (_) => true,
      settle: () async {
        links.restore(null);
      },
    );
    await expectLater(
      checked.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect((await checked.read()).enabled, isFalse);
    expect(registry.value.owner, isNull);
  });

  test('Windows 补充允许标记不误判为保存失败，之后外部删除能被 read 发现', () async {
    registry.value = WindowsStartupRegistration(
      owner: executable,
      approval: enabledMarker,
    );
    final checked = WindowsFolderStartupService(
      registry: registry,
      links: links,
      executable: executable,
      exists: (_) => true,
      settle: () async {
        registry.value = WindowsStartupRegistration(
          owner: executable,
          folderApproval: enabledMarker,
        );
      },
    );
    expect((await checked.initialize()).enabled, isTrue);
    links.restore(null);
    final state = await checked.read();
    expect(state.enabled, isFalse);
    expect(state.message, contains('丢失'));
  });

  test('注册失败恢复原快捷方式和原 Run 注册；关闭失败也恢复', () async {
    registry.value = WindowsStartupRegistration(
      command: executable,
      approval: enabledMarker,
    );
    final original = registry.value;
    registry.failOnce = true;
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect(links.read(), isNull);
    expect(registry.value.sameAs(original), isTrue);
    await service.setEnabled(true);
    final saved = links.bytes;
    registry.failOnce = true;
    await expectLater(
      service.setEnabled(false),
      throwsA(isA<StartupException>()),
    );
    expect(links.bytes, saved);
    expect((await service.read()).enabled, isTrue);
  });

  test('不抢占仍存在的其他副本；移动后旧副本不存在则迁移', () async {
    const old = r'D:\Old Clip\idreaml_clip.exe';
    registry.value = const WindowsStartupRegistration(owner: old);
    links.save(old);
    expect((await service.initialize()).enabled, isFalse);
    final moved = WindowsFolderStartupService(
      registry: registry,
      links: links,
      executable: executable,
      exists: (file) => file == executable,
      settle: () async {},
    );
    expect((await moved.initialize()).enabled, isTrue);
    expect(links.read()!.target, executable);
  });

  test('异常参数不视为已开启，且不在初始化时覆盖用户修改的快捷方式', () async {
    registry.value = const WindowsStartupRegistration(owner: executable);
    links.bytes = utf8.encode(
      jsonEncode([executable, '--other', path.windows.dirname(executable)]),
    );
    expect((await service.initialize()).enabled, isFalse);
    expect(links.saves, 0);
    expect((await service.setEnabled(true)).enabled, isTrue);
  });

  test('无效或不存在的程序路径不创建快捷方式', () async {
    final missing = WindowsFolderStartupService(
      registry: registry,
      links: links,
      executable: executable,
      exists: (_) => false,
      settle: () async {},
    );
    await expectLater(
      missing.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect(links.saves, 0);
    expect(registry.writes, 0);
  });

  test('真实 COM 快捷方式由 Windows 独立读取和执行，注册表与文件使用隔离位置', () async {
    final directory = Directory.systemTemp.createTempSync(
      'idreaml-startup-test-',
    );
    final root =
        'Software\\Idreaml\\Clip\\Tests\\Folder.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final nativeRegistry = WindowsRegistryStartupStore(
      runKey: '$root\\Run',
      approvalKey: '$root\\RunApproved',
      preferenceKey: '$root\\Preference',
      folderApprovalKey: '$root\\FolderApproved',
    );
    final nativeLinks = WindowsStartupLinkFile(
      directory: path.join(directory.path, '启动目录'),
    );
    final applicationDirectory = Directory(path.join(directory.path, '中文 应用'))
      ..createSync();
    final target = File(
      path.windows.join(
        Platform.environment['WINDIR']!,
        'System32',
        'whoami.exe',
      ),
    ).copySync(path.join(applicationDirectory.path, 'whoami.exe')).path;
    final nativeService = WindowsFolderStartupService(
      registry: nativeRegistry,
      links: nativeLinks,
      executable: target,
      settle: () async {},
    );
    try {
      expect((await nativeService.setEnabled(true)).enabled, isTrue);
      final escaped = nativeLinks.filename.replaceAll("'", "''");
      final independent = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$link=(New-Object -ComObject WScript.Shell).CreateShortcut(\'$escaped\'); '
            '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$link.TargetPath)); '
            '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$link.WorkingDirectory))',
      ]);
      expect(independent.exitCode, 0, reason: '${independent.stderr}');
      expect(
        (independent.stdout as String)
            .trim()
            .split(RegExp(r'\r?\n'))
            .map((value) => utf8.decode(base64Decode(value)).toLowerCase())
            .toList(),
        [target.toLowerCase(), path.windows.dirname(target).toLowerCase()],
      );
      // Execute only a harmless Windows command through the temporary shortcut.
      using((arena) {
        final info = arena<SHELLEXECUTEINFO>();
        info.ref.cbSize = sizeOf<SHELLEXECUTEINFO>();
        // SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC from shellapi.h.
        info.ref.fMask = 0x40 | 0x100;
        info.ref.lpFile = nativeLinks.filename.toNativeUtf16(allocator: arena);
        info.ref.nShow = SW_HIDE;
        expect(
          ShellExecuteEx(info),
          isNot(0),
          reason: 'ShellExecuteEx: ${GetLastError()}',
        );
        try {
          expect(WaitForSingleObject(info.ref.hProcess, 10000), WAIT_OBJECT_0);
          final code = arena<Uint32>();
          expect(GetExitCodeProcess(info.ref.hProcess, code), isNot(0));
          expect(code.value, 0);
        } finally {
          CloseHandle(info.ref.hProcess);
        }
      });
      await nativeService.setEnabled(false);
      expect(File(nativeLinks.filename).existsSync(), isFalse);
      expect(
        nativeRegistry.read().sameAs(const WindowsStartupRegistration()),
        isTrue,
      );
    } finally {
      expect(root.startsWith(r'Software\Idreaml\Clip\Tests\Folder.'), isTrue);
      using((arena) {
        RegDeleteTree(HKEY_CURRENT_USER, root.toNativeUtf16(allocator: arena));
      });
      directory.deleteSync(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('真实启动目录与 Windows 当前用户的 Startup 文件夹一致（只读）', () async {
    final system = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('
          '[Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)))',
    ]);
    expect(system.exitCode, 0, reason: '${system.stderr}');
    final directory = utf8.decode(
      base64Decode((system.stdout as String).trim()),
    );
    expect(
      path.windows.dirname(WindowsStartupLinkFile().filename).toLowerCase(),
      directory.toLowerCase(),
    );
  }, skip: !Platform.isWindows);
}
