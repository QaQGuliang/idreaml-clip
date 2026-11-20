import 'dart:async';
// `Size` comes from dart:ui here; dart:ffi only provides the native types.
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../desk/desk_models.dart';
import '../models/clipboard_item.dart';
import '../models/quick_shortcut.dart';
import '../ui/desk_composer.dart';
import 'quick_panel_placement.dart';
import 'quick_preview_placement.dart';
import 'quick_paste_service.dart';
import 'windows_quick_paste_service.dart';
import 'shortcut_availability.dart' as shortcut_check;
import 'win_v_shortcut_service.dart';
import 'startup_service.dart';
import 'windows_folder_startup_service.dart';
import 'screenshot_service.dart';
import 'administrator_launch_service.dart';

/// DWMWA_NCRENDERING_POLICY with DWMNCRP_DISABLED/ENABLED (dwmapi.h, Vista+).
const _dwmwaNcRenderingPolicy = 2;
const _dwmncrpDisabled = 1;
const _dwmncrpEnabled = 2;

/// DWMWA_COLOR_NONE/DWMWA_COLOR_DEFAULT for [DWMWA_BORDER_COLOR].
const _dwmColorNone = 0xFFFFFFFE;
const _dwmColorDefault = 0xFFFFFFFF;

/// 快速新增窗口的逻辑尺寸：便签额外带可选标题，因此比待办略高。
Size deskComposerSize(DeskKind kind) =>
    Size(410, kind == DeskKind.note ? 496 : 414);

int _setDwmAttribute(int handle, int attribute, int value) {
  final data = calloc<Uint32>();
  try {
    data.value = value;
    return DwmSetWindowAttribute(handle, attribute, data, sizeOf<Uint32>());
  } finally {
    calloc.free(data);
  }
}

/// Removes the Windows window frame effects that would otherwise sit around the
/// quick panel.
///
/// The quick panel is the main window resized into a frameless popup, so DWM
/// keeps treating it as a normal caption window and still paints its non-client
/// frame: drop shadow, rounded corners, the 1px border and the frame band that
/// window_manager works around with 1px/8px insets for
/// `TitleBarStyle.hidden`. An image preview only paints the picture itself, so
/// that frame lands on the transparent area around it and reads as a light
/// frosted card. Disabling the non-client rendering, corners and border while
/// the window shows the quick panel leaves the picture on its own; the main
/// window restores the system defaults.
class QuickWindowFrame {
  QuickWindowFrame({
    int Function(int handle, int attribute, int value)? setAttribute,
  }) : _setAttribute = setAttribute ?? _setDwmAttribute;

  final int Function(int handle, int attribute, int value) _setAttribute;

  /// Quick panel: no non-client rendering, square corners, invisible border.
  void applyQuick(int handle) {
    _write(handle, _dwmwaNcRenderingPolicy, _dwmncrpDisabled);
    _write(handle, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND);
    _write(handle, DWMWA_BORDER_COLOR, _dwmColorNone);
  }

  /// Main window: system defaults.
  void applyMain(int handle) {
    _write(handle, _dwmwaNcRenderingPolicy, _dwmncrpEnabled);
    _write(handle, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DEFAULT);
    _write(handle, DWMWA_BORDER_COLOR, _dwmColorDefault);
  }

  void _write(int handle, int attribute, int value) {
    try {
      _setAttribute(handle, attribute, value);
    } catch (_) {
      // Windows 10 rejects the Windows 11 attributes; the frame effects simply
      // stay as they are, exactly as before this call existed.
    }
  }
}

class DesktopService with TrayListener, WindowListener {
  DesktopService(
    this.controller, {
    bool Function(QuickShortcut)? canRegisterShortcut,
    QuickPasteService? pasteService,
    WinVShortcutService? winVShortcut,
    StartupService? startupService,
    AdministratorLaunchService? administrator,
    QuickWindowFrame? windowFrame,
    this.screenshotService,
    this.onExit,
  }) : administrator =
           administrator ?? AdministratorLaunchService(controller.repository),
       _canRegisterShortcut =
           canRegisterShortcut ?? shortcut_check.canRegisterShortcut,
       _winVShortcut = winVShortcut ?? WindowsWinVShortcutService(),
       _windowFrame = windowFrame ?? QuickWindowFrame(),
       _startupService =
           startupService ??
           (Platform.isWindows
               ? WindowsFolderStartupService()
               : PlatformStartupService()),
       _pasteService =
           pasteService ??
           (Platform.isWindows
               ? WindowsQuickPasteService()
               : const CopyOnlyPasteService());

