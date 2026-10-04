import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/workspace_layout.dart';

import 'support/clipboard_test_support.dart';

void main() {
  late MemoryClipboardRepository repository;
  late AppController controller;
  late RecordingDesktopService desktop;
  final sidebar = find.byKey(const ValueKey('main-sidebar'));
  final sidebarDivider = find.byKey(const ValueKey('sidebar-divider'));
  final history = find.byKey(const ValueKey('history-list'));
  final detail = find.byKey(const ValueKey('content-preview'));
  final historyDivider = find.byKey(const ValueKey('history-divider'));

  setUp(() async {
    repository = MemoryClipboardRepository();
    controller = testController(repository);
    desktop = RecordingDesktopService(controller);
    await controller.reload();
  });
  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1180, 760),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('拖动中间边界时列表和预览反向变化，松开后保存布局', (tester) async {
    await mount(tester);
    final initialHistory = tester.getSize(history).width;
    final initialDetail = tester.getSize(detail).width;
    await tester.drag(historyDivider, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(history).width, closeTo(initialHistory - 150, .1));
    expect(tester.getSize(detail).width, closeTo(initialDetail + 150, .1));
    await tester.drag(historyDivider, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(history).width, closeTo(initialHistory - 70, .1));
    expect(tester.getSize(detail).width, closeTo(initialDetail + 70, .1));
    final saved = WorkspaceLayout.decode(
      repository.settings['workspace_layout'],
    );
    expect(saved.historyFraction, controller.workspaceLayout.historyFraction);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导航拖至最窄仍保留全部图标、提示及操作，向右拖动恢复文字', (tester) async {
    await mount(tester);
    await tester.drag(sidebarDivider, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, WorkspaceLayout.minSidebarWidth);
    for (final label in ['全部历史', '我的收藏', '云同步', '设备', '隐私', '设置']) {
      expect(find.byTooltip(label), findsOneWidget);
    }
    expect(find.text('设置'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(controller.page, AppPage.settings);
    await tester.tap(find.byTooltip('暂停记录'));
    await tester.pumpAndSettle();
    expect(controller.recordingEnabled, isFalse);
    expect(find.byTooltip('恢复记录'), findsOneWidget);
    await tester.drag(sidebarDivider, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, closeTo(232, .1));
    expect(find.text('设置'), findsNWidgets(2));
    expect(find.text('全部历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最小窗口和拖动极限保留两列，放大窗口恢复所选宽度比例', (tester) async {
    await mount(tester);
    await tester.drag(sidebarDivider, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, WorkspaceLayout.maxSidebarWidth);
    tester.view.physicalSize = const Size(900, 620);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 260);
    await tester.drag(historyDivider, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(history).width,
      closeTo(WorkspaceLayout.minHistoryWidth, .1),
    );
    await tester.drag(historyDivider, const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(detail).width,
      closeTo(WorkspaceLayout.minDetailWidth, .1),
    );
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, WorkspaceLayout.maxSidebarWidth);
    final available =
        tester.getSize(history).width + tester.getSize(detail).width;
    expect(
      tester.getSize(history).width / available,
      closeTo(controller.workspaceLayout.historyFraction, .001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面切换与快捷面板往返后保持拖动布局', (tester) async {
    await mount(tester);
    await tester.drag(sidebarDivider, const Offset(-154, 0));
    await tester.pumpAndSettle();
    await tester.drag(historyDivider, const Offset(-180, 0));
    await tester.pumpAndSettle();
    final expectedWidth = tester.getSize(history).width;
    await tester.tap(find.byTooltip('隐私'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全部历史'));
    await tester.pumpAndSettle();
    expect(tester.getSize(history).width, expectedWidth);
    await controller.enterQuickMode();
    await tester.pumpAndSettle();
    controller.leaveQuickMode();
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 72);
    expect(tester.getSize(history).width, expectedWidth);
    expect(tester.takeException(), isNull);
  });

  test('保存的布局可以恢复，损坏或越界数据不会产生无效尺寸', () {
    const layout = WorkspaceLayout(sidebarWidth: 72, historyFraction: .4);
    final restored = WorkspaceLayout.decode(layout.encode());
    expect(restored.sidebarWidth, 72);
    expect(restored.historyFraction, .4);
    expect(WorkspaceLayout.decode('invalid').sidebarWidth, 226);
    expect(
      WorkspaceLayout.decode('{"sidebarWidth": "wide"}').sidebarWidth,
      226,
    );
    final bounded = WorkspaceLayout.decode(
      '{"sidebarWidth": -20, "historyFraction": 3}',
    );
    expect(bounded.sidebarWidth, 72);
    expect(bounded.historyFraction, 1);
    expect(layout.copyWith(sidebarWidth: double.nan).sidebarWidth, 72);
  });
}
