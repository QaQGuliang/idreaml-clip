import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/clipboard_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppController controller;
  late RecordingDesktopService desktop;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-desk-shell-');
    final notes = DesktopNotes(
      DeskRepository(
        deviceId: 'shell-test',
        testPath: p.join(root.path, 'desktop.db'),
        factory: databaseFactoryFfiNoIsolate,
      ),
    );
    await notes.initialize();
    for (final kind in DeskKind.values) {
      await notes.updateSettings(kind, {'enabled': true});
    }
    await notes.save(DeskKind.note, body: '第一条桌面便签');
    await notes.save(DeskKind.note, body: '第二条桌面便签');
    await notes.save(DeskKind.todo, body: '尚待完成的事项');
    await notes.save(DeskKind.todo, body: '已经完成的事项', done: true);
    controller = testController(MemoryClipboardRepository())
      ..desktopNotes = notes;
    desktop = RecordingDesktopService(controller);
    await controller.reload();
  });
  tearDown(() async {
    controller.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('最小主窗口同时启用桌面模块后侧栏不溢出，数量和导航保持可用', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();

    final sidebar = find.byKey(const ValueKey('main-sidebar'));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(sidebar).height, 620);
    expect(
      find.descendant(of: sidebar, matching: find.text('桌面')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byTooltip('便签'), matching: find.text('2')),
      findsOneWidget,
    );
    // 已完成的待办保留在数据库，但不计入侧栏待完成数量。
    expect(
      find.descendant(of: find.byTooltip('待办'), matching: find.text('1')),
      findsOneWidget,
    );
    for (final label in ['全部历史', '我的收藏', '便签', '待办', '云同步', '设备', '隐私', '设置']) {
      final navigation = find.byTooltip(label);
      expect(navigation.hitTestable(), findsOneWidget);
      expect(
        tester.getRect(navigation).bottom,
        lessThanOrEqualTo(tester.getRect(sidebar).bottom),
      );
    }

    await tester.tap(find.byTooltip('便签'));
    await tester.pumpAndSettle();
    expect(controller.page, AppPage.notes);
    expect(find.text('第一条桌面便签'), findsOneWidget);
    expect(find.text('第二条桌面便签'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('待办'));
    await tester.pumpAndSettle();
    expect(controller.page, AppPage.todos);
    expect(find.text('尚待完成的事项'), findsOneWidget);
    expect(find.text('已经完成的事项'), findsNothing);
    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();
    expect(find.text('已经完成的事项'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(controller.page, AppPage.settings);
    expect(find.widgetWithText(ListTile, '便签与待办'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
