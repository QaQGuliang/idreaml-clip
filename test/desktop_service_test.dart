import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/services/desktop_service.dart';
import 'package:idreaml_clip/src/services/quick_paste_service.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'support/clipboard_test_support.dart';
import 'support/fake_win_v_shortcut.dart';

// The plugin is a singleton; test bindings reset native event-channel handlers
// between tests. Keep its event source alive while still mocking registration.
class _HotKeyPlatform extends MethodChannelHotKeyManager {
  final events = StreamController<Map<Object?, Object?>>.broadcast();
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => events.stream;
}

class _PasteTarget implements QuickPasteTarget {
  int calls = 0;
  int? sequence;
  VoidCallback? onPaste;
  @override
  Future<bool> paste({int? clipboardSequence}) async {
    calls++;
    sequence = clipboardSequence;
    onPaste?.call();
    return true;
  }
}

class _PasteService implements QuickPasteService {
  _PasteTarget? target;
  VoidCallback? onCapture;
  @override
  Future<QuickPasteTarget?> captureTarget() async {
    onCapture?.call();
    return target;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const screenChannel = MethodChannel(
    'dev.leanflutter.plugins/screen_retriever',
  );
  const trayChannel = MethodChannel('tray_manager');
  const hotkeyChannel = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
  const hotkeyEvents = MethodChannel(
    'dev.leanflutter.plugins/hotkey_manager_event',
  );
  late AppController controller;
  late DesktopService desktop;
  late List<MethodCall> windowCalls;
  late List<MethodCall> trayCalls;
  late List<MethodCall> hotkeyCalls;
  late Offset physicalPointer;
  late List<Map<String, Object>> displays;
  late Rect bounds;
  late bool maximized;
  late bool shortcutAvailable;
  late bool failShortcutRegistration;
  late _PasteService pasteService;
  late FakeWinVShortcut winV;
  final platform = _HotKeyPlatform();
  final originalPlatform = HotKeyManagerPlatform.instance;
  setUpAll(() {
    HotKeyManagerPlatform.instance = platform;
    // Create the singleton outside any individual widget test's FakeAsync zone.
    expect(hotKeyManager.registeredHotKeyList, isEmpty);
  });
  tearDownAll(() async {
    HotKeyManagerPlatform.instance = originalPlatform;
    await platform.events.close();
  });

  Map<String, Object> display(String id, Rect area, {double scale = 1}) => {
    'id': id,
    'name': id,
    'size': {'width': area.width / scale, 'height': area.height / scale},
    'visibleSize': {'width': area.width / scale, 'height': area.height / scale},
    'visiblePosition': {'dx': area.left / scale, 'dy': area.top / scale},
    'scaleFactor': scale,
  };

  setUp(() async {
    controller = testController(MemoryClipboardRepository());
    await controller.reload();
    shortcutAvailable = true;
    failShortcutRegistration = false;
    pasteService = _PasteService();
    winV = FakeWinVShortcut();
    desktop = DesktopService(
      controller,
      canRegisterShortcut: (_) => shortcutAvailable,
      pasteService: pasteService,
      winVShortcut: winV,
    );
    windowCalls = [];
    trayCalls = [];
    hotkeyCalls = [];
    bounds = const Rect.fromLTWH(0, 0, 1180, 760);
    physicalPointer = const Offset(500, 300);
    displays = [display('primary', const Rect.fromLTWH(0, 0, 1920, 1040))];
    maximized = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      windowCalls.add(call);
      if (call.method == 'isMaximized') return maximized;
      if (call.method == 'isMinimized' || call.method == 'isFullScreen') {
        return false;
      }
      if (call.method == 'unmaximize') maximized = false;
      if (call.method == 'getBounds') {
        return {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        };
      }
      if (call.method == 'setBounds') {
        final args = call.arguments as Map;
        bounds = Rect.fromLTWH(
          args['x'] as double? ?? bounds.left,
          args['y'] as double? ?? bounds.top,
          args['width'] as double? ?? bounds.width,
          args['height'] as double? ?? bounds.height,
        );
      }
      return null;
    });
    messenger.setMockMethodCallHandler(screenChannel, (call) async {
      switch (call.method) {
        case 'getCursorScreenPoint':
          final ratio = (call.arguments as Map)['devicePixelRatio'] as double;
          return {
            'dx': physicalPointer.dx / ratio,
            'dy': physicalPointer.dy / ratio,
          };
        case 'getAllDisplays':
          return {'displays': displays};
        case 'getPrimaryDisplay':
          return displays.first;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(trayChannel, (call) async {
      trayCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(hotkeyChannel, (call) async {
      hotkeyCalls.add(call);
      if (call.method == 'register' && failShortcutRegistration) {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(hotkeyEvents, (_) async => null);
  });

  tearDown(() {
    windowManager.removeListener(desktop);
    trayManager.removeListener(desktop);
    controller.dispose();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      windowChannel,
      screenChannel,
      trayChannel,
      hotkeyChannel,
      hotkeyEvents,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> finish(WidgetTester tester, Future<void> work) async {
    var finished = false;
    final tracked = work.whenComplete(() => finished = true);
    for (var i = 0; i < 30 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(finished, isTrue, reason: 'Window transition did not complete');
    await tracked;
  }

  void useNativeDpi(WidgetTester tester) {
    // window_manager reads dart:ui.window, while screen_retriever reads the
    // binding's view. Keep their coordinates consistent in the test harness.
    tester.view.devicePixelRatio = windowManager.getDevicePixelRatio();
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Rect physicalBounds() {
    final scale = windowManager.getDevicePixelRatio();
    return Rect.fromLTWH(
      bounds.left * scale,
      bounds.top * scale,
      bounds.width * scale,
      bounds.height * scale,
    );
  }

  testWidgets('唤醒退出最大化、缩小并定位到鼠标附近，失焦后隐藏', (tester) async {
    useNativeDpi(tester);
    maximized = true;
    await finish(tester, desktop.showQuick());
    expect(windowCalls.map((call) => call.method), contains('unmaximize'));
    expect(windowCalls.map((call) => call.method), contains('setAsFrameless'));
    expect(
      windowCalls
          .singleWhere((call) => call.method == 'setHasShadow')
          .arguments,
      {'hasShadow': false},
    );
    expect(physicalBounds(), const Rect.fromLTWH(512, 312, 347, 427));
    expect(controller.quickMode, isTrue);
    final hides = windowCalls.where((call) => call.method == 'hide').length;
    desktop.onWindowBlur();
    await tester.pump();
    expect(
      windowCalls.where((call) => call.method == 'hide').length,
      hides + 1,
    );
  });

  testWidgets('失焦不关闭管理窗口，返回历史后也不会被旧 blur 事件隐藏', (tester) async {
    useNativeDpi(tester);
    desktop.onWindowBlur();
    expect(windowCalls, isEmpty);
    await finish(tester, desktop.showQuick());
    await finish(tester, desktop.showHistory());
    final hides = windowCalls.where((call) => call.method == 'hide').length;
    desktop.onWindowBlur();
    await tester.pump();
    expect(controller.quickMode, isFalse);
    expect(bounds.size, const Size(1180, 760));
    expect(windowCalls.where((call) => call.method == 'hide').length, hides);
  });

  testWidgets('不同 DPI 的副屏使用实际鼠标坐标和目标屏幕尺寸', (tester) async {
    useNativeDpi(tester);
    physicalPointer = const Offset(2500, 300);
    displays.add(
      display(
        'secondary',
        const Rect.fromLTWH(1920, 0, 2560, 1400),
        scale: 1.5,
      ),
    );
    await finish(tester, desktop.showQuick());
    expect(physicalBounds().size, const Size(347 * 1.5, 427 * 1.5));
    expect(physicalBounds().left, closeTo(2518, 0.01));
    expect(physicalBounds().top, closeTo(318, 0.01));
  });

  testWidgets('托盘左击进入全部历史并清空旧搜索和今日筛选', (tester) async {
    useNativeDpi(tester);
    controller.page = AppPage.favorites;
    controller.historySearch = '旧搜索';
    controller.historyTodayOnly = true;
    desktop.onTrayIconMouseDown();
    await tester.pumpAndSettle();
    expect(controller.page, AppPage.history);
    expect(controller.historySearch, isEmpty);
    expect(controller.historyTodayOnly, isFalse);
    expect(controller.history.length, 3);
    expect(windowCalls.map((call) => call.method), contains('show'));
  });

  testWidgets('托盘使用英文标题，右键只显示退出应用程序', (tester) async {
    useNativeDpi(tester);
    await finish(tester, desktop.initialize());
    expect(
      trayCalls.singleWhere((call) => call.method == 'setToolTip').arguments,
      {'toolTip': 'Idreaml Clip'},
    );
    final menu =
        (trayCalls
                    .singleWhere((call) => call.method == 'setContextMenu')
                    .arguments
                as Map)['menu']
            as Map;
    expect((menu['items'] as List).map((item) => item['label']), ['退出应用程序']);
    desktop.onTrayIconRightMouseDown();
    await tester.pump();
    expect(trayCalls.last.method, 'popUpContextMenu');
    expect(trayCalls.last.arguments, {'bringAppToFront': true});
    desktop.onTrayIconRightMouseDown();
    await tester.pump();
    expect(
      trayCalls.where((call) => call.method == 'popUpContextMenu'),
      hasLength(2),
    );
  });

  testWidgets('托盘退出菜单关闭程序，旧菜单入口不再生效', (tester) async {
    useNativeDpi(tester);
    desktop.onTrayMenuItemClick(MenuItem(key: 'quick', label: '打开快捷剪切板'));
    await tester.pumpAndSettle();
    expect(controller.quickMode, isFalse);
    expect(windowCalls, isEmpty);
    desktop.onTrayMenuItemClick(MenuItem(key: 'history', label: '进入全部历史'));
    await tester.pumpAndSettle();
    expect(controller.quickMode, isFalse);
    expect(windowCalls, isEmpty);
    desktop.onTrayMenuItemClick(MenuItem(key: 'exit', label: '退出应用程序'));
    await tester.pumpAndSettle();
    expect(trayCalls.map((call) => call.method), contains('destroy'));
    expect(windowCalls.last.method, 'close');
    expect(
      windowCalls
          .lastWhere((call) => call.method == 'setPreventClose')
          .arguments,
      {'isPreventClose': false},
    );
  });

  testWidgets('重复退出只执行一次清理，托盘失败仍关闭程序', (tester) async {
    var cleanups = 0;
    desktop = DesktopService(
      controller,
      winVShortcut: winV,
      onExit: () async {
        cleanups++;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(trayChannel, (call) async {
          if (call.method == 'destroy') {
            throw PlatformException(code: 'tray_unavailable');
          }
          return null;
        });
    final first = desktop.exitApp();
    final second = desktop.exitApp();
    await finish(tester, Future.wait([first, second]));
    expect(cleanups, 1);
    expect(windowCalls.where((call) => call.method == 'close'), hasLength(1));
    windowCalls.clear();
    await desktop.showMain();
    await desktop.showQuick();
    expect(windowCalls, isEmpty);
  });

  testWidgets('保存新快捷键后解除旧注册并持久化', (tester) async {
    await finish(tester, desktop.initialize());
    const shortcut = QuickShortcut(
      key: PhysicalKeyboardKey.keyJ,
      control: true,
      alt: true,
    );
    hotkeyCalls.clear();
    expect(await desktop.updateQuickShortcut(shortcut), isNull);
    expect(hotkeyCalls.map((call) => call.method), ['register', 'unregister']);
    expect(controller.quickShortcut.sameCombination(shortcut), isTrue);
    expect(
      QuickShortcut.decode(
        await controller.repository.getSetting('quick_shortcut'),
      ).sameCombination(shortcut),
      isTrue,
    );
    hotkeyCalls.clear();
    expect(await desktop.updateQuickShortcut(shortcut), isNull);
    expect(hotkeyCalls, isEmpty);
  });

  testWidgets('冲突或注册失败保留原快捷键及设置', (tester) async {
    await finish(tester, desktop.initialize());
    final previous = controller.quickShortcut;
    const shortcut = QuickShortcut(key: PhysicalKeyboardKey.keyJ, alt: true);
    hotkeyCalls.clear();
    shortcutAvailable = false;
    expect(await desktop.updateQuickShortcut(shortcut), contains('占用'));
    expect(hotkeyCalls, isEmpty);
    shortcutAvailable = true;
    failShortcutRegistration = true;
    expect(await desktop.updateQuickShortcut(shortcut), isNotNull);
    expect(controller.quickShortcut.sameCombination(previous), isTrue);
    expect(await controller.repository.getSetting('quick_shortcut'), isNull);
  });

  testWidgets('数据库保存失败撤销新注册，原注册保持有效', (tester) async {
    await finish(tester, desktop.initialize());
    final previous = controller.quickShortcut;
    (controller.repository as MemoryClipboardRepository).failSettingWrite =
        true;
    hotkeyCalls.clear();
    expect(
      await desktop.updateQuickShortcut(const QuickShortcut(alt: true)),
      isNotNull,
    );
    expect(hotkeyCalls.map((call) => call.method), ['register', 'unregister']);
    expect(controller.quickShortcut.sameCombination(previous), isTrue);
  });

  testWidgets('启动时默认组合被占用会提示修改', (tester) async {
    shortcutAvailable = false;
    await finish(tester, desktop.initialize());
    expect(controller.shortcutError, contains('占用'));
    expect(hotkeyCalls.where((call) => call.method == 'register'), isEmpty);
  });

  Future<void> emitCustomKey(WidgetTester tester, String identifier) async {
    await tester.runAsync(() async {
      platform.events.add({
        'type': 'onKeyDown',
        'data': {'identifier': identifier},
      });
      await Future<void>.delayed(Duration.zero);
    });
    // Window transitions await frames while the plugin stream uses the real
    // async zone. Advance both, just as native messages and frames interleave.
    for (var i = 0; i < 4; i++) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
  }

  testWidgets('Win+V 与原自定义组合互斥，关闭后原组合恢复生效', (tester) async {
    useNativeDpi(tester);
    const saved = QuickShortcut(key: PhysicalKeyboardKey.keyJ, alt: true);
    await controller.saveQuickShortcut(saved);
    await finish(tester, desktop.initialize());
    final previous =
        (hotkeyCalls.lastWhere((c) => c.method == 'register').arguments
                as Map)['identifier']
            as String;
    expect(await desktop.setWinVShortcutEnabled(true), isNull);
    expect(winV.active, isTrue);
    expect(hotkeyCalls.last.method, 'unregister');
    expect(controller.quickShortcut.sameCombination(saved), isTrue);
    expect(
      await controller.repository.getSetting('win_v_shortcut_enabled'),
      'true',
    );
    await emitCustomKey(tester, previous);
    expect(controller.quickMode, isFalse);
    expect(await desktop.beginShortcutRecording(), contains('关闭'));
    expect(
      await desktop.updateQuickShortcut(const QuickShortcut()),
      contains('关闭'),
    );
    winV.onPressed!();
    await tester.pumpAndSettle();
    expect(controller.quickMode, isTrue);
    await finish(tester, desktop.showHistory());
    expect(await desktop.setWinVShortcutEnabled(false), isNull);
    expect(winV.active, isFalse);
    expect(
      await controller.repository.getSetting('win_v_shortcut_enabled'),
      'false',
    );
    final restored =
        (hotkeyCalls.lastWhere((c) => c.method == 'register').arguments
                as Map)['identifier']
            as String;
    winV.onPressed!(); // Ignore a queued activation from the stopped hook.
    await tester.pumpAndSettle();
    expect(controller.quickMode, isFalse);
    await emitCustomKey(tester, restored);
    expect(controller.quickMode, isTrue);
    expect(controller.quickShortcut.sameCombination(saved), isTrue);
  });

  testWidgets('重启只启用保存的 Win+V 模式，退出释放拦截', (tester) async {
    controller.winVShortcutEnabled = true;
    await finish(tester, desktop.initialize());
    expect(winV.active, isTrue);
    expect(hotkeyCalls.where((c) => c.method == 'register'), isEmpty);
    await desktop.exitApp();
    expect(winV.active, isFalse);
    expect(windowCalls.last.method, 'close');
  });

  testWidgets('非 Windows 忽略 Win+V 设置并继续注册自定义组合', (tester) async {
    winV.isSupported = false;
    controller.winVShortcutEnabled = true;
    await finish(tester, desktop.initialize());
    expect(desktop.usesWinV, isFalse);
    expect(winV.starts, 0);
    expect(hotkeyCalls.where((c) => c.method == 'register'), hasLength(1));
    expect(await desktop.setWinVShortcutEnabled(true), contains('Windows'));
  });

  testWidgets('拦截启动失败保留原模式；保存失败恢复原快捷键', (tester) async {
    await finish(tester, desktop.initialize());
    winV.failStart = true;
    hotkeyCalls.clear();
    expect(await desktop.setWinVShortcutEnabled(true), isNotNull);
    expect(controller.winVShortcutEnabled, isFalse);
    expect(hotkeyCalls, isEmpty);
    winV.failStart = false;
    (controller.repository as MemoryClipboardRepository).failSettingWrite =
        true;
    expect(await desktop.setWinVShortcutEnabled(true), isNotNull);
    expect(controller.winVShortcutEnabled, isFalse);
    expect(winV.active, isFalse);
    expect(hotkeyCalls.map((c) => c.method), ['unregister', 'register']);
    expect(controller.shortcutModeChanging, isFalse);
  });

  testWidgets('恢复组合冲突或写入失败时保持 Win+V 独占', (tester) async {
    controller.winVShortcutEnabled = true;
    await finish(tester, desktop.initialize());
    shortcutAvailable = false;
    expect(await desktop.setWinVShortcutEnabled(false), contains('占用'));
    expect(winV.active, isTrue);
    shortcutAvailable = true;
    (controller.repository as MemoryClipboardRepository).failSettingWrite =
        true;
    hotkeyCalls.clear();
    expect(await desktop.setWinVShortcutEnabled(false), isNotNull);
    expect(controller.winVShortcutEnabled, isTrue);
    expect(winV.active, isTrue);
    expect(hotkeyCalls.map((c) => c.method), ['register', 'unregister']);
    expect(winV.starts, 2);
  });

  testWidgets('拦截异常提示重试，不自动启用自定义组合', (tester) async {
    controller.winVShortcutEnabled = true;
    winV.failStart = true;
    await finish(tester, desktop.initialize());
    expect(controller.shortcutError, contains('启用失败'));
    expect(hotkeyCalls.where((c) => c.method == 'register'), isEmpty);
    winV.failStart = false;
    expect(await desktop.setWinVShortcutEnabled(true), isNull);
    winV.active = false;
    winV.onFailure!();
    expect(controller.shortcutError, contains('停止响应'));
    expect(desktop.usesWinV, isTrue);
    expect(hotkeyCalls.where((c) => c.method == 'register'), isEmpty);
  });

  Future<void> mountSettings(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await controller.setPage(AppPage.settings);
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置开关切换期间锁定操作，开启置灰，关闭后恢复编辑', (tester) async {
    await finish(tester, desktop.initialize());
    await mountSettings(tester);
    final toggle = find.byKey(const ValueKey('win-v-shortcut-switch'));
    final custom = find.byKey(const ValueKey('custom-shortcut-button'));
    expect(tester.widget<OutlinedButton>(custom).onPressed, isNotNull);
    winV.startGate = Completer<void>();
    await tester.tap(toggle);
    await tester.pump();
    expect(tester.widget<OutlinedButton>(custom).onPressed, isNull);
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(await desktop.setWinVShortcutEnabled(true), isNotNull);
    winV.startGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(tester.widget<OutlinedButton>(custom).onPressed, isNull);
    expect(find.text(controller.quickShortcut.label()), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(tester.widget<OutlinedButton>(custom).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('其他平台设置页不展示 Win+V 开关', (tester) async {
    winV.isSupported = false;
    controller.winVShortcutEnabled = true;
    await mountSettings(tester);
    expect(find.byKey(const ValueKey('win-v-shortcut-switch')), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('custom-shortcut-button')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('录入时注销旧快捷键，取消后恢复原注册', (tester) async {
    await finish(tester, desktop.initialize());
    final previous =
        hotkeyCalls.lastWhere((call) => call.method == 'register').arguments
            as Map;
    hotkeyCalls.clear();
    expect(await desktop.beginShortcutRecording(), isNull);
    expect(hotkeyCalls.map((call) => call.method), ['unregister']);
    expect(await desktop.beginShortcutRecording(), isNotNull);
    await desktop.endShortcutRecording();
    expect(hotkeyCalls.map((call) => call.method), ['unregister', 'register']);
    expect(
      (hotkeyCalls.last.arguments as Map)['identifier'],
      previous['identifier'],
    );
    expect(await controller.repository.getSetting('quick_shortcut'), isNull);
  });

  testWidgets('录入相同组合也重新注册，保存新组合后不恢复旧组合', (tester) async {
    await finish(tester, desktop.initialize());
    final original = controller.quickShortcut;
    await desktop.beginShortcutRecording();
    hotkeyCalls.clear();
    expect(await desktop.updateQuickShortcut(original), isNull);
    await desktop.endShortcutRecording();
    expect(hotkeyCalls.map((call) => call.method), ['register']);
    await desktop.beginShortcutRecording();
    hotkeyCalls.clear();
    const changed = QuickShortcut(key: PhysicalKeyboardKey.keyQ, alt: true);
    expect(await desktop.updateQuickShortcut(changed), isNull);
    await desktop.endShortcutRecording();
    expect(hotkeyCalls.map((call) => call.method), ['register']);
    expect(controller.quickShortcut.sameCombination(changed), isTrue);
  });

  testWidgets('录入后的组合冲突，退出编辑仍恢复原组合', (tester) async {
    await finish(tester, desktop.initialize());
    final previous = controller.quickShortcut;
    await desktop.beginShortcutRecording();
    hotkeyCalls.clear();
    shortcutAvailable = false;
    expect(
      await desktop.updateQuickShortcut(
        const QuickShortcut(key: PhysicalKeyboardKey.f8),
      ),
      isNotNull,
    );
    expect(hotkeyCalls, isEmpty);
    shortcutAvailable = true;
    await desktop.endShortcutRecording();
    expect(hotkeyCalls.map((call) => call.method), ['register']);
    expect(controller.quickShortcut.sameCombination(previous), isTrue);
  });

  testWidgets('唤醒前捕获输入目标，复制后先隐藏再粘贴，并传递剪切板序号', (tester) async {
    useNativeDpi(tester);
    final target = _PasteTarget();
    pasteService.target = target;
    pasteService.onCapture = () => expect(windowCalls, isEmpty);
    await finish(tester, desktop.showQuick());
    controller.copiedClipboardSequence = 42;
    target.onPaste = () => expect(windowCalls.last.method, 'hide');
    await desktop.completeQuickUse();
    expect(target.calls, 1);
    expect(target.sequence, 42);
    expect(desktop.quickVisibility.value, isFalse);
  });

  testWidgets('右键复制及失焦后完成的复制都不会向旧输入框粘贴', (tester) async {
    useNativeDpi(tester);
    final target = _PasteTarget();
    pasteService.target = target;
    await finish(tester, desktop.showQuick());
    await desktop.completeQuickUse(paste: false);
    expect(target.calls, 0);
    await finish(tester, desktop.showQuick());
    desktop.onWindowBlur();
    await tester.pump();
    await desktop.completeQuickUse();
    expect(target.calls, 0);
  });

  testWidgets('没有输入目标时仅收起面板；预览扩展和收起保持面板位置', (tester) async {
    useNativeDpi(tester);
    await finish(tester, desktop.showQuick());
    final initial = physicalBounds();
    final preview = await desktop.expandQuickPreview();
    expect(preview, isNotNull);
    expect(preview!.panelBounds, initial);
    expect(preview.previewBounds.left, greaterThan(initial.right));
    expect(physicalBounds().width, greaterThan(initial.width));
    await desktop.collapseQuickPreview();
    expect(physicalBounds(), initial);
    await desktop.completeQuickUse();
    expect(windowCalls.last.method, 'hide');
  });

  testWidgets('屏幕右侧悬停预览向左展开，关闭后恢复原位置', (tester) async {
    useNativeDpi(tester);
    physicalPointer = const Offset(1870, 600);
    await finish(tester, desktop.showQuick());
    final initial = physicalBounds();
    final preview = await desktop.expandQuickPreview();
    expect(preview!.previewBounds.right, lessThan(initial.left));
    expect(preview.panelLocal.left, greaterThan(0));
    for (final size in [const Size(1600, 900), const Size(900, 1600)]) {
      final image = await desktop.expandQuickPreview(imageSize: size);
      expect(image!.panelBounds, rectMoreOrLessEquals(initial));
      expect(
        image.previewLocal.size.aspectRatio,
        closeTo(size.aspectRatio, 0.00001),
      );
    }
    final json = await desktop.expandQuickPreview();
    expect(json!.panelBounds, rectMoreOrLessEquals(initial));
    expect(json.previewBounds, rectMoreOrLessEquals(preview.previewBounds));
    await desktop.collapseQuickPreview();
    expect(physicalBounds(), rectMoreOrLessEquals(initial));
  });

  testWidgets('相同图片重复请求不再调整原生窗口，鼠标位置随左扩展正确换算', (tester) async {
    useNativeDpi(tester);
    physicalPointer = const Offset(1870, 600);
    await finish(tester, desktop.showQuick());
    final initial = physicalBounds();
    final preview = await desktop.expandQuickPreview(
      imageSize: const Size(640, 320),
    );
    windowCalls.clear();
    await desktop.expandQuickPreview(imageSize: const Size(640, 320));
    expect(windowCalls.where((call) => call.method == 'setBounds'), isEmpty);
    physicalPointer = initial.topLeft + const Offset(50, 60);
    final pointer = await desktop.getQuickPointerPosition();
    final expected =
        preview!.panelLocal.topLeft +
        Offset(50 / preview.scale, 60 / preview.scale);
    expect(pointer!.dx, closeTo(expected.dx, 0.01));
    expect(pointer.dy, closeTo(expected.dy, 0.01));
    await desktop.hide();
    expect(await desktop.getQuickPointerPosition(), isNull);
  });
}
