// Isolated Windows UI verification. No clipboard monitoring, tray hooks,
// existing user database, credentials, or cloud connection are used here.
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:idreaml_clip/src/ui/app_theme.dart';
import 'package:idreaml_clip/src/ui/main_shell.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/data_storage.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/desktop_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';

class _NoCredentials implements CredentialStore {
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> writeToken(String token) async => throw StateError('验证程序不保存令牌');
  @override
  Future<void> deleteToken() async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await Directory.systemTemp.createTemp('idreaml-desk-preview-');
  final storage = DataStorage(
    installationDirectory: root,
    supportDirectory: root,
  );
  await storage.initialize();
  final database = ClipboardDatabase(storage: storage);
  await database.open();
  final repository = ClipboardRepository(database);
  final controller = AppController(
    repository,
    SyncService(repository, _NoCredentials()),
  );
  await controller.initialize(startMonitor: false);
  final desktop = DesktopService(controller);
  await desktop.prepareWindow();
  await windowManager.setPreventClose(false);
  await windowManager.setTitle('Idreaml Clip · 便签待办验证');
  final notes = controller.desktopNotes!;
  for (final kind in DeskKind.values) {
    await notes.updateSettings(kind, {
      'enabled': true,
      'x': kind == DeskKind.note ? 420.0 : 780.0,
      'y': 100.0,
      'width': 320.0,
      'height': 600.0,
    });
  }
  await notes.save(
    DeskKind.note,
    title: '桌面便签',
    body: '在这里记录灵感和临时信息。\n单按 F3 可以快速添加便签。',
  );
  await notes.save(
    DeskKind.note,
    title: '关于新界面的想法',
    body: '留一点呼吸的空间，用清晰的层级呈现每条记录。\n把重要的小事放在看得见的地方。',
  );
  await notes.save(DeskKind.note, body: '下午整理项目资料，记得补上本周的设计笔记。');
  await notes.save(DeskKind.todo, body: '验证待办完成与恢复');
  await notes.save(DeskKind.todo, body: '整理本周的设计笔记');
  await notes.save(DeskKind.todo, body: '为桌面挑选喜欢的卡片颜色', done: true);
  notes.openManager = (kind, id) async {
    controller.selectedDeskId = id;
    controller.deskViewRequest++;
    controller.setPage(kind == DeskKind.note ? AppPage.notes : AppPage.todos);
    await windowManager.show();
    await windowManager.focus();
  };
  await notes.channel.invokeMethod<void>('inspectWindows');
  await notes.attachNative();
  Timer.periodic(const Duration(seconds: 2), (_) async {
    final value = await notes.channel.invokeMethod<Object?>('diagnostics');
    await File(
      '${File(Platform.resolvedExecutable).parent.path}/diagnostics.json',
    ).writeAsString(jsonEncode(value));
  });
  controller.setPage(AppPage.notes);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Stack(
          children: [
            MainShell(controller: controller, desktopService: desktop),
            Positioned(
              right: 24,
              bottom: 24,
              child: Row(
                children: [
                  for (final kind in DeskKind.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: FilledButton(
                        onPressed: () async {
                          await windowManager.hide();
                          await notes.compose(kind, hotkey: true);
                        },
                        child: Text('预览新增${kind.label}'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
