import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/data_storage.dart';
import 'package:idreaml_clip/src/models/arrow_style.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/services/desktop_service.dart';
import 'package:idreaml_clip/src/services/screenshot_service.dart';
import 'package:idreaml_clip/src/ui/release_info_card.dart';
import 'package:idreaml_clip/src/ui/shortcut_help.dart';
import 'package:idreaml_clip/src/ui/storage_directory_card.dart';

import 'support/clipboard_test_support.dart';

class _SettingsRepository extends MemoryClipboardRepository {
  @override
  final storage = DataStorage()..root = Directory('settings-test-data');
}

void main() {
  late AppController controller;
  late _SettingsRepository repository;

  Future<void> mount(WidgetTester tester, {bool screenshots = true}) async {
    repository = _SettingsRepository();
    controller = testController(repository);
    addTearDown(controller.dispose);
    await controller.setPage(AppPage.settings);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: DesktopService(
          controller,
          screenshotService: ScreenshotService(
            controller,
            supported: screenshots,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置分类可进入、返回和重新从侧栏打开，保留存储和版本入口', (tester) async {
    await mount(tester);
    for (final name in ['快捷键', '快捷面板与历史', '截图与贴图', '启动与权限']) {
      expect(find.widgetWithText(ListTile, name), findsOneWidget);
    }
    expect(find.byType(StorageDirectoryCard), findsNothing);
    expect(find.byType(ReleaseInfoCard), findsNothing);
    await tester.tap(find.text('快捷面板与历史'));
    await tester.pumpAndSettle();
    expect(find.byType(StorageDirectoryCard), findsOneWidget);
    expect(find.text('历史保存数量'), findsOneWidget);
    expect(find.text('全局快捷键'), findsNothing);
    await tester.tap(find.byTooltip('返回设置首页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('版本信息'));
    await tester.pumpAndSettle();
    expect(find.byType(ReleaseInfoCard), findsOneWidget);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(ReleaseInfoCard), findsNothing);
    expect(find.widgetWithText(ListTile, '快捷键'), findsOneWidget);
  });

  testWidgets('默认箭头可固定、取消展开或恢复沿用，失败保留原值', (tester) async {
    await mount(tester);
    await tester.tap(find.text('截图与贴图'));
    await tester.pumpAndSettle();
    final picker = find.byType(DropdownButton<String>);
    Future<void> choose(String label) async {
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose(ArrowStyle.outlined.label);
    expect(controller.defaultArrowStyle, ArrowStyle.outlined);
    expect(repository.settings['default_arrow_style'], 'outlined');
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(15, 15));
    await tester.pumpAndSettle();
    expect(controller.defaultArrowStyle, ArrowStyle.outlined);
    repository.failSettingWrite = true;
    await choose(ArrowStyle.filled.label);
    expect(find.text('默认箭头样式保存失败，请重试'), findsOneWidget);
    expect(controller.defaultArrowStyle, ArrowStyle.outlined);
    repository.failSettingWrite = false;
    await choose('沿用上次选择');
    expect(controller.defaultArrowStyle, isNull);
    expect(repository.settings['default_arrow_style'], 'last');
  });

  testWidgets('无截图支持的平台不显示空分类，快捷键详情保留剪切板设置', (tester) async {
    await mount(tester, screenshots: false);
    expect(find.text('截图与贴图'), findsNothing);
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();
    expect(find.text('全局快捷键'), findsOneWidget);
    expect(find.text('截图快捷键'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('all-shortcut-help-button')));
    await tester.pumpAndSettle();
    expect(find.text('快捷剪切板'), findsOneWidget);
    expect(find.byType(ScreenshotHelpContent), findsNothing);
    expect(find.text('贴图窗口'), findsNothing);
  });

  testWidgets('全部快捷键说明实时更新自定义组合和截图键', (tester) async {
    await mount(tester);
    await controller.saveWinVShortcutEnabled(false);
    await tester.tap(find.text('快捷键'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('all-shortcut-help-button')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AllShortcutHelpDialog);
    expect(dialog, findsOneWidget);
    final initialQuick = controller.quickShortcut.label();
    expect(
      find.descendant(of: dialog, matching: find.text(initialQuick)),
      findsOneWidget,
    );

    const quick = QuickShortcut(key: PhysicalKeyboardKey.keyQ, alt: true);
    const screenshot = QuickShortcut(
      key: PhysicalKeyboardKey.f8,
      control: true,
    );
    await controller.saveQuickShortcut(quick);
    await controller.saveScreenshotShortcut(screenshot);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: dialog, matching: find.text(quick.label())),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(initialQuick)),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(screenshot.label())),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('F1')),
      findsNothing,
    );
  });

  testWidgets('固定 Win V 模式说明仅显示当前生效组合，关闭后恢复自定义', (tester) async {
    repository = _SettingsRepository();
    controller = testController(repository);
    addTearDown(controller.dispose);
    const custom = QuickShortcut(key: PhysicalKeyboardKey.keyQ, control: true);
    await controller.saveQuickShortcut(custom);
    await controller.saveWinVShortcutEnabled(true);
    await tester.pumpWidget(
      MaterialApp(
        home: AllShortcutHelpDialog(
          controller: controller,
          supportsWinV: true,
          supportsScreenshots: false,
        ),
      ),
    );
    expect(find.text('Win + V'), findsOneWidget);
    expect(find.text(custom.label()), findsNothing);
    await controller.saveWinVShortcutEnabled(false);
    await tester.pump();
    expect(find.text('Win + V'), findsNothing);
    expect(find.text(custom.label()), findsOneWidget);
  });

  testWidgets('快捷键说明在窄窗口和较大字体下可滚动且不溢出', (tester) async {
    repository = _SettingsRepository();
    controller = testController(repository);
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.4)),
          child: child!,
        ),
        home: AllShortcutHelpDialog(
          controller: controller,
          supportsWinV: false,
          supportsScreenshots: true,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('贴图窗口'));
    await tester.pumpAndSettle();
    expect(find.text('贴图窗口').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
