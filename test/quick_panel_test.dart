import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/services/quick_panel_placement.dart';

import 'support/clipboard_test_support.dart';

void main() {
  late MemoryClipboardRepository repository;
  late AppController controller;
  late RecordingDesktopService desktop;
  String? copiedText;

  setUp(() async {
    repository = MemoryClipboardRepository(count: 20);
    controller = testController(repository);
    desktop = RecordingDesktopService(controller);
    await controller.enterQuickMode();
    copiedText = null;
  });
  tearDown(() => controller.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = quickPanelSize;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMenu(WidgetTester tester, String text) async {
    await tester.tap(
      find.text(text),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('紧凑布局显示搜索、条目和底栏且不溢出', (tester) async {
    await mount(tester);
    expect(tester.getSize(find.byType(Scaffold)), quickPanelSize);
    expect(find.byKey(const ValueKey('quick-search')), findsOneWidget);
    expect(tester.getSize(find.text('搜索全部历史…')).width, greaterThan(150));
    expect(find.text('全部历史 →'), findsOneWidget);
    expect(find.text('剪切板内容 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单击未选中的条目复制该条目并关闭面板', (tester) async {
    await mount(tester);
    expect(controller.selectedQuick!.id, 'item-0');
    await tester.tap(find.text('剪切板内容 1'));
    await tester.pumpAndSettle();
    expect(copiedText, '剪切板内容 1');
    expect(repository.usedIds, ['item-1']);
    expect(desktop.hides, 1);
    expect(desktop.quickUsePasteRequests, [true]);
  });

  testWidgets('右键只打开菜单，复制菜单作用于右击的条目', (tester) async {
    await mount(tester);
    await openMenu(tester, '剪切板内容 1');
    expect(copiedText, isNull);
    expect(find.widgetWithText(MenuItemButton, '复制'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, '删除'), findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, '复制'));
    await tester.pumpAndSettle();
    expect(copiedText, '剪切板内容 1');
    expect(desktop.hides, 1);
    expect(repository.deletedIds, isEmpty);
    expect(desktop.quickUsePasteRequests, [false]);
  });

  testWidgets('右键删除只删除目标条目，保持面板打开', (tester) async {
    await mount(tester);
    await openMenu(tester, '剪切板内容 1');
    await tester.tap(find.widgetWithText(MenuItemButton, '删除'));
    await tester.pumpAndSettle();
    expect(repository.deletedIds, ['item-1']);
    expect(find.text('剪切板内容 1'), findsNothing);
    expect(find.text('剪切板内容 0'), findsOneWidget);
    expect(copiedText, isNull);
    expect(desktop.hides, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索框获得焦点时 Esc 关闭面板', (tester) async {
    await mount(tester);
    await tester.enterText(find.byKey(const ValueKey('quick-search')), '内容');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktop.hides, 1);
    expect(copiedText, isNull);
  });

  testWidgets('右键菜单用键盘选择删除不会额外复制当前选中条目', (tester) async {
    await mount(tester);
    await openMenu(tester, '剪切板内容 1');
    final deleteButton = find.widgetWithText(MenuItemButton, '删除');
    final focus = Focus.of(
      tester.element(
        find.descendant(of: deleteButton, matching: find.text('删除')),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repository.deletedIds, ['item-1']);
    expect(copiedText, isNull);
    expect(desktop.hides, 0);
  });

  testWidgets('菜单打开时 Esc 关闭整个面板', (tester) async {
    await mount(tester);
    await openMenu(tester, '剪切板内容 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(desktop.hides, 1);
    expect(copiedText, isNull);
  });

  testWidgets('方向键自动滚动到选中条目，Enter 复制', (tester) async {
    await mount(tester);
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(controller.selectedQuick!.id, 'item-9');
    expect(find.text('剪切板内容 9').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(copiedText, '剪切板内容 9');
    expect(desktop.hides, 1);
    expect(desktop.quickUsePasteRequests, [true]);
  });

  testWidgets('再次唤醒清空旧搜索词和右键菜单', (tester) async {
    await mount(tester);
    await tester.enterText(find.byKey(const ValueKey('quick-search')), '内容 1');
    await tester.pumpAndSettle();
    await openMenu(tester, '剪切板内容 1');
    await controller.enterQuickMode();
    await tester.pumpAndSettle();
    final search = tester.widget<TextField>(
      find.byKey(const ValueKey('quick-search')),
    );
    expect(search.controller!.text, isEmpty);
    expect(find.byType(MenuItemButton), findsNothing);
    expect(find.text('剪切板内容 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空列表在缩小后的面板内不溢出', (tester) async {
    repository.items.clear();
    await controller.reload();
    await mount(tester);
    expect(find.text('还没有剪切板记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('管理页没有唤出快捷面板的按钮', (tester) async {
    await mount(tester);
    tester.view.physicalSize = const Size(1180, 760);
    controller.leaveQuickMode();
    await tester.pumpAndSettle();
    expect(find.text('全部历史'), findsWidgets);
    expect(find.text('快捷面板'), findsNothing);
  });
}
