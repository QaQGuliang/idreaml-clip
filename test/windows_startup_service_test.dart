import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/startup_service.dart';
import 'package:idreaml_clip/src/services/windows_startup_service.dart';
import 'package:idreaml_clip/src/services/windows_startup_store.dart';
import 'package:win32/win32.dart';

class _Store implements WindowsStartupStore {
  WindowsStartupRegistration value = const WindowsStartupRegistration();
  int writes = 0;
  bool failOnce = false;
  bool loseCommandOnce = false;
  @override
  WindowsStartupRegistration read() => value;
  @override
  void write(WindowsStartupRegistration next) {
    writes++;
    if (failOnce) {
      failOnce = false;
      value = WindowsStartupRegistration(command: next.command);
      throw const StartupException('Windows 拒绝访问开机启动设置');
    }
    value = loseCommandOnce
        ? WindowsStartupRegistration(approval: next.approval, owner: next.owner)
        : next;
    loseCommandOnce = false;
  }
}

void main() {
  const executable = r'C:\Program Files\理梦剪藏\idreaml_clip.exe';
  final enabled = [2, ...List.filled(11, 0)];
  late _Store store;
  late WindowsStartupService service;
  setUp(() {
    store = _Store();
    service = WindowsStartupService(
      store: store,
      executable: executable,
      exists: (_) => true,
    );
  });

  test('首次启动不替用户开启；显式开启保存带引号的 Unicode 路径并校验', () async {
    expect((await service.initialize()).enabled, isFalse);
    expect(store.writes, 0);
    expect((await service.setEnabled(true)).enabled, isTrue);
    expect(store.value.command, '"$executable"');
    expect(store.value.approval, enabled);
    expect(store.value.owner, executable);
    expect((await service.read()).enabled, isTrue);
    final writes = store.writes;
    await service.initialize();
    expect(store.writes, writes, reason: '正常启动不反复写入 Run');
  });

  test('旧版仅剩批准标记时显示关闭，用户在设置开启即可修复', () async {
    store.value = WindowsStartupRegistration(approval: enabled);
    final state = await service.initialize();
    expect(state.enabled, isFalse);
    expect(state.message, contains('不完整'));
    expect(store.writes, 0);
    await service.setEnabled(true);
    expect(store.value.command, '"$executable"');
    expect((await service.read()).enabled, isTrue);
  });

  test('已明确开启后 Run 和批准标记丢失，下次运行修复；关闭后不再恢复', () async {
    await service.setEnabled(true);
    store.value = WindowsStartupRegistration(owner: store.value.owner);
    final nextSession = WindowsStartupService(
      store: store,
      executable: executable,
      exists: (_) => true,
    );
    expect((await nextSession.initialize()).enabled, isTrue);
    expect(store.value.command, '"$executable"');
    await nextSession.setEnabled(false);
    expect(store.value.sameAs(const WindowsStartupRegistration()), isTrue);
    expect((await nextSession.initialize()).enabled, isFalse);
  });

  test('迁移旧版未加引号的有效启动项，并记录开启意愿', () async {
    store.value = WindowsStartupRegistration(
      command: executable,
      approval: enabled,
    );
    expect((await service.initialize()).enabled, isTrue);
    expect(store.value.command, '"$executable"');
    expect(store.value.owner, executable);
  });

  for (final marker in [3, 7, 99]) {
    test('保留 Windows 禁用或未知状态 $marker，不自动开启', () async {
      final approval = [marker, ...List.filled(11, 0)];
      store.value = WindowsStartupRegistration(
        owner: executable,
        approval: approval,
      );
      expect((await service.initialize()).enabled, isFalse);
      expect(store.writes, 0);
      expect(store.value.approval, approval);
      expect((await service.setEnabled(true)).enabled, isTrue);
      expect(store.value.approval, enabled);
    });
  }

  test('迁移已移动的程序；旧副本仍存在或其他程序占用启动项时不抢占', () async {
    const old = r'D:\Old Clip\idreaml_clip.exe';
    store.value = WindowsStartupRegistration(command: '"$old"', owner: old);
    expect((await service.initialize()).enabled, isFalse);
    expect(store.writes, 0);
    final moved = WindowsStartupService(
      store: store,
      executable: executable,
      exists: (value) => value == executable,
    );
    expect((await moved.initialize()).enabled, isTrue);
    expect(store.value.owner, executable);
    store.value = const WindowsStartupRegistration(
      command: r'C:\other.exe',
      owner: old,
    );
    final writes = store.writes;
    expect((await moved.initialize()).enabled, isFalse);
    expect(store.writes, writes);
  });

  test('拒绝包含参数的命令，不自动将其视为当前自启', () async {
    store.value = WindowsStartupRegistration(command: '"$executable" --other');
    expect((await service.initialize()).enabled, isFalse);
    expect(store.writes, 0);
  });

  test('异常的单个引号启动命令不导致初始化异常，可在应用内修复', () async {
    store.value = const WindowsStartupRegistration(command: '"');
    expect((await service.initialize()).enabled, isFalse);
    expect(store.writes, 0);
    expect((await service.setEnabled(true)).enabled, isTrue);
  });

  test('部分写入失败回滚，不能假装启用成功', () async {
    store.failOnce = true;
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect(store.value.sameAs(const WindowsStartupRegistration()), isTrue);
    expect((await service.read()).enabled, isFalse);
  });

  test('写入后记录被改动导致校验失败，完整恢复原禁用标记', () async {
    final before = WindowsStartupRegistration(
      approval: [3, ...List.filled(11, 0)],
    );
    store.value = before;
    store.loseCommandOnce = true;
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect(store.value.sameAs(before), isTrue);
  });

  test('关闭失败时恢复原来的开启状态', () async {
    await service.setEnabled(true);
    final before = store.value;
    store.failOnce = true;
    await expectLater(
      service.setEnabled(false),
      throwsA(isA<StartupException>()),
    );
    expect(store.value.sameAs(before), isTrue);
    expect((await service.read()).enabled, isTrue);
  });

  test('无效、过长及不存在的程序路径不写入注册表', () async {
    for (final badPath in [
      'relative.exe',
      'C:\\${'x' * 260}.exe',
      'C:\\bad".exe',
    ]) {
      final invalid = WindowsStartupService(
        store: store,
        executable: badPath,
        exists: (_) => true,
      );
      await expectLater(
        invalid.setEnabled(true),
        throwsA(isA<StartupException>()),
      );
    }
    final missing = WindowsStartupService(
      store: store,
      executable: executable,
      exists: (_) => false,
    );
    await expectLater(
      missing.setEnabled(true),
      throwsA(isA<StartupException>()),
    );
    expect(store.writes, 0);
  });

  test('Windows 注册表真实读写：新建缺失键、修复和关闭（独立测试子树）', () async {
    final root =
        'Software\\Idreaml\\Clip\\Tests\\Startup.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final native = WindowsRegistryStartupStore(
      runKey: '$root\\Run',
      approvalKey: '$root\\Approved',
      preferenceKey: '$root\\Preference',
      folderApprovalKey: '$root\\FolderApproved',
    );
    final nativeService = WindowsStartupService(
      store: native,
      executable: executable,
      exists: (_) => true,
    );
    try {
      expect((await nativeService.initialize()).enabled, isFalse);
      await nativeService.setEnabled(true);
      expect(native.read().command, '"$executable"');
      expect(native.read().approval, enabled);
      expect(native.read().owner, executable);
      // Independently verify what another Windows process sees, instead of
      // relying solely on a round trip through our own FFI registry adapter.
      final systemRead = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('
            '[Microsoft.Win32.Registry]::GetValue('
            '"HKEY_CURRENT_USER\\$root\\Run", "Idreaml Clip", "<missing>")))',
      ]);
      expect(systemRead.exitCode, 0, reason: '${systemRead.stderr}');
      expect(
        (systemRead.stdout as String).trim(),
        base64Encode(utf8.encode('"$executable"')),
        reason: '系统必须能读到同一启动命令，包括引号、中文和空格',
      );
      native.write(
        WindowsStartupRegistration(approval: enabled, owner: executable),
      );
      expect((await nativeService.initialize()).enabled, isTrue);
      expect(native.read().command, '"$executable"');
      await nativeService.setEnabled(false);
      expect(native.read().sameAs(const WindowsStartupRegistration()), isTrue);
    } finally {
      expect(root.startsWith(r'Software\Idreaml\Clip\Tests\Startup.'), isTrue);
      final result = using(
        (arena) => RegDeleteTree(
          HKEY_CURRENT_USER,
          root.toNativeUtf16(allocator: arena),
        ),
      );
      expect(result, anyOf(ERROR_SUCCESS, ERROR_FILE_NOT_FOUND));
    }
  }, skip: !Platform.isWindows);
}
