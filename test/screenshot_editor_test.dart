import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/screenshot/screenshot_editor.dart';

void main() {
  const channel = MethodChannel('idreaml_clip/screenshot');
  late List<MethodCall> calls;
  late Map<String, Object> commitReply;
  var scrollTop = 0, scrollWidth = 400, scrollHeight = 300;
  var failScrollStart = false;
  setUp(() {
    calls = [];
    commitReply = {'success': true};
    scrollTop = 0;
    failScrollStart = false;
  });

  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Map<String, Object> snapshot(int session) => {
    'session': session,
    'pixels': Uint8List(800 * 600 * 4)..fillRange(0, 800 * 600 * 4, 255),
    'width': 800,
    'height': 600,
    'windows': [
      [50, 100, 450, 400],
    ],
    'styles': '{}',
  };

  Future<void> fromHost(WidgetTester tester, String method, Object data) async {
    const codec = StandardMethodCodec();
    final done = Completer<void>();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, data)),
      (_) => done.complete(),
    );
    await done.future;
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester, {bool pending = true}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'beginScroll' || call.method == 'scrollFrame') {
        if (call.method == 'beginScroll') {
          if (failScrollStart) {
            throw PlatformException(code: 'capture', message: '模拟采集启动失败');
          }
          final args = call.arguments as Map;
          scrollWidth = args['width'] as int;
          scrollHeight = args['height'] as int;
        }
        final pixels = Uint8List(scrollWidth * scrollHeight * 4);
        for (var y = 0; y < scrollHeight; y++) {
          for (var x = 0; x < scrollWidth; x++) {
            var value = (x * 73856093) ^ ((y + scrollTop) * 19349663);
            value ^= value >> 13;
            final at = (y * scrollWidth + x) * 4;
            pixels[at] = value & 255;
            pixels[at + 1] = (value >> 8) & 255;
            pixels[at + 2] = (value >> 16) & 255;
            pixels[at + 3] = 255;
          }
        }
        return {
          'session': 1,
          'width': scrollWidth,
          'height': scrollHeight,
          'pixels': pixels,
        };
      }
      return switch (call.method) {
        'load' => pending ? snapshot(1) : null,
        'commit' => commitReply,
        _ => null,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(const ScreenshotEditorApp());
    await settleImages(tester);
    expect(calls.where((c) => c.method == 'ready'), hasLength(pending ? 1 : 0));
  }

  final toolbar = find.byKey(const ValueKey('screenshot-toolbar'));

  testWidgets('长截图首次完成只进入编辑，第二次完成才提交合成后的长图', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    expect(
      find.byKey(const ValueKey('scroll-capture-controls')),
      findsOneWidget,
    );
    expect(find.byTooltip('停止采集'), findsNothing);
    scrollTop = 80;
    await settleImages(tester);
    await settleImages(tester);
    expect(find.text('400 × 380 px'), findsOneWidget);
    await tester.tap(find.byTooltip('完成采集，进入编辑'));
    await settleImages(tester);
    expect(
      find.byKey(const ValueKey('long-screenshot-editor')),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('放大长图'));
    await tester.pump();
    await tester.tap(find.byTooltip('实心遮盖'));
    await tester.pump();
    for (final state in tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    )) {
      if (state.position.axis == Axis.vertical &&
          state.position.maxScrollExtent > 0) {
        state.position.jumpTo(state.position.maxScrollExtent);
      }
    }
    await tester.pump();
    final canvas = tester.getRect(
      find.byKey(const ValueKey('long-screenshot-canvas')),
    );
    expect(canvas.width, 500);
    await tester.dragFrom(
      canvas.topLeft + const Offset(80, 300) * 1.25,
      const Offset(60, 45) * 1.25,
    );
    await settleImages(tester);
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await tester.pump();
    await tester.tap(find.byTooltip('重做（Ctrl + Y）'));
    await settleImages(tester);
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    final commit = calls.singleWhere((c) => c.method == 'commit');
    final image = img.decodePng((commit.arguments as Map)['png'] as Uint8List)!;
    expect(image.width, 400);
    expect(image.height, 380);
    final marked = image.getPixel(100, 325);
    expect([marked.r, marked.g, marked.b], [17, 24, 39]);
    expect(calls.last.method, 'close');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长截图开始失败恢复普通选区且可重新开始', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    failScrollStart = true;
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    expect(find.text('模拟采集启动失败'), findsOneWidget);
    expect(find.byKey(const ValueKey('scroll-capture-controls')), findsNothing);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    failScrollStart = false;
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    await tester.tap(find.byTooltip('取消长截图（Esc）'));
    await fromHost(tester, 'reset', 1);
    final count = calls.length;
    await tester.pump(const Duration(seconds: 2));
    expect(calls.length, count);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> dragToolbar(
    WidgetTester tester,
    Offset distance, {
    bool hold = false,
  }) async {
    final bounds = tester.getRect(toolbar);
    final pointer = await tester.startGesture(
      Offset(bounds.right - 3, bounds.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    if (hold) await tester.pump(const Duration(milliseconds: 600));
    await pointer.moveBy(distance / 4);
    await tester.pump();
    await pointer.moveBy(distance * 3 / 4);
    await tester.pump();
    await pointer.up();
    await tester.pump();
  }

  testWidgets('选区下方工具栏紧贴边框，切换样式仍贴边', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    expect(tester.getRect(toolbar).top, 400);
    final beforeDrag = tester.getRect(toolbar);
    await dragToolbar(tester, const Offset(0, -60), hold: true);
    expect(tester.getRect(toolbar), beforeDrag);
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    expect(tester.getRect(toolbar).top, 400);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final pixelRatio in [1.0, 1.5, 2.0]) {
    testWidgets('缩放 $pixelRatio 时上方工具栏按实际高度贴边，移动选区后跟随', (tester) async {
      await mount(tester);
      tester.view.devicePixelRatio = pixelRatio;
      await tester.pump();
      await tester.dragFrom(
        Offset(100, 400) / pixelRatio,
        Offset(350, 180) / pixelRatio,
      );
      await tester.pump();
      expect(tester.getRect(toolbar).bottom, closeTo(400 / pixelRatio, .01));
      await tester.tap(find.byTooltip('矩形'));
      await tester.pump();
      final styledToolbar = tester.getRect(toolbar);
      // Narrow high-DPI views can wrap the style controls onto another row.
      expect(
        styledToolbar.bottom,
        closeTo(
          (styledToolbar.height <= 400 / pixelRatio ? 400 : 580) / pixelRatio,
          .01,
        ),
      );
      expect(
        tester
            .getRect(find.text('350 × 180 px'))
            .overlaps(tester.getRect(toolbar)),
        isFalse,
      );
      await tester.tap(find.byTooltip('选择 / 调整'));
      await tester.pump();
      await tester.dragFrom(
        Offset(260, 480) / pixelRatio,
        Offset(0, -240) / pixelRatio,
      );
      await tester.pump();
      final rect = tester.getRect(toolbar);
      // At high scaling there may only be room inside the lower edge.
      expect(
        (rect.top - 340 / pixelRatio).abs() < .01 ||
            (rect.bottom - 160 / pixelRatio).abs() < .01 ||
            (rect.bottom - 340 / pixelRatio).abs() < .01,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('全屏按住工具栏空白处可拖动且不越界，撤销全屏后恢复选区贴边', (tester) async {
    await mount(tester);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.tapAt(const Offset(150, 225));
    await tester.pump();
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    final before = tester.getRect(toolbar);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    await dragToolbar(tester, const Offset(120, 160), hold: true);
    await tester.pump();
    final moved = tester.getRect(toolbar);
    expect(moved.left, greaterThan(before.left + 80));
    expect(moved.top, greaterThan(before.top + 120));
    expect(find.text('800 × 600 px'), findsOneWidget);
    await dragToolbar(tester, const Offset(2000, 2000));
    await tester.pump();
    expect(tester.getRect(toolbar).right, lessThanOrEqualTo(1200));
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(900));
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(900));
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await tester.pump();
    expect(find.text('400 × 300 px'), findsOneWidget);
    expect(tester.getRect(toolbar).top, 600);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全屏工具栏行内空白可拖动，按钮与样式控件不拖动工具栏', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final beforeDrag = tester.getRect(toolbar);
    final finish = tester.getRect(find.byTooltip('完成（Enter）'));
    final blank = Offset(finish.right + 20, finish.center.dy);
    expect(beforeDrag.contains(blank), isTrue);
    await tester.dragFrom(
      blank,
      const Offset(0, 90),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final moved = tester.getRect(toolbar);
    expect(moved.top, greaterThan(beforeDrag.top + 50));
    expect(calls.where((c) => c.method == 'commit'), isEmpty);

    await tester.drag(
      find.byTooltip('矩形'),
      const Offset(0, 80),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(tester.getRect(toolbar), moved);
    final widthControl = find.byType(DropdownButton<double>).first;
    await tester.tap(widthControl);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5').last);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<double>>(widthControl).value, 5);
    expect(tester.getRect(toolbar), moved);
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await tester.tapAt(const Offset(300, 450));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('800 × 600 px'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('接近整屏的非全屏选区没有外侧空间时贴住内侧下边框', (tester) async {
    await mount(tester);
    await tester.dragFrom(const Offset(20, 70), const Offset(750, 520));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    expect(tester.getRect(toolbar).bottom, 590);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('预热不显示截图，复用引擎时丢弃上次选区和标注', (tester) async {
    await mount(tester, pending: false);
    expect(find.byType(ScreenshotEditor), findsNothing);
    await fromHost(tester, 'start', snapshot(1));
    await settleImages(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await tester.tapAt(const Offset(120, 170));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '上次标注');
    await fromHost(tester, 'reset', 1);
    expect(find.byType(ScreenshotEditor), findsNothing);
    await fromHost(tester, 'start', snapshot(2));
    await settleImages(tester);
    expect(find.text('400 × 300 px'), findsNothing);
    expect(find.text('上次标注'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(calls.where((c) => c.method == 'load'), hasLength(1));
    expect(calls.where((c) => c.method == 'ready').map((c) => c.arguments), [
      1,
      2,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消后忽略迟到的旧会话，旧清理不影响新会话', (tester) async {
    await mount(tester, pending: false);
    await fromHost(tester, 'reset', 1);
    await fromHost(tester, 'start', snapshot(1));
    await settleImages(tester);
    expect(find.byType(ScreenshotEditor), findsNothing);
    await fromHost(tester, 'start', snapshot(2));
    await settleImages(tester);
    await fromHost(tester, 'reset', 1);
    expect(find.byType(ScreenshotEditor), findsOneWidget);
    expect(calls.where((c) => c.method == 'ready').map((c) => c.arguments), [
      2,
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('会话被关闭后退出确认弹窗不会留到下次截图', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    commitReply = {'error': '副本已保存；复制失败', 'locked': true};
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    await tester.tap(find.byTooltip('取消（Esc）'));
    await tester.pumpAndSettle();
    expect(find.text('退出截图结果处理？'), findsOneWidget);
    await fromHost(tester, 'reset', 1);
    await tester.pumpAndSettle();
    await fromHost(tester, 'start', snapshot(2));
    await settleImages(tester);
    expect(find.text('退出截图结果处理？'), findsNothing);
    expect(find.byType(ScreenshotEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窗口选择后全部工具可用，绘制与另存为最终会关闭编辑器', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    expect(find.text('400 × 300 px'), findsOneWidget);
    for (final tool in [
      '矩形',
      '椭圆',
      '直线',
      '箭头',
      '画笔',
      '荧光笔',
      '文字',
      '马赛克',
      '实心遮盖',
      '自动编号',
    ]) {
      expect(find.byTooltip(tool), findsOneWidget);
    }
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    await tester.dragFrom(const Offset(100, 160), const Offset(100, 80));
    await settleImages(tester);
    await tester.tap(find.byTooltip('另存为并完成'));
    await settleImages(tester);
    expect(tester.takeException(), isNull);
    final commit = calls.singleWhere((c) => c.method == 'commit');
    expect((commit.arguments as Map)['saveAs'], isTrue);
    expect(calls.last.method, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('中文多行输入期间 Enter 不完成，图标完成包含当前文字', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await tester.tapAt(const Offset(120, 170));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '中文截图\n第二行');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    expect(calls.where((c) => c.method == 'commit'), hasLength(1));
    expect(calls.last.method, 'close');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消另存为保留选区，随后普通完成可用', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    commitReply = {'cancelled': true};
    await tester.tap(find.byTooltip('另存为并完成'));
    await settleImages(tester);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    expect(find.text('400 × 300 px'), findsOneWidget);
    commitReply = {'success': true};
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    expect(calls.last.method, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
