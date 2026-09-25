import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/data/clipboard_database.dart';
import 'src/data/clipboard_repository.dart';
import 'src/services/desktop_service.dart';
import 'src/services/credential_service.dart';
import 'src/services/sync_service.dart';
import 'src/services/clipboard_service.dart';
import 'src/services/windows_clipboard_service.dart';
import 'src/services/windows_app_instance.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final instance = Platform.isWindows ? WindowsAppInstance.acquire() : null;
  if (instance != null && instance.launch != InstanceLaunch.primary) exit(0);

  final database = ClipboardDatabase();
  await database.open();
  final repository = ClipboardRepository(database);
  final syncService = SyncService(repository, SecureCredentialService());
  final controller = AppController(
    repository,
    syncService,
    clipboard: Platform.isWindows
        ? WindowsClipboardService()
        : TextClipboardService(),
  );
  await controller.initialize();

  final desktopService = DesktopService(
    controller,
    onExit: () async {
      instance?.stopListening();
      controller.dispose();
      await database.close();
    },
  );
  await desktopService.initialize();

  runApp(
    IdreamlClipApp(controller: controller, desktopService: desktopService),
  );
  instance?.listen(
    onActivate: desktopService.showHistory,
    onShutdown: desktopService.exitApp,
  );
}
