import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/data/clipboard_database.dart';
import 'src/data/clipboard_repository.dart';
import 'src/services/desktop_service.dart';
import 'src/services/credential_service.dart';
import 'src/services/sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = ClipboardDatabase();
  await database.open();
  final repository = ClipboardRepository(database);
  final syncService = SyncService(repository, SecureCredentialService());
  final controller = AppController(repository, syncService);
  await controller.initialize();

  final desktopService = DesktopService(controller);
  await desktopService.initialize();

  runApp(
    IdreamlClipApp(controller: controller, desktopService: desktopService),
  );
}
