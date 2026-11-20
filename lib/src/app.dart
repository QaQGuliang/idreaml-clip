import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'services/desktop_service.dart';
import 'ui/app_theme.dart';
import 'ui/desk_composer.dart';
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
      builder: (context, _) {
        final notes = controller.desktopNotes;
        final composerKind = controller.composerKind;
        if (composerKind != null && notes != null) {
          return DeskComposer(
            key: ValueKey('desk-composer-${controller.composerSession}'),
            notes: notes,
            kind: composerKind,
            draft: controller.composerDraft,
            onFinish: desktopService.finishComposer,
            onDismissReady: desktopService.attachComposerDismiss,
          );
        }
        return controller.quickMode
            ? QuickPanel(
                key: ValueKey('quick-panel-${controller.quickSession}'),
                controller: controller,
                desktopService: desktopService,
              )
            : MainShell(
                key: const ValueKey('main-shell'),
                controller: controller,
                desktopService: desktopService,
              );
      },
    ),
  );
}