  final AppController controller;
  final AdministratorLaunchService administrator;
  final ScreenshotService? screenshotService;
  late final screenshots = screenshotService ?? ScreenshotService(controller);
  final Future<void> Function()? onExit;
  Future<void>? _exitFuture;
  final bool Function(QuickShortcut) _canRegisterShortcut;
  final QuickPasteService _pasteService;
  final WinVShortcutService _winVShortcut;
  final QuickWindowFrame _windowFrame;
  final StartupService _startupService;
  bool _startupReady = false;
  int _startupRevision = 0;
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

  /// 快捷面板与快速新增共用同一套浮层窗口样式，进入任一模式后只需配置一次。
  bool _popupWindowConfigured = false;
  bool _mainVisible = false;
  bool _composerVisible = false;
  bool _composerReturnMain = true;
  bool _composerRestore = true;
  bool _composerDismissing = false;
  int? _foregroundBeforeComposer;
  DeskComposerDismiss? _composerDismiss;
  bool get _quickVisible => quickVisibility.value;
  set _quickVisible(bool value) => quickVisibility.value = value;

  Future<void>? _windowReady;

  Future<void> prepareWindow() => _windowReady ??= _prepareWindow();

  Future<void> _prepareWindow() async {
    await windowManager.ensureInitialized();

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
    _mainVisible = true;
  }

