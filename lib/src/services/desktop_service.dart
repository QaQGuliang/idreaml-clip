import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../models/quick_shortcut.dart';
import 'quick_panel_placement.dart';
import 'quick_preview_placement.dart';
import 'quick_paste_service.dart';
import 'windows_quick_paste_service.dart';
import 'shortcut_availability.dart' as shortcut_check;
import 'win_v_shortcut_service.dart';

class DesktopService with TrayListener, WindowListener {
  DesktopService(
    this.controller, {
    bool Function(QuickShortcut)? canRegisterShortcut,
    QuickPasteService? pasteService,
    WinVShortcutService? winVShortcut,
    this.onExit,
  }) : _canRegisterShortcut =
           canRegisterShortcut ?? shortcut_check.canRegisterShortcut,
       _winVShortcut = winVShortcut ?? WindowsWinVShortcutService(),
       _pasteService =
           pasteService ??
           (Platform.isWindows
               ? WindowsQuickPasteService()
               : const CopyOnlyPasteService());

  final AppController controller;
  final Future<void> Function()? onExit;
  Future<void>? _exitFuture;
  final bool Function(QuickShortcut) _canRegisterShortcut;
  final QuickPasteService _pasteService;
  final WinVShortcutService _winVShortcut;
  bool _winVActive = false;
  bool get supportsWinV => _winVShortcut.isSupported;
  bool get usesWinV => supportsWinV && controller.winVShortcutEnabled;
  QuickPasteTarget? _quickPasteTarget;
  final quickVisibility = ValueNotifier<bool>(false);
  QuickPreviewPlacement? _previewPlacement;
  Future<void>? _previewTransition;
  int _quickEpoch = 0;
  bool _trayMenuOpen = false;
  HotKey? _registeredShortcut;
  HotKey? _suspendedShortcut;
  bool _recordingShortcut = false;
  bool _savingShortcut = false;
  bool _exiting = false;
  bool _changingMode = false;
  bool get _quickVisible => quickVisibility.value;
  set _quickVisible(bool value) => quickVisibility.value = value;

  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    const options = WindowOptions(
      size: Size(1180, 760),
      minimumSize: Size(900, 620),
      center: true,
      title: 'Idreaml Clip',
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0xFFF4F3F8),
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await hotKeyManager.unregisterAll();
    try {
      if (usesWinV) {
        await _startWinV();
      } else {
        if (!_canRegisterShortcut(controller.quickShortcut)) {
          throw StateError('unavailable');
        }
        final quickHotKey = controller.quickShortcut.toHotKey();
        await hotKeyManager.register(
          quickHotKey,
          keyDownHandler: _onQuickHotKey,
        );
        _registeredShortcut = quickHotKey;
      }
      controller.setShortcutError(null);
    } catch (_) {
      controller.setShortcutError(
        usesWinV ? 'Win + V 启用失败，请关闭开关后重试' : '快捷键注册失败，可能已被占用，请在设置中更换',
      );
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
      await trayManager.setToolTip('Idreaml Clip');
      await trayManager.setContextMenu(
        Menu(
          items: [MenuItem(key: 'exit', label: '退出应用程序')],
        ),
      );
    } catch (_) {
      // Tray availability must never affect local clipboard capture.
    }
  }

  Future<void> showQuick() async {
    if (_changingMode || _exiting) return;
    _changingMode = true;
    final previousTarget = _quickVisible ? _quickPasteTarget : null;
    _quickEpoch++;
    _quickVisible = false;
    try {
      _quickPasteTarget = await _pasteService.captureTarget() ?? previousTarget;
      if (_previewTransition != null) await _previewTransition;
      _previewPlacement = null;
      // Read the pointer before activating or moving our own window.
      final initialScale = _windowCoordinateScale;
      final pointer =
          await screenRetriever.getCursorScreenPoint() * initialScale;
      var displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) {
        displays = [await screenRetriever.getPrimaryDisplay()];
      }
      // Windows reports each display using its own DPI, while the pointer uses
      // our window's DPI. Compare all coordinates in physical pixels there.
      final workAreas = displays.map((display) {
        final scale = Platform.isWindows
            ? (display.scaleFactor ?? 1).toDouble()
            : 1.0;
        return Rect.fromLTWH(
          (display.visiblePosition?.dx ?? 0) * scale,
          (display.visiblePosition?.dy ?? 0) * scale,
          (display.visibleSize ?? display.size).width * scale,
          (display.visibleSize ?? display.size).height * scale,
        );
      }).toList();
      final area = nearestWorkArea(pointer, workAreas);
      final display = displays[workAreas.indexOf(area)];
      final bounds = placeQuickPanel(
        pointer: pointer,
        workAreas: [area],
        scale: Platform.isWindows ? (display.scaleFactor ?? 1).toDouble() : 1,
      );
      await windowManager.hide();
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      await controller.enterQuickMode();
      await windowManager.setMinimumSize(Size.zero);
      await windowManager.setResizable(false);
      if (Platform.isWindows) {
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(false);
      }
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setBackgroundColor(const Color(0x00000000));
      await windowManager.setBounds(_toWindowCoordinates(bounds));
      await windowManager.show();
      // Moving between monitors can change the window's DPI. Reapply after
      // Flutter receives the new metrics, then enforce the final minimum size.
      await WidgetsBinding.instance.endOfFrame;
      final finalBounds = _toWindowCoordinates(bounds);
      await windowManager.setBounds(finalBounds);
      await windowManager.setMinimumSize(finalBounds.size);
      await windowManager.focus();
      _quickVisible = true;
    } finally {
      _changingMode = false;
    }
  }

  double get _windowCoordinateScale =>
      Platform.isWindows ? windowManager.getDevicePixelRatio() : 1;

  Rect _toWindowCoordinates(Rect bounds) {
    final scale = _windowCoordinateScale;
    return Rect.fromLTWH(
      bounds.left / scale,
      bounds.top / scale,
      bounds.width / scale,
      bounds.height / scale,
    );
  }

  Future<void> showMain() async {
    if (_changingMode || _exiting) return;
    _changingMode = true;
    _quickEpoch++;
    _quickPasteTarget = null;
    _quickVisible = false;
    try {
      if (_previewTransition != null) await _previewTransition;
      _previewPlacement = null;
      await windowManager.hide();
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setResizable(true);
      if (Platform.isWindows) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      }
      await windowManager.setBackgroundColor(const Color(0xFFF4F3F8));
      await windowManager.setSize(const Size(1180, 760));
      await windowManager.setMinimumSize(const Size(900, 620));
      await windowManager.center();
      controller.leaveQuickMode();
      await windowManager.show();
      await windowManager.focus();
    } finally {
      _changingMode = false;
    }
  }

  Future<void> hide() async {
    _quickEpoch++;
    _quickPasteTarget = null;
    _quickVisible = false;
    await windowManager.hide();
  }

  Future<void> completeQuickUse({bool paste = true}) async {
    final target = _quickVisible ? _quickPasteTarget : null;
    final sequence = controller.copiedClipboardSequence;
    await hide();
    if (paste && target != null) {
      try {
        await target.paste(clipboardSequence: sequence);
      } catch (_) {
        // The clipboard remains usable if the target app rejects input.
      }
    }
  }

  Future<T> _withPreviewTransition<T>(Future<T> Function() action) {
    final result = _previewTransition?.then((_) => action()) ?? action();
    _previewTransition = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  /// Read the physical cursor again after a resize. Flutter's cached pointer
  /// location can still be relative to the window's previous screen position.
  Future<Offset?> getQuickPointerPosition() async {
    if (!_quickVisible || !controller.quickMode || _changingMode) return null;
    final epoch = _quickEpoch;
    final scale = _windowCoordinateScale;
    final pointer = await screenRetriever.getCursorScreenPoint() * scale;
    final bounds = await windowManager.getBounds();
    if (!_quickVisible || epoch != _quickEpoch) return null;
    return pointer / _windowCoordinateScale - bounds.topLeft;
  }

  Future<QuickPreviewPlacement?> expandQuickPreview({Size? imageSize}) =>
      _withPreviewTransition(() async {
        if (!_quickVisible || !controller.quickMode || _changingMode) {
          return null;
        }
        final epoch = _quickEpoch;
        final scale = _windowCoordinateScale;
        final current = await windowManager.getBounds();
        final original =
            _previewPlacement?.panelLocal.shift(current.topLeft) ?? current;
        final panel = Rect.fromLTWH(
          original.left * scale,
          original.top * scale,
          original.width * scale,
          original.height * scale,
        );
        var displays = await screenRetriever.getAllDisplays();
        if (displays.isEmpty) {
          displays = [await screenRetriever.getPrimaryDisplay()];
        }
        final areas = displays.map((display) {
          final dpi = Platform.isWindows
              ? (display.scaleFactor ?? 1).toDouble()
              : 1.0;
          return Rect.fromLTWH(
            (display.visiblePosition?.dx ?? 0) * dpi,
            (display.visiblePosition?.dy ?? 0) * dpi,
            (display.visibleSize ?? display.size).width * dpi,
            (display.visibleSize ?? display.size).height * dpi,
          );
        }).toList();
        final placement = placeQuickPreview(
          panel: panel,
          workArea: nearestWorkArea(panel.center, areas),
          scale: scale,
          imageSize: imageSize,
        );
        if (!_quickVisible || epoch != _quickEpoch) return null;
        final target = _toWindowCoordinates(placement.windowBounds);
        if (target != current) {
          await windowManager.setMinimumSize(Size.zero);
          if (!_quickVisible || epoch != _quickEpoch) return null;
          await windowManager.setBounds(target);
        }
        if (!_quickVisible || epoch != _quickEpoch) return null;
        _previewPlacement = placement;
        return placement;
      });

  Future<void> collapseQuickPreview() => _withPreviewTransition(() async {
    final placement = _previewPlacement;
    _previewPlacement = null;
    if (placement == null ||
        !_quickVisible ||
        !controller.quickMode ||
        _changingMode) {
      return;
    }
    final epoch = _quickEpoch;
    final current = await windowManager.getBounds();
    // Preserve the panel's screen position even after dragging the expanded window.
    final panel = placement.panelLocal.shift(current.topLeft);
    if (!_quickVisible || epoch != _quickEpoch) return;
    await windowManager.setMinimumSize(Size.zero);
    if (!_quickVisible || epoch != _quickEpoch) return;
    await windowManager.setBounds(panel);
    if (_quickVisible && epoch == _quickEpoch) {
      await windowManager.setMinimumSize(panel.size);
    }
  });

  Future<void> showHistory() async {
    controller.historySearch = '';
    await controller.setPage(AppPage.history);
    await showMain();
  }

  Future<void> setLaunchAtStartup(bool value) async {
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
    controller.setLaunchAtStartupState(value);
  }

  Future<String?> updateQuickShortcut(QuickShortcut shortcut) async {
    if (usesWinV) return '请先关闭固定 Win + V 快捷键';
    if (controller.shortcutModeChanging) return '正在切换快捷键，请稍候';
    if (_savingShortcut) return '正在保存快捷键，请稍候';
    if (!shortcut.isValid) return '系统不支持这个按键组合，请重新录入';
    if (_registeredShortcut != null &&
        shortcut.sameCombination(controller.quickShortcut)) {
      return null;
    }
    _savingShortcut = true;
    HotKey? replacement;
    var registered = false;
    try {
      if (!_canRegisterShortcut(shortcut)) return '该快捷键已被占用或被系统保留，请换一个组合';
      replacement = shortcut.toHotKey();
      await hotKeyManager.register(replacement, keyDownHandler: _onQuickHotKey);
      registered = true;
      await controller.saveQuickShortcut(shortcut);
      final previous = _registeredShortcut;
      _registeredShortcut = replacement;
      replacement = null;
      if (previous != null) {
        try {
          await hotKeyManager.unregister(previous);
        } catch (_) {
          controller.setShortcutError('新快捷键已生效，旧快捷键将在重启后释放');
        }
      }
      return null;
    } catch (_) {
      if (registered && replacement != null) {
        try {
          await hotKeyManager.unregister(replacement);
        } catch (_) {
          /* The previous shortcut remains active. */
        }
      }
      return '快捷键保存失败，请重试或选择其他组合';
    } finally {
      _savingShortcut = false;
    }
  }

  void _onQuickHotKey(HotKey shortcut) {
    if (!_exiting &&
        !usesWinV &&
        !controller.shortcutModeChanging &&
        !_recordingShortcut &&
        shortcut.identifier == _registeredShortcut?.identifier) {
      unawaited(showQuick());
    }
  }

  Future<String?> beginShortcutRecording() async {
    if (usesWinV) return '请先关闭固定 Win + V 快捷键';
    if (controller.shortcutModeChanging) return '正在切换快捷键，请稍候';
    if (_recordingShortcut || _savingShortcut) return '正在编辑快捷键，请稍候';
    _recordingShortcut = true;
    final registered = _registeredShortcut;
    try {
      if (registered != null) {
        await hotKeyManager.unregister(registered);
        _suspendedShortcut = registered;
        _registeredShortcut = null;
      }
      return null;
    } catch (_) {
      _recordingShortcut = false;
      return '无法开始录入快捷键，请重试';
    }
  }

  Future<void> endShortcutRecording() async {
    if (!_recordingShortcut) return;
    final previous = _suspendedShortcut;
    try {
      if (_registeredShortcut == null &&
          previous != null &&
          !_exiting &&
          !usesWinV) {
        if (!_canRegisterShortcut(controller.quickShortcut)) {
          throw StateError('unavailable');
        }
        await hotKeyManager.register(previous, keyDownHandler: _onQuickHotKey);
        _registeredShortcut = previous;
        controller.setShortcutError(null);
      }
    } catch (_) {
      controller.setShortcutError('原快捷键恢复失败，请重新设置快捷键');
    } finally {
      _suspendedShortcut = null;
      _recordingShortcut = false;
    }
  }

  Future<void> exitApp() => _exitFuture ??= _exitApp();

  Future<void> _exitApp() async {
    _exiting = true;
    _quickVisible = false;
    _quickPasteTarget = null;
    // A failed tray/hotkey plugin must not prevent exit or an uninstall.
    for (final cleanup in <Future<void> Function()>[
      _stopWinV,
      hotKeyManager.unregisterAll,
      trayManager.destroy,
      ?onExit,
    ]) {
      try {
        await cleanup().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Native process teardown also releases hooks and kernel handles.
      }
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<void> _startWinV() async {
    await _winVShortcut.start(
      () {
        if (_winVActive &&
            usesWinV &&
            !_exiting &&
            !controller.shortcutModeChanging) {
          unawaited(showQuick());
        }
      },
      () {
        _winVActive = false;
        if (!_exiting) controller.setShortcutError('Win + V 已停止响应，请关闭开关后重试');
      },
    );
    _winVActive = true;
  }

  Future<void> _stopWinV() async {
    await _winVShortcut.stop();
    _winVActive = false;
  }

  Future<String?> setWinVShortcutEnabled(bool enabled) async {
    if (!supportsWinV) return '固定 Win + V 仅适用于 Windows';
    if (_exiting ||
        controller.shortcutModeChanging ||
        _savingShortcut ||
        _recordingShortcut) {
      return '正在编辑快捷键，请稍候';
    }
    if (enabled == usesWinV && (!enabled || _winVActive)) return null;
    controller.setShortcutModeChanging(true);
    final previous = _registeredShortcut;
    HotKey? replacement;
    try {
      if (enabled) {
        await _startWinV();
        if (previous != null) {
          await hotKeyManager.unregister(previous);
          _registeredShortcut = null;
        }
      } else {
        if (!_canRegisterShortcut(controller.quickShortcut)) {
          return '原自定义快捷键已被占用，Win + V 保持启用，请释放该组合后重试';
        }
        replacement = controller.quickShortcut.toHotKey();
        await hotKeyManager.register(
          replacement,
          keyDownHandler: _onQuickHotKey,
        );
        _registeredShortcut = replacement;
        await _stopWinV();
      }
      await controller.saveWinVShortcutEnabled(enabled);
      return null;
    } catch (_) {
      // Persist only after both registrations have switched. A failed write or
      // native operation restores the old mode and leaves its saved chord intact.
      var restored = true;
      if (enabled) {
        try {
          await _stopWinV();
          if (_registeredShortcut == null && previous != null) {
            if (!_canRegisterShortcut(controller.quickShortcut)) {
              throw StateError('unavailable');
            }
            await hotKeyManager.register(
              previous,
              keyDownHandler: _onQuickHotKey,
            );
            _registeredShortcut = previous;
          }
        } catch (_) {
          restored = false;
        }
      } else {
        try {
          if (replacement != null) await hotKeyManager.unregister(replacement);
          _registeredShortcut = null;
          if (!_winVActive) await _startWinV();
        } catch (_) {
          restored = false;
        }
      }
      final error = restored
          ? '快捷键模式切换失败，已保留原设置，请重试'
          : '快捷键模式切换失败，原快捷键恢复失败，请重启应用后重试';
      controller.setShortcutError(error);
      return error;
    } finally {
      controller.setShortcutModeChanging(false);
    }
  }

  @override
  void onWindowClose() {
    if (!_exiting) hide();
  }

  @override
  void onWindowBlur() {
    if (controller.quickMode && _quickVisible && !_changingMode) {
      unawaited(hide());
    }
  }

  @override
  void onTrayIconMouseDown() => showHistory();

  @override
  void onTrayIconRightMouseDown() => unawaited(_showTrayMenu());

  Future<void> _showTrayMenu() async {
    if (_trayMenuOpen) return;
    _trayMenuOpen = true;
    try {
      await trayManager.popUpContextMenu(
        // Windows needs a foreground menu owner to dismiss on an outside click.
        // ignore: deprecated_member_use
        bringAppToFront: Platform.isWindows,
      );
    } finally {
      if (Platform.isWindows) finishWindowsTrayMenu();
      _trayMenuOpen = false;
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'exit':
        exitApp();
        return;
    }
  }
}
