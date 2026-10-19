import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/administrator_launch_service.dart';
import 'package:path/path.dart' as p;

import 'support/clipboard_test_support.dart';

class _Platform implements AdministratorPlatform {
  @override
  bool supported = true;
  bool elevated = false;
  int restarts = 0;
  Object? failure;
  Completer<void>? gate;
  @override
  Future<bool> isElevated() async => elevated;
  @override
  Future<void> restartElevated({String? locatorPath}) async {
    restarts++;
    await gate?.future;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> waitForParentExit(int parentId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryClipboardRepository repository;
  late _Platform platform;
  late AdministratorLaunchService service;
  setUp(() {
    repository = MemoryClipboardRepository();
    platform = _Platform();
    service = AdministratorLaunchService(repository, platform: platform);
  });

  test('默认关闭，普通启动不请求权限', () async {
    expect(await service.initialize(), isFalse);
    expect(service.enabled, isFalse);
    expect(platform.restarts, 0);
  });

  test('开启先保存设置，再请求提权；下次启动沿用该设置', () async {
    await service.initialize();
    expect(await service.setEnabled(true), isTrue);
    expect(
      await repository.getSetting(AdministratorLaunchService.settingKey),
      'true',
    );
    final restarted = AdministratorLaunchService(
      repository,
      platform: platform,
    );
    expect(await restarted.initialize(), isTrue);
    expect(platform.restarts, 2);
  });

  test('当前已是管理员时不重复重启', () async {
    platform.elevated = true;
    expect(await service.setEnabled(true), isFalse);
    expect(service.enabled, isTrue);
    expect(service.elevated, isTrue);
    expect(platform.restarts, 0);
    final restarted = AdministratorLaunchService(
      repository,
      platform: platform,
    );
    expect(await restarted.initialize(), isFalse);
    expect(platform.restarts, 0);
  });

  test('取消 UAC 恢复开关并保持原进程运行', () async {
    platform.failure = PlatformException(code: 'cancelled');
    expect(await service.setEnabled(true), isFalse);
    expect(service.enabled, isFalse);
    expect(
      await repository.getSetting(AdministratorLaunchService.settingKey),
      'false',
    );
    expect(service.message, contains('授权已取消'));
  });

  test('提权启动失败恢复原设置', () async {
    platform.failure = PlatformException(code: 'launch');
    expect(await service.setEnabled(true), isFalse);
    expect(service.enabled, isFalse);
    expect(service.message, contains('无法以管理员身份重启'));
  });

  test('设置保存失败不启动新进程', () async {
    repository.failSettingWrite = true;
    await expectLater(service.setEnabled(true), throwsStateError);
    expect(platform.restarts, 0);
    expect(service.enabled, isFalse);
    expect(service.changing, isFalse);
  });

  test('默认管理员启动被取消时保留偏好并允许继续使用', () async {
    repository.settings[AdministratorLaunchService.settingKey] = 'true';
    platform.failure = PlatformException(code: 'cancelled');
    expect(await service.initialize(), isFalse);
    expect(service.enabled, isTrue);
    expect(service.message, contains('继续以普通身份运行'));
    expect(await service.setEnabled(false), isFalse);
    expect(
      await repository.getSetting(AdministratorLaunchService.settingKey),
      'false',
    );
  });

  test('关闭默认提权不重启当前管理员进程，下次普通启动不提权', () async {
    platform.elevated = true;
    repository.settings[AdministratorLaunchService.settingKey] = 'true';
    await service.initialize();
    expect(await service.setEnabled(false), isFalse);
    expect(service.message, contains('下次从桌面普通启动时生效'));
    platform.elevated = false;
    final restarted = AdministratorLaunchService(
      repository,
      platform: platform,
    );
    expect(await restarted.initialize(), isFalse);
    expect(platform.restarts, 0);
  });

  test('授权请求期间阻止重复提交，完成后释放状态', () async {
    platform.gate = Completer<void>();
    final changing = service.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(service.changing, isTrue);
    await expectLater(service.setEnabled(true), throwsStateError);
    expect(platform.restarts, 1);
    platform.gate!.complete();
    expect(await changing, isTrue);
    expect(service.changing, isFalse);
  });

  test('其他平台不读取或修改管理员启动偏好', () async {
    platform.supported = false;
    expect(await service.initialize(), isFalse);
    await expectLater(service.setEnabled(true), throwsUnsupportedError);
    expect(repository.settings, isEmpty);
    expect(platform.restarts, 0);
  });

  test('桌面服务刷新状态时不会自动弹出提权请求', () async {
    repository.settings[AdministratorLaunchService.settingKey] = 'true';
    expect(await service.initialize(requestRestart: false), isFalse);
    expect(service.enabled, isTrue);
    expect(platform.restarts, 0);
  });

  test('解析重启参数并保留中文和空格目录', () {
    final locator = p.absolute('中文 空格', 'storage-location.json');
    final args = AdministratorRestartOptions.parse([
      '--administrator-parent-pid=123',
      '--storage-locator=$locator',
    ]);
    expect(args.parentId, 123);
    expect(args.locatorPath, locator);
    for (final value in ['0', '-1', 'abc', '4294967296']) {
      expect(
        () => AdministratorRestartOptions.parse([
          '--administrator-parent-pid=$value',
        ]),
        throwsFormatException,
      );
    }
    expect(
      () => AdministratorRestartOptions.parse([
        '--storage-locator=relative.json',
      ]),
      throwsFormatException,
    );
    expect(AdministratorRestartOptions.parse([]).parentId, isNull);
  });

  test('Windows 通道保留目录参数并单独等待原进程退出', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(WindowsAdministratorPlatform.channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'isElevated' ? true : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        WindowsAdministratorPlatform.channel,
        null,
      ),
    );
    final native = WindowsAdministratorPlatform();
    expect(await native.isElevated(), isTrue);
    final locator = p.absolute('data 空格', 'storage-location.json');
    await native.restartElevated(locatorPath: locator);
    await native.waitForParentExit(pid);
    expect(calls[1].arguments, locator);
    expect(calls[2].arguments, pid);
  });
}