  Future<void> initialize() async {
    await prepareWindow();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
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

    await screenshots.initialize();
    controller.desktopNotes?.openManager = (kind, id) async {
      await showHistory();
      controller.selectedDeskId = id;
      controller.deskViewRequest++;
      controller.setPage(kind == DeskKind.note ? AppPage.notes : AppPage.todos);
    };
    await controller.desktopNotes?.attachNative();
    controller.desktopNotes?.openComposer = (kind, {hotkey = false}) =>
        showComposer(kind, hotkey: hotkey);
    await administrator.initialize(requestRestart: false);
    _publishAdministrator();
    try {
      final state = await _startupService.initialize();
      controller.setLaunchAtStartupState(state.enabled, message: state.message);
    } catch (error) {
      controller.setLaunchAtStartupState(false, message: _startupError(error));
    }
    _startupReady = true;

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
    if (_changingMode || _exiting || screenshots.active || _recordingShortcut) {
      return;
    }
    if (controller.composerMode || _composerVisible) {
      await _dismissComposer(restore: false);
    }
    if (_changingMode) return;
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
      final (cursor, displays) = await (
        screenRetriever.getCursorScreenPoint(),
        _getDisplays(),
      ).wait;
      final pointer = cursor * initialScale;
      final areas = displays.map(_workArea).toList();
      final area = nearestWorkArea(pointer, areas);
      final targetScale = _displayScale(displays[areas.indexOf(area)]);
      final bounds = placeQuickPanel(
        pointer: pointer,
        workAreas: [area],
        scale: targetScale,
      );
      if (!_popupWindowConfigured) {
        await windowManager.hide();
        if (await windowManager.isMinimized()) await windowManager.restore();
        if (await windowManager.isMaximized()) await windowManager.unmaximize();
      }
      await controller.enterQuickMode();
      await windowManager.setMinimumSize(Size.zero);
      await _configurePopupWindow();
      await windowManager.setBounds(_toWindowCoordinates(bounds));
      await windowManager.show();
      _mainVisible = false;
      if (initialScale != targetScale) {
        // Windows may adjust the bounds when changing DPI. A suspended
        // renderer must not hold the window transition lock indefinitely.
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {},
        );
        await windowManager.setBounds(_toWindowCoordinates(bounds));
      }
      await windowManager.setMinimumSize(_toWindowCoordinates(bounds).size);
      await windowManager.focus();
      _quickVisible = true;
    } finally {
      _changingMode = false;
    }
  }

  double get _windowCoordinateScale =>
      Platform.isWindows ? windowManager.getDevicePixelRatio() : 1;

  Future<List<Display>> _getDisplays() async {
    final displays = await screenRetriever.getAllDisplays();
    return displays.isEmpty
        ? [await screenRetriever.getPrimaryDisplay()]
        : displays;
  }

  double _displayScale(Display display) =>
      Platform.isWindows ? (display.scaleFactor ?? 1).toDouble() : 1;

  Rect _workArea(Display display) {
    final scale = _displayScale(display);
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(
      (display.visiblePosition?.dx ?? 0) * scale,
      (display.visiblePosition?.dy ?? 0) * scale,
      size.width * scale,
      size.height * scale,
    );
  }

  Rect _toWindowCoordinates(Rect bounds) {
    final scale = _windowCoordinateScale;
    return Rect.fromLTWH(
      bounds.left / scale,
      bounds.top / scale,
      bounds.width / scale,
      bounds.height / scale,
    );
  }

  /// 打开快速新增浮层：复用同一 Flutter 窗口，居中显示在便签/待办轨道所在
  /// 显示器，结束后回到进入前的窗口状态（可见的主窗口或托盘隐藏）。
  Future<void> showComposer(DeskKind kind, {bool hotkey = false}) async {
    if (_changingMode || _exiting || screenshots.active || _recordingShortcut) {
      return;
    }
    if (_composerVisible || controller.composerMode) return;
    // 快捷面板仍显示时不叠加第二个浮层；面板已收起（如快捷面板的新建按钮）
    // 则继续打开快速新增，并结束快捷面板的会话状态。
    if (_quickVisible) return;
    final notes = controller.desktopNotes;
    if (notes == null || !notes.enabled(kind)) return;
    _changingMode = true;
    _composerDismiss = null;
    try {
      final draft = await notes.draft(kind);
      final display = _composerDisplay(
        await _getDisplays(),
        notes.config(kind),
      );
      final scale = _displayScale(display);
      final area = _workArea(display);
      final logical = deskComposerSize(kind);
      final width = math.min(logical.width, area.width / scale);
      final height = math.min(logical.height, area.height / scale);
      final bounds = Rect.fromLTWH(
        area.left + (area.width - width * scale) / 2,
        area.top + (area.height - height * scale) / 2,
        width * scale,
        height * scale,
      );
      _composerReturnMain = _mainVisible;
      _foregroundBeforeComposer = Platform.isWindows
          ? await _foregroundOtherThanSelf()
          : null;
      _quickEpoch++;
      _quickPasteTarget = null;
      _quickVisible = false;
      if (controller.quickMode) controller.leaveQuickMode();
      // Read the current scale before the window leaves the main monitor.
      final initialScale = _windowCoordinateScale;
      await windowManager.hide();
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      await windowManager.setMinimumSize(Size.zero);
      await _configurePopupWindow();
      await windowManager.setBounds(_toWindowCoordinates(bounds));
      // 与 Flutter 管理页编辑一致：编辑期间本进程复制的内容不进入历史。
      // 该通道失败不应阻断快速新增本身。
      try {
        await notes.editing(true);
      } catch (_) {}
      controller.enterComposerMode(kind, hotkey: hotkey, draft: draft);
      await windowManager.show();
      if (initialScale != scale) {
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {},
        );
        await windowManager.setBounds(_toWindowCoordinates(bounds));
      }
      await windowManager.setMinimumSize(_toWindowCoordinates(bounds).size);
      await windowManager.focus();
      _composerVisible = true;
    } finally {
      _changingMode = false;
    }
  }

  /// 快速新增页面完成草稿处理后调用：隐藏浮层并回到进入前的窗口状态。
  Future<void> finishComposer(DeskComposerResult result) async {
    if (!_composerVisible) return;
    _composerVisible = false;
    _composerDismiss = null;
    _changingMode = true;
    try {
      await windowManager.hide();
      controller.leaveComposerMode();
      try {
        await controller.desktopNotes?.editing(false);
      } catch (_) {}
      if (_exiting || !_composerRestore) return;
      if (_composerReturnMain) {
        await _applyMainWindow();
      } else {
        _restoreForegroundBeforeComposer();
      }
    } finally {
      _composerRestore = true;
      _changingMode = false;
    }
  }

  /// 页面把「失焦/系统关闭时保存草稿并退出」的入口交给窗口模式。
  void attachComposerDismiss(DeskComposerDismiss? dismiss) {
    _composerDismiss = dismiss;
  }

  Future<void> _dismissComposer({required bool restore}) async {
    if (_composerDismissing) return;
    _composerDismissing = true;
    _composerRestore = restore;
    try {
      final dismiss = _composerDismiss;
      if (dismiss != null) {
        await dismiss(clearDraft: false);
      } else if (_composerVisible) {
        await finishComposer(DeskComposerResult.dismissed);
      }
    } finally {
      _composerDismissing = false;
      if (_composerVisible) _composerRestore = true;
    }
  }

  /// 浮层样式与快捷面板一致：无边框、置顶、跳过任务栏、透明底色。
  Future<void> _configurePopupWindow() async {
    if (!_popupWindowConfigured) {
      await windowManager.setResizable(false);
      if (Platform.isWindows) {
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(true);
      }
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      _popupWindowConfigured = true;
    }
    // Declared on every wake: the main window uses an opaque light backdrop,
    // and a leftover one turns the area an expanded image preview leaves
    // empty into a light block.
    await windowManager.setBackgroundColor(const Color(0x00000000));
    if (Platform.isWindows) {
      // Windows still frames this window as a caption window, so the picture
      // preview would sit inside that shadow, border and rounded corners.
      _windowFrame.applyQuick(await windowManager.getId());
    }
  }

  Display _composerDisplay(List<Display> displays, DeskSettings settings) {
    final wanted = settings.monitor;
    if (wanted.isNotEmpty) {
      for (final display in displays) {
        if (display.id == wanted || display.name == wanted) return display;
      }
    }
    return displays.first;
  }

  /// 记录进入快速新增前的前台窗口；本应用自己的窗口不作为恢复目标。
  Future<int?> _foregroundOtherThanSelf() async {
    try {
      final foreground = GetForegroundWindow();
      if (foreground == 0 || foreground == await windowManager.getId()) {
        return null;
      }
      return foreground;
    } catch (_) {
      return null;
    }
  }

  void _restoreForegroundBeforeComposer() {
    final handle = _foregroundBeforeComposer;
    _foregroundBeforeComposer = null;
    if (!Platform.isWindows || handle == null || handle == 0) return;
    try {
      // 主窗口不在屏幕上时回到此前的前台应用，而不是弹出主窗口。
      if (GetForegroundWindow() != handle) SetForegroundWindow(handle);
    } catch (_) {
      // Windows 可能拒绝跨进程恢复前台，焦点会留在系统默认窗口。
    }
  }

  Future<void> showMain() async {
    if (_changingMode || _exiting) return;
    if (controller.composerMode || _composerVisible) {
      await _dismissComposer(restore: false);
    }
    if (_changingMode) return;
    _changingMode = true;
    try {
      await _applyMainWindow();
    } finally {
      _changingMode = false;
    }
  }

  Future<void> _applyMainWindow() async {
    _popupWindowConfigured = false;
    _quickEpoch++;
    _quickPasteTarget = null;
    _quickVisible = false;
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
    if (Platform.isWindows) {
      // Restore the system frame the quick panel switched off.
      _windowFrame.applyMain(await windowManager.getId());
    }
    await windowManager.setSize(const Size(1180, 760));
    await windowManager.setMinimumSize(const Size(900, 620));
    await windowManager.center();
    controller.leaveQuickMode();
    await windowManager.show();
    await windowManager.focus();
    _mainVisible = true;
  }

  Future<void> hide() async {
    _quickEpoch++;
    _quickPasteTarget = null;
    _quickVisible = false;
    _mainVisible = false;
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

  Future<void> pinHistoryImage(ClipboardItem item) async {
    final payload = await controller.repository.readPayload(item);
    if (!payload.isImage) throw StateError('只有图片记录可以贴图');
    await screenshots.pinHistoryImage(payload.imageBytes);
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
        final areas = (await _getDisplays()).map(_workArea).toList();
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

  /// 点击待办提醒后聚焦主窗口并打开待办管理页；模块关闭时只聚焦主窗口。
  Future<void> showTodoReminders() async {
    await showHistory();
    if (controller.desktopNotes?.enabled(DeskKind.todo) != true) return;
    await controller.setPage(AppPage.todos);
  }

  Future<void> setLaunchAtStartup(bool value) async {
    if (controller.launchAtStartupChanging) return;
    _startupRevision++;
    controller.setLaunchAtStartupChanging(true);
    try {
      final state = await _startupService.setEnabled(value);
      controller.setLaunchAtStartupState(state.enabled, message: state.message);
    } catch (error) {
      var enabled = false;
      try {
        enabled = (await _startupService.read()).enabled;
      } catch (_) {
        // Do not display success when the actual registration cannot be read.
      }
      final message = _startupError(error);
      controller.setLaunchAtStartupState(enabled, message: message);
      throw StartupException(message);
    } finally {
      controller.setLaunchAtStartupChanging(false);
    }
  }

  String _startupError(Object error) =>
      error is StartupException ? error.message : '无法读取或保存开机启动设置，请重试。';

  Future<void> refreshStartupState() async {
    if (!_startupReady || _exiting || controller.launchAtStartupChanging) {
      return;
    }
    final revision = ++_startupRevision;
    try {
      final state = await _startupService.read();
      if (!_exiting && revision == _startupRevision) {
        controller.setLaunchAtStartupState(
          state.enabled,
          message: state.message,
        );
      }
    } catch (error) {
      if (!_exiting && revision == _startupRevision) {
        controller.setLaunchAtStartupState(
          false,
          message: _startupError(error),
        );
      }
    }
  }

  Future<String?> updateQuickShortcut(QuickShortcut shortcut) async {
    if (controller.reservesDesktopShortcut(shortcut)) return 'F3 已用于便签和待办';
    if (screenshots.supported &&
        shortcut.sameCombination(controller.screenshotShortcut)) {
      return '该组合已用于截图';
    }
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

  Future<String?> beginShortcutRecording({bool screenshot = false}) async {
    if (usesWinV && !screenshot) return '请先关闭固定 Win + V 快捷键';
    if (controller.shortcutModeChanging) return '正在切换快捷键，请稍候';
    if (_recordingShortcut || _savingShortcut) return '正在编辑快捷键，请稍候';
    _recordingShortcut = true;
    final registered = _registeredShortcut;
    try {
      await screenshots.suspendShortcut();
      await controller.desktopNotes?.suspend(true);
      if (registered != null) {
        await hotKeyManager.unregister(registered);
        _suspendedShortcut = registered;
        _registeredShortcut = null;
      }
      return null;
    } catch (_) {
      _recordingShortcut = false;
      await screenshots.resumeShortcut();
      await controller.desktopNotes?.suspend(false);
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
      await screenshots.resumeShortcut();
      await controller.desktopNotes?.suspend(false);
    }
  }

  Future<void> exitApp() => _exitFuture ??= _exitApp();

  /// Relaunches with the same data locator. The child waits for this process
  /// so the single-instance lock and native resources are released first.
  Future<void> restartApplication() async {
    await Process.start(Platform.resolvedExecutable, [
      '--administrator-parent-pid=$pid',
    ], mode: ProcessStartMode.detached);
    await exitApp();
  }

  void _publishAdministrator({bool changing = false}) =>
      controller.setAdministratorState(
        enabled: administrator.enabled,
        elevated: administrator.elevated,
        message: administrator.message,
        changing: changing,
      );

  Future<String?> setRunAsAdministratorEnabled(bool value) async {
    if (_exiting ||
        controller.administratorChanging ||
        controller.storageChanging) {
      return '正在处理其他操作，请稍候。';
    }
    _publishAdministrator(changing: true);
    try {
      final restart = await administrator.setEnabled(value);
      _publishAdministrator(changing: restart);
      if (restart) await exitApp();
      return administrator.message;
    } catch (_) {
      _publishAdministrator();
      return administrator.message ?? '无法更改管理员启动设置，请重试。';
    } finally {
      if (!_exiting) _publishAdministrator();
    }
  }

  Future<void> _exitApp() async {
    if (controller.composerMode) await _dismissComposer(restore: false);
    _exiting = true;
    _quickVisible = false;
    _quickPasteTarget = null;
    // A failed tray/hotkey plugin must not prevent exit or an uninstall.
    for (final cleanup in <Future<void> Function()>[
      screenshots.dispose,
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
    if (_exiting) return;
    if (controller.composerMode) {
      // 系统关闭等同于关闭按钮：保留草稿后回到进入前的窗口。
      unawaited(_dismissComposer(restore: true));
      return;
    }
    hide();
  }

  @override
  void onWindowFocus() {
    if (!controller.quickMode) unawaited(refreshStartupState());
  }

  @override
  void onWindowBlur() {
    if (_changingMode || screenshots.active) return;
    if (controller.composerMode) {
      // 离开快速新增保留草稿，与原生窗口的失焦语义一致。
      if (_composerVisible) unawaited(_dismissComposer(restore: true));
      return;
    }
    if (controller.quickMode && _quickVisible) unawaited(hide());
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
