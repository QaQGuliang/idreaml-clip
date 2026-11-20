import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/screenshot/arrow_style_picker.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_model.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_editor.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_color_picker.dart';

void main() {
  const channel = MethodChannel('idreaml_clip/screenshot');
  late List<MethodCall> calls;
  late Map<String, Object> commitReply;
  var scrollTop = 0, scrollWidth = 400, scrollHeight = 300;
  var autoScroll = false, failScrollStep = false;
  Completer<void>? pendingStyleSave;
  var failScrollStart = false;
  var failColorCopy = false;
  var helpShortcut = 'Ctrl + Shift + S';
  var failHelpQuery = false;
  setUp(() {
    calls = [];
    commitReply = {'success': true};
    scrollTop = 0;
    autoScroll = failScrollStep = false;
    pendingStyleSave = null;
    failScrollStart = false;
    failColorCopy = false;
    helpShortcut = 'Ctrl + Shift + S';
    failHelpQuery = false;
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
    'autoScroll': autoScroll,
    'pixels': Uint8List(800 * 600 * 4)..fillRange(0, 800 * 600 * 4, 255),
    'width': 800,
    'height': 600,
    'windows': [
      [50, 100, 450, 400],
    ],
    'styles': '{}',
    'screenshotShortcut': 'F8',
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
      if (call.method == 'getScreenshotShortcut') {
        if (failHelpQuery) throw PlatformException(code: 'unavailable');
        return helpShortcut;
      }
      if (call.method == 'copyColor' && failColorCopy) {
        throw PlatformException(code: 'clipboard', message: '无法复制');
      }
      if (call.method == 'scrollStep') {
        if (failScrollStep) {
          throw PlatformException(code: 'scroll', message: '窗口不接受自动滚动');
        }
        // The page accepts two scroll steps and then reaches its bottom.
        if (scrollTop < 120) scrollTop += 60;
        return null;
      }
      if (call.method == 'styles' && pendingStyleSave != null) {
        await pendingStyleSave!.future;
        return null;
      }
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
  final strokePicker = find.byKey(const ValueKey('screenshot-stroke-width'));
  final fontPicker = find.byKey(const ValueKey('screenshot-font-size'));

  double sizeValue(WidgetTester tester, Finder picker) =>
      tester.widget<Slider>(picker).value;

  double fontValue(WidgetTester tester, Finder picker) =>
      tester.widget<DropdownButton<double>>(picker).value!;

  bool toolActive(WidgetTester tester, String label) {
    final button = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == label,
      ),
    );
    return button.isSelected ??
        button.style?.backgroundColor?.resolve({}) == const Color(0xFF6D28D9);
  }

  // Colors, stroke width and font size live in a popup anchored to the toolbar
  // so the bar itself stays a single row.
  Future<void> openStyles(WidgetTester tester) async {
    await tester.tap(find.byTooltip('标注样式'));
    await tester.pumpAndSettle();
  }

  Future<void> closeStyles(WidgetTester tester) async {
    // Mirror clicking away from the menu: dismiss the popup route only.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
  }

  Future<double> strokeWidth(WidgetTester tester) async {
    await openStyles(tester);
    final value = sizeValue(tester, strokePicker);
    await closeStyles(tester);
    return value;
  }

  // The blank padding of the bar is its drag handle; buttons never are.
  Future<void> dragToolbar(
    WidgetTester tester,
    Offset distance, {
    bool hold = false,
  }) async {
    final bounds = tester.getRect(toolbar);
    final pointer = await tester.startGesture(
      Offset(bounds.left + 3, bounds.center.dy),
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

  Future<double> fontSize(WidgetTester tester) async {
    await openStyles(tester);
    final value = fontValue(tester, fontPicker);
    await closeStyles(tester);
    return value;
  }

  Future<void> undo(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleImages(tester);
  }

  Future<img.Image> exportedImage(WidgetTester tester) async {
    commitReply = {'cancelled': true};
    await tester.tap(find.byTooltip('另存为并完成'));
    await settleImages(tester);
    final result = calls.lastWhere((c) => c.method == 'commit');
    return img.decodePng((result.arguments as Map)['png'] as Uint8List)!;
  }

  // Check inherited paint colors, including the disabled state. This also
  // catches theme changes which silently make a dark icon blend into its bar.
  void expectPinContrast(WidgetTester tester, Color background) {
    final pin = find.widgetWithText(TextButton, '贴图');
    final icon = find.descendant(
      of: pin,
      matching: find.byIcon(Icons.push_pin_rounded),
    );
    final label = find.descendant(of: pin, matching: find.text('贴图'));
    final labelContext = tester.element(label);
    final textStyle = DefaultTextStyle.of(labelContext).style;
    expect(
      textStyle.fontFamily,
      Theme.of(labelContext).textTheme.labelLarge!.fontFamily,
    );
    final foregrounds = [
      IconTheme.of(tester.element(icon)).color!,
      textStyle.color!,
    ];
    final bg = background.computeLuminance() + .05;
    for (final foreground in foregrounds) {
      final fg =
          Color.alphaBlend(foreground, background).computeLuminance() + .05;
      expect(fg > bg ? fg / bg : bg / fg, greaterThanOrEqualTo(4.5));
    }
  }

  Future<void> mountTwoDisplays(WidgetTester tester) async {
    await mount(tester, pending: false);
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1600, 800);
    final data = snapshot(1)
      ..['width'] = 1600
      ..['height'] = 800
      ..['monitors'] = [
        [0, 0, 800, 600],
        [800, 160, 1600, 800],
      ]
      ..['pixels'] = (Uint8List(1600 * 800 * 4)
        ..fillRange(0, 1600 * 800 * 4, 255));
    await fromHost(tester, 'start', data);
    await settleImages(tester);
  }

  Future<void> openLongEditor(WidgetTester tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    await tester.tap(find.byTooltip('完成采集，进入编辑'));
    await settleImages(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('long-screenshot-editor')),
      findsOneWidget,
    );
  }

  Future<void> chooseArrowStyle(WidgetTester tester, ArrowStyle style) async {
    await tester.tap(find.byTooltip('箭头样式'));
    await tester.pumpAndSettle();
    for (final option in ArrowStyle.values) {
      final row = find.widgetWithText(PopupMenuItem<ArrowStyle>, option.label);
      expect(row, findsOneWidget);
      expect(
        tester
            .widget<ArrowStylePreview>(
              find.descendant(
                of: row,
                matching: find.byType(ArrowStylePreview),
              ),
            )
            .style,
        option,
      );
    }
    await tester.tap(find.text(style.label));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ArrowStylePicker>(find.byType(ArrowStylePicker)).value,
      style,
    );
  }

  testWidgets('截图帮助紧邻选择，显示最新组合且隔离画布快捷键', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    final help = tester.getRect(find.byTooltip('截图帮助'));
    final select = tester.getRect(find.byTooltip('选择 / 调整'));
    expect(help.right, lessThanOrEqualTo(select.left));
    expect(help.center.dy, select.center.dy);
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final width = await strokeWidth(tester);
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    expect(find.text(helpShortcut), findsOneWidget);
    expect(find.text('F8'), findsNothing);
    expect(
      (calls.lastWhere((call) => call.method == 'setLocalShortcuts').arguments
          as Map)['enabled'],
      false,
    );
    for (final key in [
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.f2,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    // Native messages in flight are ignored as well as Flutter key events.
    await fromHost(tester, 'localShortcut', {'session': 1, 'key': 'escape'});
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      calls.where((c) => ['commit', 'copyColor', 'close'].contains(c.method)),
      isEmpty,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    // Keys pressed while the help dialog was open left the stroke width alone.
    expect(await strokeWidth(tester), width);
    expect(toolActive(tester, '矩形'), isTrue);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(await strokeWidth(tester), width + 1);
    helpShortcut = 'Alt + F9';
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    expect(find.text(helpShortcut), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('帮助读取失败仍显示本次截图的组合，并保留未确认文字', (tester) async {
    failHelpQuery = true;
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await tester.tapAt(const Offset(120, 180));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '未完成的文字');
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    expect(find.text('F8'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭帮助'));
    await tester.pumpAndSettle();
    final text = tester.widget<TextField>(find.byType(TextField));
    expect(text.controller!.text, '未完成的文字');
    expect(text.focusNode!.hasFocus, isTrue);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('多屏帮助完整落在编辑工具所在的显示器且可滚动', (tester) async {
    await mountTwoDisplays(tester);
    await tester.dragFrom(
      const Offset(860, 320) / 1.5,
      const Offset(510, 300) / 1.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    final body = tester.getRect(
      find
          .descendant(of: find.byType(Dialog), matching: find.byType(Material))
          .first,
    );
    expect(body.left, greaterThanOrEqualTo(800 / 1.5));
    expect(body.top, greaterThanOrEqualTo(160 / 1.5));
    expect(body.right, lessThanOrEqualTo(1600 / 1.5));
    expect(body.bottom, lessThanOrEqualTo(800 / 1.5));
    await tester.ensureVisible(find.text('取色器'));
    await tester.pumpAndSettle();
    expect(find.text('取色器').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄长图窗口仍固定显示帮助和选择，关闭帮助不会完成长图', (tester) async {
    await openLongEditor(tester);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(840, 1000);
    await tester.pump();
    final help = tester.getRect(find.byTooltip('截图帮助'));
    final select = tester.getRect(find.byTooltip('选择 / 调整'));
    expect(help.right, select.left);
    expect(help.center.dy, select.center.dy);
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    expect(find.text('截图使用说明与快捷键'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey('long-screenshot-editor')),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('双 Ctrl 临时选择，移动中松键后完成拖动并恢复矩形及撤销重做', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    await tester.dragFrom(const Offset(120, 190), const Offset(80, 60));
    await settleImages(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    final moving = await tester.startGesture(
      const Offset(160, 220),
      kind: PointerDeviceKind.mouse,
    );
    await moving.moveBy(const Offset(30, 15));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await moving.moveBy(const Offset(30, 15));
    await moving.up();
    await settleImages(tester);
    expect(toolActive(tester, '矩形'), isTrue);
    await tester.dragFrom(const Offset(300, 190), const Offset(60, 60));
    final result = await exportedImage(tester);
    expect(result.getPixel(70, 120).g, 255); // Original rectangle moved away.
    expect(result.getPixel(130, 150).g, 87); // Its new left edge.
    expect(result.getPixel(250, 120).g, 87); // The next rectangle was drawn.
    await undo(tester);
    expect(toolActive(tester, '矩形'), isTrue);
    final undone = await exportedImage(tester);
    expect(undone.getPixel(250, 120).g, 255);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleImages(tester);
    expect(toolActive(tester, '矩形'), isTrue);
    final redone = await exportedImage(tester);
    expect(redone.getPixel(250, 120).g, 87);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('绘制中按 Ctrl 先完成当前矩形，随后可临时选择并调整端点', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final drawing = await tester.startGesture(
      const Offset(120, 190),
      kind: PointerDeviceKind.mouse,
    );
    await drawing.moveTo(const Offset(160, 210));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(toolActive(tester, '矩形'), isTrue);
    await drawing.moveTo(const Offset(200, 250));
    await drawing.up();
    await settleImages(tester);
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await tester.dragFrom(const Offset(200, 250), const Offset(20, 20));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleImages(tester);
    expect(toolActive(tester, '矩形'), isTrue);
    final resized = await exportedImage(tester);
    expect(resized.getPixel(170, 150).g, 87);
    expect(resized.getPixel(150, 150).g, 255);
    await undo(tester);
    final restored = await exportedImage(tester);
    expect(restored.getPixel(150, 120).g, 87);
    expect(restored.getPixel(170, 150).g, 255);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('文字 Ctrl+A 正常，临时选择在失焦及新截图会话后清理', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('文字'));
    await tester.tapAt(const Offset(120, 190));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'abc12');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(toolActive(tester, '文字'), isTrue);
    final text = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(text.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    tester.binding.platformDispatcher.onViewFocusChange?.call(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.unfocused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.pump();
    expect(toolActive(tester, '矩形'), isTrue);
    tester.binding.platformDispatcher.onViewFocusChange?.call(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.undefined,
      ),
    );
    await tester.pump();
    expect(toolActive(tester, '矩形'), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await fromHost(tester, 'reset', 1);
    await fromHost(tester, 'start', snapshot(2));
    await settleImages(tester);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    // A new capture session opens on the selection tool.
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    expect(toolActive(tester, '矩形'), isFalse);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Ctrl 选择的标注在样式弹层中保持选中，松键才恢复原工具', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.dragFrom(const Offset(120, 190), const Offset(80, 60));
    await settleImages(tester);
    await tester.tap(find.byTooltip('荧光笔'));
    await tester.pump();
    expect(await strokeWidth(tester), 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(const Offset(160, 220));
    await tester.pump(const Duration(milliseconds: 350));
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    // The selected annotation keeps driving the style popup while Ctrl is held.
    await openStyles(tester);
    expect(sizeValue(tester, strokePicker), 3);
    await closeStyles(tester);
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(toolActive(tester, '荧光笔'), isTrue);
    expect(await strokeWidth(tester), 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('绘制中 Ctrl+Z 取消当前笔画后继续移动鼠标不会恢复或报错', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    final drawing = await tester.startGesture(
      const Offset(120, 190),
      kind: PointerDeviceKind.mouse,
    );
    await drawing.moveTo(const Offset(200, 250));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await drawing.moveTo(const Offset(240, 280));
    await drawing.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleImages(tester);
    expect(toolActive(tester, '矩形'), isTrue);
    final result = await exportedImage(tester);
    expect(
      result.every(
        (pixel) => pixel.r == 255 && pixel.g == 255 && pixel.b == 255,
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长图编辑按住 Ctrl 可移动标注，松开仍使用原直线工具', (tester) async {
    await openLongEditor(tester);
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pump();
    final base = await exportedImage(tester);
    await tester.tap(find.byTooltip('直线'));
    await tester.pump();
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('long-screenshot-canvas')),
    );
    await tester.dragFrom(origin + const Offset(60, 90), const Offset(120, 0));
    await settleImages(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    await tester.dragFrom(origin + const Offset(120, 90), const Offset(0, 40));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
    await tester.pump();
    expect(toolActive(tester, '直线'), isTrue);
    await tester.dragFrom(origin + const Offset(60, 180), const Offset(120, 0));
    final result = await exportedImage(tester);
    expect(result.getPixel(120, 130).g, 87);
    expect(result.getPixel(120, 180).g, 87);
    expect(result.getPixel(120, 90).toList(), base.getPixel(120, 90).toList());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('六种描边工具绘制中按数字键实时调粗细，一次撤销恢复空白', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    for (final tool in ['矩形', '椭圆', '直线', '箭头', '画笔', '荧光笔']) {
      await tester.tap(find.byTooltip(tool));
      await tester.pump();
      final initial = await strokeWidth(tester);
      final gesture = await tester.startGesture(
        const Offset(120, 200),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(const Offset(160, 220));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
      await gesture.moveTo(const Offset(220, 240));
      await tester.pump();
      await gesture.up();
      await settleImages(tester);
      // One digit1 then three digit2 presses: the drawn stroke ends up wider.
      expect(await strokeWidth(tester), initial + 2, reason: tool);
      final drawn = await exportedImage(tester);
      expect(
        drawn.any((pixel) => pixel.r < 250 || pixel.g < 250 || pixel.b < 250),
        isTrue,
        reason: tool,
      );
      await undo(tester);
      final undone = await exportedImage(tester);
      expect(
        undone.every(
          (pixel) => pixel.r == 255 && pixel.g == 255 && pixel.b == 255,
        ),
        isTrue,
        reason: '$tool 的粗细变化与整笔应一起撤销',
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('样式弹层按工具显示，马赛克块和编号大小也可用数字键调整', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    // Nothing to style while the selection tool is active.
    expect(find.byTooltip('标注样式'), findsNothing);
    for (final tool in ['矩形', '椭圆', '直线', '箭头', '画笔', '荧光笔']) {
      await tester.tap(find.byTooltip(tool));
      await tester.pump();
      expect(strokePicker, findsNothing, reason: '$tool 的样式默认收起');
      await openStyles(tester);
      expect(strokePicker, findsOneWidget, reason: tool);
      expect(fontPicker, findsNothing, reason: tool);
      expect(find.text('字号'), findsNothing, reason: tool);
      await closeStyles(tester);
    }
    await tester.tap(find.byTooltip('马赛克'));
    await tester.pump();
    await openStyles(tester);
    expect(find.text('块大小'), findsOneWidget);
    expect(fontPicker, findsNothing);
    final block = sizeValue(tester, strokePicker);
    await closeStyles(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(await strokeWidth(tester), block + 1);
    await tester.tap(find.byTooltip('自动编号'));
    await tester.pump();
    await openStyles(tester);
    expect(strokePicker, findsNothing);
    expect(find.text('字号'), findsOneWidget);
    await closeStyles(tester);
    final number = await fontSize(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad1);
    await tester.pump();
    expect(await fontSize(tester), number - 2);
    await tester.tap(find.byTooltip('实心遮盖'));
    await tester.pump();
    await openStyles(tester);
    // A block cover only takes a color; size shortcuts are ignored.
    expect(strokePicker, findsNothing);
    expect(fontPicker, findsNothing);
    await closeStyles(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(toolActive(tester, '实心遮盖'), isTrue);
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await openStyles(tester);
    expect(strokePicker, findsNothing);
    expect(fontPicker, findsOneWidget);
    await closeStyles(tester);
    await tester.tapAt(const Offset(120, 170));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '编号 12');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '编号 12',
    );
    expect(calls.where((call) => call.method == 'commit'), isEmpty);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('样式弹层锚定工具栏，打开时不加宽也不移动工具栏', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final bar = tester.getRect(toolbar);
    final menu = tester.widget<PopupMenuButton<void>>(
      find.byKey(const ValueKey('screenshot-style-menu')),
    );
    expect(menu.color, const Color(0xF21F2027));
    expect(menu.shape, isA<RoundedRectangleBorder>());
    await openStyles(tester);
    expect(strokePicker, findsOneWidget);
    expect(
      find.byKey(const ValueKey('screenshot-custom-color')),
      findsOneWidget,
    );
    expect(tester.getRect(toolbar), bar);
    expect(
      tester.getRect(find.byType(PopupMenuItem<void>)).top,
      greaterThanOrEqualTo(bar.bottom),
    );
    await closeStyles(tester);
    expect(strokePicker, findsNothing);
    expect(tester.getRect(toolbar), bar);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('打开截图默认使用选择工具，工具栏为单行且没有第三行提示', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    expect(toolActive(tester, '选择 / 调整'), isTrue);
    expect(toolActive(tester, '矩形'), isFalse);
    expect(tester.getRect(toolbar).height, lessThan(60));
    expect(strokePicker, findsNothing);
    expect(find.textContaining('已选区域'), findsNothing);
    expect(find.textContaining('1 / 2'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全屏默认在屏幕左下角，可拖走让出内容', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    final bar = tester.getRect(toolbar);
    expect(bar.bottom, 592);
    expect(bar.height, lessThan(60));
    expect(bar.left, lessThan(200));
    await dragToolbar(tester, const Offset(0, -200));
    final moved = tester.getRect(toolbar);
    expect(moved.top, lessThan(bar.top - 150));
    expect(moved.bottom, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('选中与拖动已有标注时调整粗细，组合键及弹出菜单不触发', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('直线'));
    await tester.pump();
    await tester.dragFrom(const Offset(120, 210), const Offset(120, 0));
    await settleImages(tester);
    await tester.tap(find.byTooltip('选择 / 调整'));
    await tester.pump();
    await tester.tapAt(const Offset(180, 210));
    await tester.pump();
    await openStyles(tester);
    expect(fontPicker, findsNothing);
    final original = sizeValue(tester, strokePicker);
    await closeStyles(tester);
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
    expect(await strokeWidth(tester), original);
    await tester.tap(find.byTooltip('截图帮助'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await strokeWidth(tester), original);
    final moving = await tester.startGesture(
      const Offset(180, 210),
      kind: PointerDeviceKind.mouse,
    );
    await moving.moveBy(const Offset(0, 20));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await moving.moveBy(const Offset(0, 20));
    await moving.up();
    await tester.pump();
    expect(await strokeWidth(tester), original + 1);
    final moved = await exportedImage(tester);
    expect(moved.getPixel(130, 150).r, 108);
    expect(moved.getPixel(130, 110).g, 255);
    await undo(tester);
    await tester.tapAt(const Offset(180, 210));
    await tester.pump();
    expect(await strokeWidth(tester), original);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(await strokeWidth(tester), original + 1);
    await undo(tester);
    await tester.tapAt(const Offset(180, 210));
    await tester.pump();
    expect(await strokeWidth(tester), original);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长图绘制中可调粗细，样式菜单显示当前值且不显示字号', (tester) async {
    await openLongEditor(tester);
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final canvas = tester.getRect(
      find.byKey(const ValueKey('long-screenshot-canvas')),
    );
    final gesture = await tester.startGesture(
      canvas.topLeft + const Offset(80, 100),
    );
    await gesture.moveBy(const Offset(100, 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await gesture.moveBy(const Offset(30, 20));
    await gesture.up();
    await settleImages(tester);
    await tester.tap(find.byTooltip('标注样式'));
    await tester.pumpAndSettle();
    expect(sizeValue(tester, strokePicker), 4);
    expect(fontPicker, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(sizeValue(tester, strokePicker), 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await undo(tester);
    final undoButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.undo),
    );
    expect(undoButton.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('截图可先选箭头样式，再选中已有箭头修改并撤销', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('箭头'));
    await tester.pump();
    await chooseArrowStyle(tester, ArrowStyle.doubleHeaded);
    await tester.dragFrom(const Offset(120, 210), const Offset(120, 0));
    await settleImages(tester);
    await tester.tap(find.byTooltip('选择 / 调整'));
    await tester.pump();
    expect(find.byType(ArrowStylePicker), findsNothing);
    await tester.tapAt(const Offset(184, 210));
    await tester.pump();
    expect(
      tester.widget<ArrowStylePicker>(find.byType(ArrowStylePicker)).value,
      ArrowStyle.doubleHeaded,
    );
    await chooseArrowStyle(tester, ArrowStyle.outlined);
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await settleImages(tester);
    await tester.tapAt(const Offset(184, 210));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester.widget<ArrowStylePicker>(find.byType(ArrowStylePicker)).value,
      ArrowStyle.doubleHeaded,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('多屏截图的箭头菜单完整落在工具栏所在的显示器', (tester) async {
    await mountTwoDisplays(tester);
    // The second screen starts lower than its neighbor and is scaled at 150%.
    await tester.dragFrom(
      const Offset(860, 320) / 1.5,
      const Offset(510, 300) / 1.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('箭头'));
    await tester.pump();
    await tester.tap(find.byTooltip('箭头样式'));
    await tester.pumpAndSettle();
    final first = tester.getRect(
      find.widgetWithText(PopupMenuItem<ArrowStyle>, '单向'),
    );
    final last = tester.getRect(
      find.widgetWithText(PopupMenuItem<ArrowStyle>, '折线'),
    );
    expect(first.left, greaterThanOrEqualTo(800 / 1.5));
    expect(first.top, greaterThanOrEqualTo(160 / 1.5));
    expect(last.right, lessThanOrEqualTo(1600 / 1.5));
    expect(last.bottom, lessThanOrEqualTo(800 / 1.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄窗口从更多选箭头后可直接切换款式，长图顶栏保持单行', (tester) async {
    await openLongEditor(tester);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(840, 1000);
    await tester.pump();
    final bar = find.byKey(const ValueKey('long-editor-toolbar'));
    final bounds = tester.getRect(bar);
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('箭头'));
    await tester.pumpAndSettle();
    expect(
      bounds.contains(tester.getCenter(find.byType(ArrowStylePicker))),
      isTrue,
    );
    await chooseArrowStyle(tester, ArrowStyle.outlined);
    expect(tester.getRect(bar), bounds);
    expect(bounds.contains(tester.getCenter(find.byTooltip('关闭'))), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('跨屏拖动已有选区后工具跟随到目标屏，输出使用冻结画面的像素尺寸', (tester) async {
    await mountTwoDisplays(tester);
    await tester.dragFrom(
      const Offset(120, 250) / 1.5,
      const Offset(300, 150) / 1.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('选择 / 调整'));
    await tester.pump();
    await tester.dragFrom(
      const Offset(200, 265) / 1.5,
      const Offset(840, 0) / 1.5,
    );
    await tester.pump();
    expect(tester.getRect(toolbar).left, greaterThanOrEqualTo(800 / 1.5));
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    final commit = calls.singleWhere((c) => c.method == 'commit');
    final result = img.decodePng(
      (commit.arguments as Map)['png'] as Uint8List,
    )!;
    expect([result.width, result.height], [300, 150]);
    expect(result.getPixel(40, 40).a, 255);
  });

  testWidgets('错位显示器可跨屏框选，长图提示收窄，普通 PNG 保留透明空角', (tester) async {
    await mountTwoDisplays(tester);
    await tester.dragFrom(
      const Offset(1050, 330) / 1.5,
      const Offset(-400, -240) / 1.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await tester.pump();
    final warning = find.textContaining('显示器之间的空隙');
    expect(warning, findsOneWidget);
    final warningBounds = tester.getRect(warning);
    expect(warningBounds.left, greaterThanOrEqualTo(0));
    expect(warningBounds.right, lessThanOrEqualTo(800 / 1.5));
    expect(warningBounds.bottom, lessThanOrEqualTo(600 / 1.5));
    expect(calls.where((c) => c.method == 'beginScroll'), isEmpty);
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    final commit = calls.singleWhere((c) => c.method == 'commit');
    final result = img.decodePng(
      (commit.arguments as Map)['png'] as Uint8List,
    )!;
    expect([result.width, result.height], [400, 240]);
    expect(result.getPixel(50, 20).a, 255);
    expect(result.getPixel(200, 20).a, 0);
    expect(result.getPixel(200, 120).a, 255);
  });

  testWidgets('从另一屏开始框选，修正空角选区后允许跨屏长截图', (tester) async {
    await mountTwoDisplays(tester);
    await tester.dragFrom(
      const Offset(1050, 330) / 1.5,
      const Offset(-400, -240) / 1.5,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await tester.pump();
    expect(find.textContaining('显示器之间的空隙'), findsOneWidget);
    // Lift the visible top-left handle into the area shared by both displays.
    await tester.tap(find.byTooltip('选择 / 调整'));
    await tester.pump();
    await tester.dragFrom(
      const Offset(650, 90) / 1.5,
      const Offset(0, 120) / 1.5,
    );
    await tester.pump();
    expect(find.textContaining('显示器之间的空隙'), findsNothing);
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    final args =
        calls.singleWhere((c) => c.method == 'beginScroll').arguments as Map;
    expect(
      [args['x'], args['y'], args['width'], args['height']],
      [650, 210, 400, 120],
    );
    await tester.tap(find.byTooltip('取消长截图（Esc）'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无需点击截图画面，首次 Esc 取消，再次打开时 C 复制并退出', (tester) async {
    await mount(tester);
    Future<void> windowFocus(ViewFocusState state) async {
      tester.binding.platformDispatcher.onViewFocusChange?.call(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: state,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
    }

    await windowFocus(ViewFocusState.focused);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, 1);
    expect(calls.where((c) => c.method == 'copyColor'), isEmpty);

    await windowFocus(ViewFocusState.unfocused);
    await fromHost(tester, 'reset', 1);
    await fromHost(tester, 'start', snapshot(2));
    await settleImages(tester);
    await windowFocus(ViewFocusState.focused);
    await fromHost(tester, 'localShortcut', {'session': 2, 'key': 'copyColor'});
    final copy = calls.singleWhere((c) => c.method == 'copyColor');
    expect(copy.arguments, {'token': 2, 'hex': '#FFFFFF'});
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, 2);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);

    await fromHost(tester, 'reset', 2);
    await fromHost(tester, 'start', snapshot(3));
    await settleImages(tester);
    // The OS can deliver a key to the reopened HWND before Flutter restores
    // its widget focus. Hiding a view parks focus at the root scope.
    await windowFocus(ViewFocusState.unfocused);
    final previousCloseCount = calls.where((c) => c.method == 'close').length;
    await fromHost(tester, 'localShortcut', {'session': 2, 'key': 'escape'});
    expect(
      calls.where((c) => c.method == 'close'),
      hasLength(previousCloseCount),
    );
    await fromHost(tester, 'localShortcut', {'session': 3, 'key': 'escape'});
    expect(calls.last.method, 'close');
    expect(calls.last.arguments, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('贴图提交最终选区 PNG 和原屏幕位置', (tester) async {
    await mount(tester);
    final pin = find.widgetWithText(TextButton, '贴图');
    final toolbarColor = tester
        .widget<Material>(
          find.descendant(of: toolbar, matching: find.byType(Material)).first,
        )
        .color!;
    // White under the translucent toolbar is the lowest-contrast screenshot.
    final surface = Color.alphaBlend(toolbarColor, Colors.white);
    expect(tester.widget<TextButton>(pin).onPressed, isNull);
    expectPinContrast(tester, surface);
    await tester.tapAt(const Offset(100, 150));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(pin).onPressed, isNotNull);
    expectPinContrast(tester, surface);
    expect(find.byTooltip('贴图并计入历史'), findsOneWidget);
    await tester.tap(pin);
    await settleImages(tester);
    final args =
        calls.singleWhere((c) => c.method == 'commit').arguments as Map;
    expect(args['pin'], true);
    expect([args['x'], args['y']], [50, 100]);
    final image = img.decodePng(args['png'] as Uint8List)!;
    expect([image.width, image.height], [400, 300]);
    expect(calls.last.method, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取色器从初始光标采样，框选和全屏后按物理像素取色，C 复制并退出', (tester) async {
    await mount(tester, pending: false);
    tester.view.devicePixelRatio = 1.5;
    final data = snapshot(1);
    data['initialCursorX'] = 27;
    data['initialCursorY'] = 36;
    final pixels = data['pixels']! as Uint8List;
    pixels.setRange((36 * 800 + 27) * 4, (36 * 800 + 27) * 4 + 4, [
      0x12,
      0x34,
      0x56,
      255,
    ]);
    pixels.setRange((585 * 800 + 780) * 4, (585 * 800 + 780) * 4 + 4, [
      0xAB,
      0xCD,
      0xEF,
      255,
    ]);
    await fromHost(tester, 'start', data);
    await settleImages(tester);
    expect(find.text('#563412'), findsOneWidget);
    expect(find.text('RGB(86, 52, 18)'), findsOneWidget);

    await tester.dragFrom(const Offset(50, 100), const Offset(80, 70));
    await tester.pump();
    final picker = find.byKey(const ValueKey('screenshot-color-picker'));
    expect(picker, findsOneWidget);
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    expect(picker, findsOneWidget);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: const Offset(510, 380));
    await pointer.moveTo(const Offset(520, 390));
    await tester.pump();
    final card = tester.widget<ScreenshotColorPicker>(
      find.byType(ScreenshotColorPicker),
    );
    expect(
      card.pixel,
      const Offset(780, 585),
      reason: 'pointer ${card.anchor}',
    );
    expect(find.text('#EFCDAB'), findsOneWidget);
    expect(tester.getRect(picker).right, lessThan(520));
    expect(tester.getRect(picker).bottom, lessThanOrEqualTo(400));
    failColorCopy = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(find.text('色值复制失败，按 C 重试'), findsOneWidget);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    failColorCopy = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    final copy = calls.lastWhere((c) => c.method == 'copyColor');
    expect(copy.arguments, {'token': 1, 'hex': '#EFCDAB'});
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    expect(calls.last.method, 'close');
    await pointer.removePointer();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取色器设置只决定初始状态，F2 只切换本次，文字输入和组合键不复制颜色', (tester) async {
    await mount(tester, pending: false);
    final picker = find.byKey(const ValueKey('screenshot-color-picker'));
    await fromHost(tester, 'start', snapshot(1)..['showColorPicker'] = false);
    await settleImages(tester);
    expect(picker, findsNothing);
    await fromHost(tester, 'localShortcut', {
      'session': 1,
      'key': 'togglePicker',
    });
    await tester.pump();
    expect(picker, findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('文字'));
    await tester.pump();
    await tester.tapAt(const Offset(120, 170));
    await tester.pump();
    expect(calls.lastWhere((c) => c.method == 'setLocalShortcuts').arguments, {
      'session': 1,
      'enabled': false,
    });
    await fromHost(tester, 'localShortcut', {'session': 1, 'key': 'copyColor'});
    await fromHost(tester, 'localShortcut', {'session': 1, 'key': 'escape'});
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    expect(picker, findsOneWidget);
    expect(calls.where((c) => c.method == 'copyColor'), isEmpty);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    await tester.tap(find.byTooltip('选择 / 调整'));
    await tester.pump();
    expect(calls.lastWhere((c) => c.method == 'setLocalShortcuts').arguments, {
      'session': 1,
      'enabled': true,
    });
    await fromHost(tester, 'reset', 1);
    await fromHost(tester, 'start', snapshot(2)..['showColorPicker'] = false);
    await settleImages(tester);
    expect(picker, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    expect(find.textContaining('400 × 380 px'), findsOneWidget);
    await tester.tap(find.byTooltip('完成采集，进入编辑'));
    await settleImages(tester);
    expect(
      find.byKey(const ValueKey('long-screenshot-editor')),
      findsOneWidget,
    );
    expect(
      calls.singleWhere((c) => c.method == 'longEditorReady').arguments,
      1,
    );
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('放大长图'));
    await tester.pump();
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('实心遮盖'));
    await tester.pumpAndSettle();
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
    // Moving a finished capture to another monitor changes logical viewport
    // size and DPI. The annotation and undo stack stay in image coordinates.
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1040, 780);
    await tester.pump();
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await tester.pump();
    await tester.tap(find.byTooltip('重做（Ctrl + Shift + Z）'));
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

  testWidgets('长图编辑的标题、操作和窗控位于同一行，只有标题区触发窗口拖动', (tester) async {
    await openLongEditor(tester);
    tester.view.physicalSize = const Size(1600, 900);
    await tester.pump();
    final title = find.byKey(const ValueKey('long-editor-title'));
    final bar = tester.getRect(
      find.byKey(const ValueKey('long-editor-toolbar')),
    );
    expect(bar.top, 0);
    expect(bar.width, 1600);
    expect(find.textContaining('理梦剪藏'), findsOneWidget);
    expect(find.textContaining('400 × 300'), findsOneWidget);
    expectPinContrast(tester, Colors.white);
    for (final control in [
      title,
      find.byTooltip('矩形'),
      find.byTooltip('放大长图'),
      find.text('适应宽度'),
      find.byTooltip('贴图并计入历史'),
      find.byTooltip('完成（Enter）'),
      find.byTooltip('最小化'),
      find.byTooltip('最大化'),
      find.byTooltip('关闭'),
    ]) {
      final center = tester.getCenter(control);
      expect(bar.contains(center), isTrue, reason: control.toString());
      expect(center.dy, closeTo(bar.center.dy, 2), reason: control.toString());
    }

    List<String> actions() => [
      for (final call in calls.where((c) => c.method == 'longEditorWindow'))
        (call.arguments as Map)['action'] as String,
    ];
    await tester.drag(
      find.byTooltip('矩形'),
      const Offset(20, 65),
      kind: PointerDeviceKind.mouse,
    );
    expect(actions(), isEmpty);
    await tester.drag(
      title,
      const Offset(100, 70),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(actions(), ['drag']);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(title);
    await tester.pump();
    expect(actions().last, 'toggleMaximize');
    await fromHost(tester, 'longEditorWindowState', {
      'session': 2,
      'maximized': true,
    });
    expect(find.byTooltip('最大化'), findsOneWidget);
    await fromHost(tester, 'longEditorWindowState', {
      'session': 1,
      'maximized': true,
    });
    await tester.tap(find.byTooltip('还原'));
    await tester.tap(find.byTooltip('最小化'));
    expect(actions(), ['drag', 'toggleMaximize', 'toggleMaximize', 'minimize']);
    for (final call in calls.where((c) => c.method == 'longEditorWindow')) {
      expect((call.arguments as Map)['session'], 1);
    }
    await tester.tap(find.byTooltip('关闭'));
    await settleImages(tester);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    expect(calls.last.method, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('高 DPI 窄窗口的更多工具、样式和缩放可操作且顶栏高度不变', (tester) async {
    await openLongEditor(tester);
    final bar = find.byKey(const ValueKey('long-editor-toolbar'));
    final originalHeight = tester.getSize(bar).height;
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(840, 1000);
    await tester.pump();
    final bounds = tester.getRect(bar);
    expect(bounds.height, originalHeight);
    expect(bounds.width, 420);
    for (final tooltip in ['更多工具', '缩放选项', '最小化', '最大化', '关闭']) {
      expect(
        bounds.contains(tester.getCenter(find.byTooltip(tooltip))),
        isTrue,
      );
    }
    await tester.tap(find.byTooltip('更多工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('矩形'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('标注样式'));
    await tester.pumpAndSettle();
    expect(find.text('粗细'), findsOneWidget);
    final strokeWidth = find.byKey(const ValueKey('screenshot-stroke-width'));
    final beforeWidth = tester.widget<Slider>(strokeWidth).value;
    await tester.drag(strokeWidth, const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(strokeWidth).value, greaterThan(beforeWidth));
    expect(tester.getRect(bar), bounds);
    // Dismiss the popover by clicking the canvas outside it.
    await tester.tapAt(const Offset(200, 460));
    await tester.pumpAndSettle();
    final canvas = find.byKey(const ValueKey('long-screenshot-canvas'));
    final before = tester.getSize(canvas).width;
    await tester.tap(find.byTooltip('缩放选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放大长图'));
    await tester.pumpAndSettle();
    expect(tester.getSize(canvas).width, greaterThan(before));
    await tester.tap(find.byTooltip('缩放选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('适应宽度'));
    await tester.pumpAndSettle();
    expect(tester.getSize(canvas).width, before);
    expect(tester.getRect(bar), bounds);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自动滚动到底冻结预览，直到用户点击完成才打开编辑器', (tester) async {
    autoScroll = true;
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    final bottom = find.textContaining('可能已到底');
    for (var i = 0; i < 160 && bottom.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(bottom, findsOneWidget);
    expect(find.textContaining('400 × 420 px'), findsOneWidget);
    expect(find.byKey(const ValueKey('long-screenshot-editor')), findsNothing);
    final count = calls.length;
    await tester.pump(const Duration(seconds: 3));
    expect(calls.length, count);
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.tap(find.byTooltip('完成采集，进入编辑'));
    await settleImages(tester);
    expect(
      find.byKey(const ValueKey('long-screenshot-editor')),
      findsOneWidget,
    );
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('无法自动滚动时可在本次采集中手动接管并继续追加', (tester) async {
    autoScroll = failScrollStep = true;
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    expect(find.textContaining('窗口不接受自动滚动'), findsOneWidget);
    await tester.tap(find.text('手动接管'));
    scrollTop = 80;
    await settleImages(tester);
    await settleImages(tester);
    expect(find.textContaining('400 × 380 px'), findsOneWidget);
    expect(calls.where((c) => c.method == 'scrollStep'), hasLength(1));
    expect(calls.where((c) => c.method == 'beginScroll'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('取消自动长截图后等待样式保存期间不再发送滚动', (tester) async {
    autoScroll = true;
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    expect(calls.where((c) => c.method == 'scrollStep'), isNotEmpty);
    pendingStyleSave = Completer<void>();
    await tester.tap(find.byTooltip('取消长截图（Esc）'));
    final count = calls.length;
    await settleImages(tester);
    expect(calls.length, count);
    pendingStyleSave!.complete();
    await tester.pump();
    expect(calls.last.method, 'close');
    expect(calls.where((c) => c.method == 'commit'), isEmpty);
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

  testWidgets('工具栏默认贴选区左下角，非全屏也能从空白处拖动并保持位置', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    expect(tester.getRect(toolbar).bottom, 400);
    final beforeDrag = tester.getRect(toolbar);
    // Pressing a button never drags the bar.
    await tester.drag(
      find.byTooltip('矩形'),
      const Offset(0, -60),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(tester.getRect(toolbar), beforeDrag);
    await dragToolbar(tester, const Offset(0, -60), hold: true);
    expect(tester.getRect(toolbar).top, beforeDrag.top - 60);
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    // A tool switch keeps the manual placement of the same selection.
    expect(tester.getRect(toolbar).top, beforeDrag.top - 60);
    // Dragging keeps the bar inside the screen.
    await dragToolbar(tester, const Offset(2000, 2000));
    expect(tester.getRect(toolbar).right, lessThanOrEqualTo(800));
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final pixelRatio in [1.0, 1.5, 2.0]) {
    testWidgets('缩放 $pixelRatio 时工具栏贴选区左下角', (tester) async {
      await mount(tester);
      tester.view.devicePixelRatio = pixelRatio;
      await tester.pump();
      await tester.dragFrom(
        Offset(100, 400) / pixelRatio,
        Offset(350, 180) / pixelRatio,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('选择 / 调整'));
      await tester.pump();
      expect(tester.getRect(toolbar).bottom, closeTo(580 / pixelRatio, .01));
      await tester.tap(find.byTooltip('矩形'));
      await tester.pump();
      final styledToolbar = tester.getRect(toolbar);
      // The style popup leaves the bar a single row at the selection corner.
      expect(styledToolbar.bottom, closeTo(580 / pixelRatio, .01));
      expect(
        tester
            .getRect(find.text('350 × 180 px'))
            .overlaps(tester.getRect(toolbar)),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('全屏按住工具栏空白处可拖动且不越界，撤销全屏后保持手动位置', (tester) async {
    await mount(tester);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    await tester.tapAt(const Offset(150, 225));
    await tester.pump();
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    final before = tester.getRect(toolbar);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    await dragToolbar(tester, const Offset(120, -160), hold: true);
    await tester.pump();
    final moved = tester.getRect(toolbar);
    expect(moved.left, greaterThan(before.left + 80));
    expect(moved.top, lessThan(before.top - 120));
    expect(find.text('800 × 600 px'), findsOneWidget);
    await dragToolbar(tester, const Offset(2000, 2000));
    await tester.pump();
    expect(tester.getRect(toolbar).right, lessThanOrEqualTo(1200));
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(900));
    final dragged = tester.getRect(toolbar);
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(900));
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await tester.pump();
    expect(find.text('400 × 300 px'), findsOneWidget);
    // A manual placement now survives selection changes; the bar stays pinned
    // to the bottom-right edge even if undo adds a redo button (width change).
    expect(tester.getRect(toolbar).bottom, dragged.bottom);
    expect(tester.getRect(toolbar).right, dragged.right);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全屏工具栏行内空白可拖动，按钮与样式弹层不拖动工具栏', (tester) async {
    await mount(tester);
    await tester.tap(find.byTooltip('当前屏幕全屏'));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final beforeDrag = tester.getRect(toolbar);
    final blank = Offset(beforeDrag.left + 3, beforeDrag.center.dy);
    await tester.dragFrom(
      blank,
      const Offset(0, -90),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final moved = tester.getRect(toolbar);
    expect(moved.top, lessThan(beforeDrag.top - 50));
    expect(calls.where((c) => c.method == 'commit'), isEmpty);

    await tester.drag(
      find.byTooltip('矩形'),
      const Offset(0, 80),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(tester.getRect(toolbar), moved);
    await openStyles(tester);
    final widthControl = find.byKey(const ValueKey('screenshot-stroke-width'));
    final beforeWidth = tester.widget<Slider>(widthControl).value;
    await tester.drag(
      widthControl,
      const Offset(30, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(tester.widget<Slider>(widthControl).value, greaterThan(beforeWidth));
    await closeStyles(tester);
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

  testWidgets('接近整屏的非全屏选区默认放在选区左下角，允许重叠', (tester) async {
    await mount(tester);
    await tester.dragFrom(const Offset(20, 70), const Offset(750, 520));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    final bar = tester.getRect(toolbar);
    expect(bar.bottom, 590);
    expect(bar.left, greaterThanOrEqualTo(8));
    // A single row: the bar never grows into a stacked block near full screen.
    expect(bar.height, lessThan(60));
    expect(bar.overlaps(const Rect.fromLTRB(20, 70, 770, 590)), isTrue);
    // The size badge follows without hiding behind the bar.
    expect(tester.getRect(find.text('750 × 520 px')).overlaps(bar), isFalse);
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

  testWidgets('长图标题栏关闭保留部分成功确认和样式，只响应该会话一次', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    await settleImages(tester);
    await tester.tap(find.byTooltip('完成采集，进入编辑'));
    await settleImages(tester);
    await tester.pump(const Duration(seconds: 1));
    commitReply = {'error': '副本已保存，复制失败', 'locked': true};
    await tester.tap(find.byTooltip('完成（Enter）'));
    await settleImages(tester);
    await fromHost(tester, 'requestClose', 0);
    expect(find.byType(AlertDialog), findsNothing);
    await fromHost(tester, 'requestClose', 1);
    await fromHost(tester, 'requestClose', 1);
    await tester.pumpAndSettle();
    expect(find.text('退出截图结果处理？'), findsOneWidget);
    await tester.tap(find.text('继续处理'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    await fromHost(tester, 'requestClose', 1);
    await tester.pumpAndSettle();
    pendingStyleSave = Completer<void>();
    await tester.tap(find.text('退出'));
    await tester.pump(const Duration(milliseconds: 300));
    await fromHost(tester, 'requestClose', 1);
    expect(calls.where((c) => c.method == 'styles'), hasLength(1));
    expect(calls.where((c) => c.method == 'close'), isEmpty);
    pendingStyleSave!.complete();
    await tester.pump();
    await fromHost(tester, 'requestClose', 1);
    expect(calls.singleWhere((c) => c.method == 'close').arguments, 1);
    expect(calls.where((c) => c.method == 'styles'), hasLength(1));
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
    expect(calls.lastWhere((c) => c.method == 'setLocalShortcuts').arguments, {
      'session': 1,
      'enabled': false,
    });
    await fromHost(tester, 'localShortcut', {'session': 1, 'key': 'escape'});
    expect(find.text('退出截图结果处理？'), findsOneWidget);
    expect(calls.where((c) => c.method == 'close'), isEmpty);
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

  testWidgets('取色器隐藏时 C 仍复制并退出', (tester) async {
    await mount(tester, pending: false);
    await fromHost(tester, 'start', snapshot(1)..['showColorPicker'] = false);
    await settleImages(tester);
    expect(find.byKey(const ValueKey('screenshot-color-picker')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    final copy = calls.singleWhere((c) => c.method == 'copyColor');
    expect(copy.arguments, {'token': 1, 'hex': '#FFFFFF'});
    expect(calls.last.method, 'close');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重新框选清空选区与标注，撤销可恢复', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    await tester.dragFrom(const Offset(120, 190), const Offset(80, 60));
    await settleImages(tester);
    expect(find.text('400 × 300 px'), findsOneWidget);
    await tester.tap(find.byTooltip('重新框选'));
    await tester.pump();
    expect(find.text('400 × 300 px'), findsNothing);
    expect(find.textContaining('拖动框选'), findsOneWidget);
    await tester.tap(find.byTooltip('撤销（Ctrl + Z）'));
    await tester.pump();
    expect(find.text('400 × 300 px'), findsOneWidget);
    final result = await exportedImage(tester);
    expect(result.getPixel(70, 120).g, 87);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自定义颜色输入 HEX 应用到标注', (tester) async {
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('矩形'));
    await tester.pump();
    await openStyles(tester);
    await tester.tap(find.byKey(const ValueKey('screenshot-custom-color')));
    await tester.pumpAndSettle();
    expect(find.text('自定义颜色'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-custom-color-input')),
      '#123456',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('screenshot-custom-color-apply')),
    );
    await tester.pumpAndSettle();
    expect(find.text('自定义颜色'), findsNothing);
    await closeStyles(tester);
    await tester.dragFrom(const Offset(120, 190), const Offset(80, 60));
    await settleImages(tester);
    final result = await exportedImage(tester);
    final pixel = result.getPixel(70, 120);
    expect([pixel.r, pixel.g, pixel.b], [0x12, 0x34, 0x56]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长图采集显示屏数，到底暂停后可继续向下采集', (tester) async {
    autoScroll = true;
    await mount(tester);
    await tester.tapAt(const Offset(100, 150));
    await tester.pump();
    await tester.tap(find.byTooltip('长截图'));
    final bottom = find.textContaining('可能已到底');
    for (var i = 0; i < 160 && bottom.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(bottom, findsOneWidget);
    expect(find.textContaining('已采集 2 屏'), findsOneWidget);
    final resume = find.byKey(const ValueKey('scroll-resume'));
    expect(resume, findsOneWidget);
    final steps = calls.where((c) => c.method == 'scrollStep').length;
    await tester.tap(resume);
    await tester.pump();
    expect(find.textContaining('正在自动向下滚动'), findsOneWidget);
    for (
      var i = 0;
      i < 40 && calls.where((c) => c.method == 'scrollStep').length <= steps;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      calls.where((c) => c.method == 'scrollStep').length,
      greaterThan(steps),
    );
    await tester.tap(find.byTooltip('取消长截图（Esc）'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长图编辑取色器采样包含标注，C 复制退出', (tester) async {
    await openLongEditor(tester);
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pump();
    await tester.tap(find.byTooltip('实心遮盖'));
    await tester.pump();
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('long-screenshot-canvas')),
    );
    await tester.dragFrom(origin + const Offset(60, 90), const Offset(120, 60));
    await settleImages(tester);
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: origin + const Offset(100, 110));
    await pointer.moveTo(origin + const Offset(100, 110));
    await tester.pump();
    expect(find.text('#111827'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    final copy = calls.lastWhere((c) => c.method == 'copyColor');
    expect(copy.arguments, {'token': 1, 'hex': '#111827'});
    expect(calls.last.method, 'close');
    await pointer.removePointer();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
