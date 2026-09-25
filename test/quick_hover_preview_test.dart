import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/services/quick_preview_placement.dart';
import 'package:idreaml_clip/src/ui/quick_hover_preview.dart';

import 'content_detail_test.dart' show item;
import 'support/clipboard_test_support.dart';

class _Desktop extends RecordingDesktopService {
  _Desktop(super.controller);
  int expansions = 0;
  int collapses = 0;
  Rect panel = const Rect.fromLTWH(0, 0, 347, 427);
  Future<void> Function(QuickPreviewPlacement)? onExpand;
  Offset? pointerPosition;
  Future<Offset?> Function()? readPointer;

  @override
  Future<QuickPreviewPlacement?> expandQuickPreview({Size? imageSize}) async {
    expansions++;
    final placement = placeQuickPreview(
      panel: panel,
      workArea: const Rect.fromLTWH(0, 0, 1920, 900),
      imageSize: imageSize,
    );
    await onExpand?.call(placement);
    return placement;
  }

  @override
  Future<void> collapseQuickPreview() async {
    collapses++;
  }

  @override
  Future<Offset?> getQuickPointerPosition() async =>
      readPointer == null ? pointerPosition : await readPointer!();
}

void main() {
  const json = '{"name":"Idreaml Clip","items":[1,2],"enabled":true}';
  late AppController controller;
  late _Desktop desktop;
  String? copied;

  setUp(() async {
    final repo = MemoryClipboardRepository(count: 0);
    repo.items.addAll([
      item(
        'image',
        ClipboardContent.image(
          img.encodePng(img.Image(width: 640, height: 320)),
          'image/png',
        ),
      ),
      item('json', const ClipboardContent.text(json)),
      item('text', const ClipboardContent.text('普通文本')),
      item('broken', const ClipboardContent.text('{不完整的 JSON')),
    ]);
    controller = testController(repo);
    desktop = _Desktop(controller);
    await controller.enterQuickMode();
    copied = null;
  });
  tearDown(() => controller.dispose());

  Future<TestGesture> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(835, 427);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
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
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(730, 420));
    addTearDown(mouse.removePointer);
    return mouse;
  }

  testWidgets('悬停图片延迟弹出预览，移入预览保持打开，离开后收起', (tester) async {
    final mouse = await mount(tester);
    await mouse.moveTo(tester.getCenter(find.text('PNG 图片')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(QuickHoverPreview), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('图片预览'), findsNothing);
    expect(find.text('PNG'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(QuickHoverPreview),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
    expect(
      tester.getSize(find.byType(QuickHoverPreview)),
      const Size(480, 240),
    );
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await mouse.moveTo(tester.getCenter(find.byType(QuickHoverPreview)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QuickHoverPreview), findsOneWidget);
    await mouse.moveTo(const Offset(750, 440));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(QuickHoverPreview), findsNothing);
    expect(copied, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JSON 预览缩进格式化，点击条目仍使用原文并请求粘贴', (tester) async {
    final mouse = await mount(tester);
    await mouse.moveTo(tester.getCenter(find.text(json)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('JSON 预览'), findsOneWidget);
    final text = tester.widget<SelectableText>(
      find.byKey(const ValueKey('quick-json-preview')),
    );
    expect(
      text.data,
      const JsonEncoder.withIndent('  ').convert(jsonDecode(json)),
    );
    await tester.tap(find.text(json));
    await tester.pumpAndSettle();
    expect(copied, json);
    expect(desktop.quickUsePasteRequests, [true]);
    expect(desktop.hides, 1);
    expect(find.byType(QuickHoverPreview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从图片预览移回同一条目不重复展开窗口', (tester) async {
    final mouse = await mount(tester);
    final row = tester.getCenter(find.text('PNG 图片'));
    await mouse.moveTo(row);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await mouse.moveTo(tester.getCenter(find.byType(QuickHoverPreview)));
      await tester.pump(const Duration(milliseconds: 250));
      await mouse.moveTo(row);
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(desktop.expansions, 1);
    expect(desktop.collapses, 0);
    expect(find.byType(QuickHoverPreview), findsOneWidget);
  });

  testWidgets('向左扩展时原生坐标先改变，鼠标静止不会触发收起再展开', (tester) async {
    final mouse = await mount(tester);
    desktop.panel = const Rect.fromLTWH(1550, 100, 347, 427);
    tester.view.physicalSize = const Size(347, 427);
    await tester.pump();
    final initialRow = tester.getCenter(find.text('PNG 图片'));
    final resized = Completer<void>();
    late QuickPreviewPlacement placement;
    desktop.onExpand = (next) async {
      placement = next;
      tester.view.physicalSize = next.windowBounds.size;
      await resized.future;
    };
    await mouse.moveTo(initialRow);
    await tester.pump(const Duration(milliseconds: 400));
    // The pointer's screen position is unchanged. Its client x changes when
    // Windows moves the enlarged window left, before Dart receives the reply.
    final pointer = initialRow + placement.panelLocal.topLeft;
    desktop.pointerPosition = pointer;
    await mouse.moveTo(pointer);
    await tester.pump(const Duration(milliseconds: 250));
    expect(desktop.collapses, 0);
    resized.complete();
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(QuickHoverPreview), findsOneWidget);
    expect(desktop.expansions, 1);
    expect(desktop.collapses, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通文本及无效 JSON 不预览，快速移开会取消待显示预览', (tester) async {
    final mouse = await mount(tester);
    await mouse.moveTo(tester.getCenter(find.text('PNG 图片')));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(tester.getCenter(find.text('普通文本')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(QuickHoverPreview), findsNothing);
    await mouse.moveTo(tester.getCenter(find.text('{不完整的 JSON')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(QuickHoverPreview), findsNothing);
    expect(copied, isNull);
  });

  testWidgets('实际鼠标仍在条目上时忽略离开事件，真正移出后关闭', (tester) async {
    final mouse = await mount(tester);
    final row = tester.getCenter(find.text('PNG 图片'));
    await mouse.moveTo(row);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    desktop.pointerPosition = row;
    await mouse.moveTo(const Offset(900, 440));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(QuickHoverPreview), findsOneWidget);
    expect(desktop.collapses, 0);
    await mouse.moveTo(row);
    desktop.pointerPosition = const Offset(900, 440);
    await mouse.moveTo(const Offset(900, 440));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(QuickHoverPreview), findsNothing);
  });

  testWidgets('离开位置的异步结果到达前重新进入，不关闭现有预览', (tester) async {
    final mouse = await mount(tester);
    final row = tester.getCenter(find.text('PNG 图片'));
    await mouse.moveTo(row);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final pending = Completer<Offset?>();
    desktop.readPointer = () => pending.future;
    await mouse.moveTo(const Offset(900, 440));
    await tester.pump(const Duration(milliseconds: 250));
    await mouse.moveTo(row);
    pending.complete(const Offset(900, 440));
    await tester.pumpAndSettle();
    expect(find.byType(QuickHoverPreview), findsOneWidget);
    expect(desktop.expansions, 1);
    expect(desktop.collapses, 0);
  });

  testWidgets('旧预览存在时取消另一条目的悬停后仍可重新预览它', (tester) async {
    final mouse = await mount(tester);
    await mouse.moveTo(tester.getCenter(find.text('PNG 图片')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final jsonRow = tester.getCenter(find.text(json));
    await mouse.moveTo(jsonRow);
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(tester.getCenter(find.byType(QuickHoverPreview)));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(jsonRow);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('JSON 预览'), findsOneWidget);
    expect(desktop.expansions, 2);
  });

  testWidgets('窗口收缩后的过期进入事件不会重新打开预览', (tester) async {
    final mouse = await mount(tester);
    desktop.pointerPosition = const Offset(900, 440);
    await mouse.moveTo(tester.getCenter(find.text('PNG 图片')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(desktop.expansions, 0);
    expect(find.byType(QuickHoverPreview), findsNothing);
  });

  testWidgets('预览打开时 Esc 关闭面板，右键菜单复制不会请求粘贴', (tester) async {
    final mouse = await mount(tester);
    await mouse.moveTo(tester.getCenter(find.text(json)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(json),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.byType(QuickHoverPreview), findsNothing);
    await tester.tap(find.widgetWithText(MenuItemButton, '复制'));
    await tester.pumpAndSettle();
    expect(copied, json);
    expect(desktop.quickUsePasteRequests, [false]);
    await mouse.moveTo(tester.getCenter(find.text('PNG 图片')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(QuickHoverPreview), findsNothing);
    expect(desktop.hides, 2);
    expect(tester.takeException(), isNull);
  });
}
