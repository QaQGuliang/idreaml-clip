import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';

class DesktopService with TrayListener, WindowListener {
  DesktopService(this.controller);

  final AppController controller;
  bool _exiting = false;

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    const options = WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(900, 620),
      center: true,
      title: 'Idreaml Clip · 理梦剪藏',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFFF4F3F8),
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await hotKeyManager.unregisterAll();
    final quickHotKey = HotKey(
      key: PhysicalKeyboardKey.keyV,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(
        quickHotKey,
        keyDownHandler: (_) => showQuick(),
      );
    } catch (_) {
      // Another application may already own this shortcut.
    }

    launchAtStartup.setup(
      appName: 'Idreaml Clip',
      appPath: Platform.resolvedExecutable,
    );
    try {
      controller.setLaunchAtStartupState(await launchAtStartup.isEnabled());
    } catch (_) {
      controller.setLaunchAtStartupState(false);
    }

    trayManager.addListener(this);
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      await trayManager.setToolTip('Idreaml Clip · 理梦剪藏');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'quick', label: '打开快捷剪切板'),
            MenuItem(key: 'main', label: '打开管理页面'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出'),
          ],
        ),
      );
    } catch (_) {
      // Tray availability must never affect local clipboard capture.
    }
  }

  Future<void> showQuick() async {
    controller.enterQuickMode();
    await windowManager.setMinimumSize(const Size(460, 540));
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setSize(const Size(520, 640), animate: true);
    await windowManager.center(animate: true);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> showMain() async {
    controller.leaveQuickMode();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setSize(const Size(1180, 760), animate: true);
    await windowManager.setMinimumSize(const Size(900, 620));
    await windowManager.center(animate: true);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hide() => windowManager.hide();

  Future<void> setLaunchAtStartup(bool value) async {
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
    controller.setLaunchAtStartupState(value);
  }

  Future<void> exitApp() async {
    _exiting = true;
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onWindowClose() {
    if (!_exiting) hide();
  }

  @override
  void onTrayIconMouseDown() => showQuick();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'quick':
        showQuick();
        return;
      case 'main':
        showMain();
        return;
      case 'exit':
        exitApp();
        return;
    }
  }
}
