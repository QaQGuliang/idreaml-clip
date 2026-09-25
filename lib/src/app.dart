import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'services/desktop_service.dart';
import 'ui/app_theme.dart';
import 'ui/main_shell.dart';
import 'ui/quick_panel.dart';

class IdreamlClipApp extends StatelessWidget {
  const IdreamlClipApp({
    super.key,
    required this.controller,
    required this.desktopService,
  });

  final AppController controller;
  final DesktopService desktopService;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Idreaml Clip',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => controller.quickMode
          ? QuickPanel(
              key: ValueKey('quick-panel-${controller.quickSession}'),
              controller: controller,
              desktopService: desktopService,
            )
          : MainShell(
              key: const ValueKey('main-shell'),
              controller: controller,
              desktopService: desktopService,
            ),
    ),
  );
}
