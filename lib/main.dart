import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/data/clipboard_database.dart';
import 'src/data/clipboard_repository.dart';
import 'src/data/data_storage.dart';
import 'src/services/desktop_service.dart';
import 'src/services/credential_service.dart';
import 'src/services/sync_service.dart';
import 'src/services/clipboard_service.dart';
import 'src/services/windows_clipboard_service.dart';
import 'src/services/windows_app_instance.dart';
import 'src/screenshot/screenshot_editor.dart';
import 'src/ui/storage_startup_error.dart';
import 'src/services/administrator_launch_service.dart';

@pragma('vm:entry-point')
void screenshotMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScreenshotEditorApp());
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  AdministratorRestartOptions restart;
  try {
    restart = AdministratorRestartOptions.parse(arguments);
    if (Platform.isWindows && restart.parentId != null) {
      await WindowsAdministratorPlatform().waitForParentExit(restart.parentId!);
    }
  } catch (error) {
    runApp(
      StorageStartupError(
        title: '管理员重启未完成',
        message: error is FormatException
            ? error.message
            : '无法等待原进程退出，请先正常退出原程序后重试。',
        instructions: '重启前的数据和设置仍保留在原目录。',
        allowChooseDirectory: false,
        retry: (_) => main(
          arguments
              .where(
                (value) => !value.startsWith('--administrator-parent-pid='),
              )
              .toList(),
        ),
      ),
    );
    return;
  }

  final instance = Platform.isWindows ? WindowsAppInstance.acquire() : null;
  if (instance != null && instance.launch != InstanceLaunch.primary) exit(0);
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('正在打开剪切板历史…'))),
    ),
  );
  await _startApplication(instance, locatorPath: restart.locatorPath);
}

Future<void> _startApplication(
  WindowsAppInstance? instance, {
  String? initialPath,
  String? locatorPath,
}) async {
  final storage = DataStorage();
  final database = ClipboardDatabase(storage: storage);
  String? storageMessage;
  Future<void> showStorageError(Object error) async {
    await database.close();
    runApp(
      StorageStartupError(
        message: error is StorageException
            ? error.message
            : '无法读取或写入数据文件${error is FileSystemException ? '：${error.path ?? ''}' : '。'}',
        retry: (path) => _startApplication(
          instance,
          initialPath: path,
          locatorPath: locatorPath,
        ),
      ),
    );
  }

  try {
    await storage.initialize(
      initialPath: initialPath,
      locatorPath: locatorPath,
    );
    await database.open();
    storageMessage = await storage.cleanupPreviousDirectory();
    if (storage.needsLegacyMigration) {
      try {
        storageMessage = (await database.moveTo(storage.defaultPath)).warning;
      } catch (_) {
        storageMessage = '暂时无法迁移至安装目录，已继续使用原数据目录。请在设置中选择可写目录。';
      }
    }
    await storage.rememberLocation();
  } catch (error) {
    await showStorageError(error);
    return;
  }
  final repository = ClipboardRepository(database);
  final administrator = AdministratorLaunchService(repository);
  final bool restarting;
  try {
    restarting = await administrator.initialize();
  } catch (error) {
    await showStorageError(error);
    return;
  }
  if (restarting) {
    instance?.stopListening();
    await storage.access.exclusive(database.close);
    exit(0);
  }
  final syncService = SyncService(
    repository,
    SecureCredentialService(storage: storage),
  );
  final controller = AppController(
    repository,
    syncService,
    clipboard: Platform.isWindows
        ? WindowsClipboardService()
        : TextClipboardService(),
  );
  controller.storageMessage = storageMessage;

  final desktopService = DesktopService(
    controller,
    administrator: administrator,
    onExit: () async {
      instance?.stopListening();
      await storage.access.exclusive(() async {
        controller.dispose();
        await database.close();
      });
    },
  );
  try {
    await Future.wait([
      desktopService.prepareWindow(),
      controller.initialize(),
    ]);
  } catch (error) {
    controller.dispose();
    await showStorageError(error);
    return;
  }
  await desktopService.initialize();

  runApp(
    IdreamlClipApp(controller: controller, desktopService: desktopService),
  );
  instance?.listen(
    onActivate: desktopService.showHistory,
    onShutdown: desktopService.exitApp,
  );
}
