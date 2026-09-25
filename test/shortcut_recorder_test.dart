import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/ui/shortcut_dialog.dart';

import 'support/clipboard_test_support.dart';

class _Desktop extends RecordingDesktopService {
  _Desktop(super.controller);
  int saves = 0;
  String? saveError;

  @override
  Future<String?> updateQuickShortcut(QuickShortcut shortcut) async {
    saves++;
    if (saveError != null) return saveError;
    await controller.saveQuickShortcut(shortcut);
    return null;
  }
}

void main() {
  late AppController controller;
  late _Desktop desktop;

  setUp(() async {
    controller = testController(MemoryClipboardRepository());
    desktop = _Desktop(controller);
    await controller.setPage(AppPage.settings);
  });
  tearDown(() => controller.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1180, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Ctrl + Shift + V'));
    await tester.pumpAndSettle();
  }

  Future<void> record(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys,
  ) async {
    await tester.tap(find.byKey(const ValueKey('shortcut-recorder')));
    await tester.pump();
    for (final key in keys) {
      await tester.sendKeyDownEvent(key);
    }
    for (final key in keys.reversed) {
      await tester.sendKeyUpEvent(key);
    }
    await tester.pumpAndSettle();
  }

  String label(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('recorded-shortcut')))
      .data!;

  testWidgets('录入完整 Alt+Q 替换 Ctrl+Shift+V，保存并持久化', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.altRight,
      LogicalKeyboardKey.keyQ,
    ]);
    expect(label(tester), 'Alt + Q');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(desktop.saves, 1);
    expect(controller.quickShortcut.label('windows'), 'Alt + Q');
    expect(
      QuickShortcut.decode(
        await controller.repository.getSetting('quick_shortcut'),
      ).label('windows'),
      'Alt + Q',
    );
    expect(find.byType(ShortcutDialog), findsNothing);
  });

  testWidgets('支持全部修饰键变化、标点和无修饰键的 F8', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.shiftRight,
      LogicalKeyboardKey.period,
    ]);
    expect(label(tester), 'Shift + Win + .');
    await record(tester, [
      LogicalKeyboardKey.controlRight,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.arrowUp,
    ]);
    expect(label(tester), 'Ctrl + Alt + ↑');
    await record(tester, [LogicalKeyboardKey.f8]);
    expect(label(tester), 'F8');
    expect(desktop.saves, 0);
  });

  testWidgets('Tab 和 Enter 作为组合按键被录入，不跳转焦点或自动保存', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.tab,
    ]);
    expect(label(tester), 'Ctrl + Tab');
    await record(tester, [
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.enter,
    ]);
    expect(label(tester), 'Alt + Enter');
    expect(desktop.saves, 0);
    expect(find.byType(ShortcutDialog), findsOneWidget);
  });

  testWidgets('主键先按下也会录入随后同时按住的修饰键', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]);
    expect(label(tester), 'Ctrl + Alt + J');
  });

  testWidgets('只按修饰键不会提交，Esc 取消录入并保留原配置', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ]);
    expect(label(tester), '请按下快捷键…');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(label(tester), 'Ctrl + Shift + V');
    expect(find.byType(ShortcutDialog), findsOneWidget);
    expect(desktop.saves, 0);
  });

  testWidgets('多个普通键不会被悄悄截断成最后一个按键', (tester) async {
    await mount(tester);
    await record(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
    ]);
    expect(find.textContaining('一次录入一个组合'), findsOneWidget);
    expect(label(tester), '请按下快捷键…');
    expect(desktop.saves, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(label(tester), 'Ctrl + Shift + V');
  });

  testWidgets('保存冲突时保留编辑内容，修改后可重新保存', (tester) async {
    await mount(tester);
    desktop.saveError = '该快捷键已被占用';
    await record(tester, [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.keyQ]);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('该快捷键已被占用'), findsOneWidget);
    expect(controller.quickShortcut.label('windows'), 'Ctrl + Shift + V');
    expect(label(tester), 'Alt + Q');
    desktop.saveError = null;
    await record(tester, [LogicalKeyboardKey.f8]);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.quickShortcut.label('windows'), 'F8');
    expect(tester.takeException(), isNull);
  });
}
