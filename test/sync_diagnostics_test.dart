import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:idreaml_clip/src/services/sync_format_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/clipboard_test_support.dart';

class _Credentials implements CredentialStore {
  final secrets = <String?, String>{null: 'test-token'};

  @override
  Future<String?> readToken({String? id}) async => secrets[id];
  @override
  Future<void> writeToken(String token, {String? id}) async =>
      secrets[id] = token;
  @override
  Future<void> deleteToken({String? id}) async => secrets.remove(id);
}

class _Repository extends ClipboardRepository {
  _Repository(super.database);

  bool failConfigWrite = false;

  @override
  Future<void> setSetting(String key, String value) async {
    if (failConfigWrite && key == 'cloud_sync_config') {
      throw StateError('Simulated settings write failure');
    }
    await super.setSetting(key, value);
  }
}

class _LocalGit extends EmbeddedGitService {
  bool rejectPush = false;
  bool retryReconcile = false;
  Future<void> Function(Directory)? seed;
  int reconcileCount = 0;
  String? receivedToken;

  @override
  Future<T> synchronize<T>({
    required Directory directory,
    required SyncConfig config,
    required String token,
    required Future<T> Function() reconcile,
  }) async {
    receivedToken = token;
    await directory.create(recursive: true);
    await seed?.call(directory);
    var result = await reconcile();
    reconcileCount++;
    if (retryReconcile) {
      result = await reconcile();
      reconcileCount++;
    }
    if (rejectPush) throw SyncFailure(SyncPhase.push, '测试服务器拒绝推送');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory root;
  late ClipboardDatabase database;
  late _Repository repository;
  late _LocalGit git;
  late _Credentials credentials;
  late SyncService sync;
  late AppController controller;
  late DesktopNotes notes;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-sync-diagnostics-');
    database = ClipboardDatabase.withFactory(databaseFactoryFfiNoIsolate);
    await database.open(path: p.join(root.path, 'clipboard.db'));
    repository = _Repository(database);
    await repository.initializeDevice();
    git = _LocalGit();
    credentials = _Credentials();
    now = DateTime(2026, 11, 13, 12);
    sync = SyncService(
      repository,
      credentials,
      git: git,
      supportDirectory: () async => root,
      now: () => now,
    );
    sync.config = const SyncConfig(
      provider: SyncProvider.custom,
      remoteUrl: 'https://example.test/sync.git',
      username: 'test',
    );
    controller = AppController(repository, sync);
    notes = DesktopNotes(
      DeskRepository(
        deviceId: 'test-device',
        testPath: '${root.path}/desktop.db',
        factory: databaseFactoryFfiNoIsolate,
      ),
    );
    await notes.initialize();
    controller.desktopNotes = notes;
    sync.syncDesktopNotes = notes.synchronize;
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    expect(p.isWithin(temp, resolved), isTrue);
    expect(p.basename(resolved), startsWith('idreaml-sync-diagnostics-'));
    await Directory(resolved).delete(recursive: true);
  });

  test('整体成功才保存分项结果，推送失败保留上次成功结果', () async {
    await repository.captureText('剪切板测试内容');
    await notes.updateSettings(DeskKind.note, {'enabled': true, 'sync': true});
    await notes.save(DeskKind.note, body: '便签测试内容');
    final result = await sync.syncNow();
    expect(result!.clipboard!.exported, 1);
    expect(result.notes!.exported, 1);
    expect(result.todos!.state, SyncModuleState.featureDisabled);
    expect(result.exported, 2);
    expect(sync.lastResult, same(result));
    expect(result.description, contains('待办 · 功能未开启'));
    git.rejectPush = true;
    await notes.save(DeskKind.note, body: '尚未上传的便签');
    expect(await sync.syncNow(), isNull);
    expect(sync.status, CloudSyncStatus.error);
    expect(sync.lastResult, same(result));
    expect(sync.lastResult!.notes!.exported, 1);
    await sync.disconnect();
    expect(sync.lastResult, isNull);
    expect(sync.lastSyncedAt, isNull);
  });

  test('更换同步分支清除旧仓库结果，旧版结果构造仍可用', () async {
    expect(
      const SyncResult(imported: 1, exported: 2).description,
      '导入 1 项，导出快照 2 项',
    );
    await sync.syncNow();
    expect(sync.lastResult, isNotNull);
    await sync.saveConfig(sync.config!.copyWith(branch: 'another'));
    expect(sync.lastResult, isNull);
    expect(sync.status, CloudSyncStatus.idle);
  });

  test('自托管支持 HTTP 和 HTTPS，切换仓库和账号须输入对应凭据', () async {
    final old = sync.config!;
    final target = old.copyWith(
      remoteUrl: 'https://git.example.test:8443/git/team/clip.git',
      username: 'new-account',
      branch: 'sync/home',
      syncOnStartup: false,
    );
    await expectLater(sync.saveConfig(target), throwsFormatException);
    await expectLater(
      sync.saveConfig(old.copyWith(username: 'other-account')),
      throwsFormatException,
    );
    expect(sync.config, same(old));
    expect(await credentials.readToken(), 'test-token');
    repository.failConfigWrite = true;
    await expectLater(
      sync.saveConfig(target, token: 'new-secret'),
      throwsStateError,
    );
    expect(sync.config, same(old));
    expect(credentials.secrets, {null: 'test-token'});
    repository.failConfigWrite = false;

    for (final url in [
      'ssh://git.example.test/clip.git',
      'http:///clip.git',
      'http://name:secret@git.example.test/clip.git',
      'https://name:secret@git.example.test/clip.git',
      'https://git.example.test/clip.git?token=secret',
    ]) {
      await expectLater(
        sync.saveConfig(target.copyWith(remoteUrl: url), token: 'test'),
        throwsFormatException,
      );
    }
    await expectLater(
      sync.saveConfig(target.copyWith(username: ''), token: 'test'),
      throwsFormatException,
    );

    const secret = ' valid password ';
    await sync.saveConfig(target, token: secret);
    final stored = (await repository.getSetting('cloud_sync_config'))!;
    final reopened = SyncConfig.decode(stored);
    expect(reopened.provider, SyncProvider.custom);
    expect(reopened.credentialId, isNotNull);
    expect(stored, isNot(contains(secret)));
    expect(await credentials.readToken(), isNull);
    expect(await credentials.readToken(id: reopened.credentialId), secret);
    await sync.saveConfig(reopened.copyWith(branch: 'another'));
    expect(sync.config!.credentialId, reopened.credentialId);
    expect(await sync.syncNow(), isNotNull);
    expect(git.receivedToken, secret);

    const httpUrl = 'http://192.168.1.10:3000/team/clip.git';
    await expectLater(
      sync.saveConfig(reopened.copyWith(remoteUrl: httpUrl)),
      throwsFormatException,
    );
    await expectLater(
      sync.saveConfig(
        reopened.copyWith(provider: SyncProvider.gitlab, remoteUrl: httpUrl),
        token: 'test',
      ),
      throwsFormatException,
    );
    await sync.saveConfig(
      const SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: httpUrl,
        username: 'new-account',
        certificateExceptionUrl: httpUrl,
      ),
      token: 'http-secret',
    );
    final httpConfig = SyncConfig.decode(
      (await repository.getSetting('cloud_sync_config'))!,
    );
    expect(httpConfig.remoteUrl, httpUrl);
    expect(httpConfig.certificateExceptionUrl, isNull);
    expect(await sync.syncNow(), isNotNull);
    expect(git.receivedToken, 'http-secret');
    await sync.disconnect();
    expect(credentials.secrets, isEmpty);
  });

  test('推送竞争重试合并时累计各模块导入，导出只统计最终快照', () async {
    for (final kind in DeskKind.values) {
      await notes.updateSettings(kind, {'enabled': true, 'sync': true});
    }
    git.retryReconcile = true;
    git.seed = (directory) async {
      final sourceDatabase = ClipboardDatabase.withFactory(
        databaseFactoryFfiNoIsolate,
      );
      await sourceDatabase.open(path: '${root.path}/remote-clipboard.db');
      try {
        final source = ClipboardRepository(sourceDatabase);
        await source.initializeDevice();
        await source.captureText('远端剪切板内容');
        await SyncFormatService().exportDevice(
          repository: directory,
          deviceId: source.deviceId,
          deviceName: '测试远端',
          items: await source.listForSync(),
        );
      } finally {
        await sourceDatabase.close();
      }
      final sourceNotes = DeskRepository(
        deviceId: 'remote-device',
        testPath: '${root.path}/remote-desktop.db',
        factory: databaseFactoryFfiNoIsolate,
      );
      await sourceNotes.save(DeskKind.note, body: '远端便签');
      await sourceNotes.save(DeskKind.todo, body: '远端待办');
      await sourceNotes.synchronize(directory, DeskKind.values.toSet());
    };
    final result = await sync.syncNow();
    expect(git.reconcileCount, 2);
    expect(result!.imported, 3);
    expect(result.exported, 3);
    for (final module in [result.clipboard!, result.notes!, result.todos!]) {
      expect(module.imported, 1);
      expect(module.exported, 1);
      expect(module.state, SyncModuleState.participating);
    }
    expect(sync.history, hasLength(1));
  });

  test('同步记录在重启后保留，满七天的记录会从数据库删除', () async {
    final currentTime = now;
    now = currentTime.subtract(const Duration(days: 7));
    await sync.syncNow(trigger: SyncTrigger.startup);
    expect(sync.history.single.trigger, SyncTrigger.startup);

    now = currentTime.subtract(const Duration(days: 6));
    await sync.syncNow(trigger: SyncTrigger.scheduled);
    expect(sync.history, hasLength(2));

    now = currentTime;
    git.rejectPush = true;
    expect(await sync.syncNow(), isNull);
    expect(sync.history.map((entry) => entry.trigger), [
      SyncTrigger.manual,
      SyncTrigger.scheduled,
    ]);
    expect(sync.history.first.succeeded, isFalse);
    expect(sync.history.first.details, contains('上传到远端失败'));
    expect(sync.history.last.succeeded, isTrue);
    expect(sync.history.last.details, contains('剪切板'));

    await database.close();
    await database.open(path: p.join(root.path, 'clipboard.db'));
    final restarted = SyncService(repository, _Credentials(), now: () => now);
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.history.map((entry) => entry.trigger), [
      SyncTrigger.manual,
      SyncTrigger.scheduled,
    ]);
    expect(await database.database.query('sync_history'), hasLength(2));

    now = now.add(const Duration(days: 8));
    await restarted.initialize();
    expect(restarted.history, isEmpty);
    expect(await database.database.query('sync_history'), isEmpty);
  });

  testWidgets('云同步卡显示三个模块，剪切板大计数不会掩盖桌面模块暂停', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {'enabled': true});
      await controller.setPage(AppPage.sync);
    });
    sync.lastResult = const SyncResult(
      imported: 0,
      exported: 2000,
      clipboard: SyncModuleResult(exported: 2000),
      notes: SyncModuleResult(state: SyncModuleState.syncDisabled),
      todos: SyncModuleResult(state: SyncModuleState.featureDisabled),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: RecordingDesktopService(controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('剪切板同步'), findsOneWidget);
    expect(find.text('便签同步'), findsOneWidget);
    expect(find.text('待办同步'), findsOneWidget);
    expect(find.text('参与同步'), findsOneWidget);
    expect(find.text('同步已关闭'), findsOneWidget);
    expect(find.text('功能未开启'), findsOneWidget);
    expect(find.textContaining('导出快照 2000 项'), findsOneWidget);
    expect(find.textContaining('上次完成 · 同步已关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(900, 620);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('待办同步'),
      100,
      scrollable: _syncPageScrollable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('待办同步').hitTestable(), findsOneWidget);
    expect(find.text('功能未开启').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('云同步页面底部显示近期成功和失败的记录', (tester) async {
    await tester.runAsync(() async {
      await sync.syncNow(trigger: SyncTrigger.scheduled);
      now = now.add(const Duration(minutes: 1));
      git.rejectPush = true;
      await sync.syncNow();
      await controller.setPage(AppPage.sync);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: RecordingDesktopService(controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('同步记录'),
      120,
      scrollable: _syncPageScrollable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('本机保留最近 7 天'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining('12:01 · 手动同步'), findsOneWidget);
    expect(find.textContaining('12:00 · 定时同步'), findsOneWidget);
    expect(find.textContaining('上传到远端失败'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自托管连接按地址协议显示证书选项', (tester) async {
    sync.config = sync.config!.copyWith(
      provider: SyncProvider.gitee,
      remoteUrl: 'https://gitee.com/example/previous.git',
      username: 'previous-account',
    );
    await controller.setPage(AppPage.sync);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: RecordingDesktopService(controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('自托管 Git'), findsOneWidget);
    final connect = find.widgetWithText(TextButton, '连接').last;
    await tester.ensureVisible(connect);
    await tester.tap(connect);
    await tester.pumpAndSettle();
    expect(find.text('自托管 Git 仓库连接'), findsOneWidget);
    expect(find.text('HTTP / HTTPS 克隆地址'), findsOneWidget);
    expect(find.text('密码或访问令牌'), findsOneWidget);
    expect(find.text('同步分支'), findsOneWidget);
    expect(find.text('https://gitee.com/example/previous.git'), findsNothing);
    expect(find.text('previous-account'), findsNothing);
    final certificateOption = find.widgetWithText(
      SwitchListTile,
      '跳过 HTTPS 证书校验',
    );
    final address = find.widgetWithText(TextField, 'HTTP / HTTPS 克隆地址');
    expect(certificateOption, findsNothing);
    await tester.enterText(address, 'https://git.example.test/clip.git');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(certificateOption).value, isFalse);
    await tester.ensureVisible(certificateOption);
    await tester.tap(certificateOption);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(certificateOption).value, isTrue);
    await tester.ensureVisible(address);
    await tester.enterText(address, 'http://git.example.test:3000/clip.git');
    await tester.pumpAndSettle();
    expect(certificateOption, findsNothing);
    expect(find.textContaining('HTTP 会明文传输'), findsOneWidget);
    await tester.enterText(address, 'https://git.example.test/clip.git');
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(certificateOption).value, isFalse);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .singleWhere((field) => field.decoration?.labelText == '密码或访问令牌')
          .obscureText,
      isTrue,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Finder _syncPageScrollable() => find
    .descendant(
      of: find.byKey(const ValueKey('cloud-sync-page')),
      matching: find.byType(Scrollable),
    )
    .first;
