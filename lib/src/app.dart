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
    title: 'Idreaml Clip · 理梦剪藏',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: controller.quickMode
            ? QuickPanel(
                key: const ValueKey('quick-panel'),
                controller: controller,
                desktopService: desktopService,
              )
            : MainShell(
                key: const ValueKey('main-shell'),
                controller: controller,
                desktopService: desktopService,
              ),
      ),
    ),
  );
}
