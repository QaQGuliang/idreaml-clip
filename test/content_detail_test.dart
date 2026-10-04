import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/clipboard_item.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/ui/clipboard_image.dart';
import 'package:idreaml_clip/src/ui/shortcut_dialog.dart';
import 'package:idreaml_clip/src/ui/json_split_preview.dart';
import 'package:idreaml_clip/src/ui/json_tree_view.dart';

import 'support/clipboard_test_support.dart';

ClipboardItem item(String id, ClipboardContent content) => ClipboardItem(
  id: id,
  type: content.type,
  content: content.content,
  contentHash: content.hash,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  lastUsedAt: DateTime(2026),
  copyCount: 1,
  favorite: false,
  deleted: false,
  deviceId: 'test',
  syncState: 'dirty',
);

void main() {
  late MemoryClipboardRepository repository;
  late AppController controller;
  late RecordingDesktopService desktop;
  final png = ClipboardContent.image(
    img.encodePng(img.Image(width: 3, height: 2)),
    'image/png',
  );
  final jpg = ClipboardContent.image(
    img.encodeJpg(img.Image(width: 3, height: 2)),
    'image/jpeg',
  );

  setUp(() async {
    repository = MemoryClipboardRepository(count: 0);
    repository.items.addAll([
      item('json', const ClipboardContent.text('{"hello": "world"}')),
      item('png', png),
      item('jpg', jpg),
      item('text', const ClipboardContent.text('plain text')),
    ]);
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

  testWidgets('详情角标随所选内容切换 JSON、PNG、JPG、TEXT，图片显示预览', (tester) async {
    await mount(tester);
    expect(find.text('JSON'), findsOneWidget);
    await tester.tap(find.text('PNG 图片'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('PNG'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final image = tester
        .widgetList<ClipboardImage>(find.byType(ClipboardImage))
        .singleWhere((image) => !image.thumbnail);
    expect(image.item.id, 'png');
    await tester.tap(find.text('JPG 图片'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('JPG'), findsOneWidget);
    await tester.tap(find.text('plain text'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('TEXT'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(JsonSplitPreview), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('JSON 详情左侧保留原文，右侧解析缩进，复制及切换条目使用正确内容', (tester) async {
    const raw = '  {"name":"理梦剪藏","items":[1,true,null,{"text":"a\\nb"}]}\n';
    const array = '[{"id":2},false]';
    repository.items.insertAll(0, [
      item('nested', const ClipboardContent.text(raw)),
      item('array', const ClipboardContent.text(array)),
      item('invalid', const ClipboardContent.text('{invalid JSON')),
    ]);
    await controller.reload();
    controller.selectHistory('nested');
    await mount(tester);
    final rawFinder = find.byKey(const ValueKey('json-raw-text'));
    final formattedFinder = find.byType(JsonTreeView);
    expect(find.text('原始文本'), findsOneWidget);
    expect(find.text('格式化 JSON'), findsOneWidget);
    expect(
      tester.getTopLeft(rawFinder).dx,
      lessThan(tester.getTopLeft(formattedFinder).dx),
    );
    expect(tester.widget<SelectableText>(rawFinder).data, raw);
    final formatted = tester
        .widget<JsonTreeView>(formattedFinder)
        .document
        .formatted;
    expect(formatted, contains('\n  "name": "理梦剪藏",\n'));
    expect(jsonDecode(formatted), jsonDecode(raw));
    String? copied;
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
    await tester.tap(find.widgetWithText(FilledButton, '复制内容'));
    await tester.pumpAndSettle();
    expect(copied, raw);
    expect(repository.items.first.content, raw);
    controller.selectHistory('array');
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(rawFinder).data, array);
    expect(
      tester.widget<JsonTreeView>(formattedFinder).document.value,
      jsonDecode(array),
    );
    controller.selectHistory('invalid');
    await tester.pumpAndSettle();
    expect(find.byType(JsonSplitPreview), findsNothing);
    expect(find.text('TEXT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长 JSON 在窄窗口中保持左右布局，两侧独立滚动', (tester) async {
    final raw = jsonEncode({
      'items': List.generate(60, (i) => {'id': i, 'name': '测试内容 $i'}),
    });
    repository.items.insert(0, item('long', ClipboardContent.text(raw)));
    await controller.reload();
    controller.selectHistory('long');
    controller.resizeWorkspace(sidebarWidth: 320, historyFraction: 1);
    await mount(tester, size: const Size(900, 620));
    final rawFinder = find.byKey(const ValueKey('json-raw-text'));
    final formattedFinder = find.byType(JsonTreeView);
    final rawScroll = tester
        .widget<SingleChildScrollView>(
          find
              .ancestor(
                of: rawFinder,
                matching: find.byType(SingleChildScrollView),
              )
              .first,
        )
        .controller!;
    final formattedScroll = tester
        .widget<ListView>(find.byKey(const ValueKey('json-tree-scroll')))
        .controller!;
    expect(
      tester.getTopLeft(rawFinder).dx,
      lessThan(tester.getTopLeft(formattedFinder).dx),
    );
    await tester.drag(formattedFinder, const Offset(0, -140));
    await tester.pumpAndSettle();
    expect(formattedScroll.offset, greaterThan(0));
    expect(rawScroll.offset, 0);
    final previous = formattedScroll.offset;
    await tester.drag(
      find
          .ancestor(of: rawFinder, matching: find.byType(SingleChildScrollView))
          .first,
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();
    expect(rawScroll.offset, greaterThan(0));
    expect(formattedScroll.offset, previous);
    expect(tester.takeException(), isNull);
  });

  testWidgets('快捷面板图片显示缩略图和格式，不暴露 base64 字符串', (tester) async {
    await controller.enterQuickMode();
    await mount(tester, size: const Size(347, 427));
    expect(find.text('PNG 图片'), findsOneWidget);
    expect(find.text(png.content), findsNothing);
    expect(find.byType(ClipboardImage), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置可进入快捷键编辑、修改和恢复默认，取消不更改配置', (tester) async {
    await controller.setPage(AppPage.settings);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('custom-shortcut-button')));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shortcut-recorder')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(
      find.text(Platform.isMacOS ? 'Option + Q' : 'Alt + Q'),
      findsOneWidget,
    );
    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    expect(
      find.text(Platform.isMacOS ? 'Option + Q' : 'Alt + Q'),
      findsNothing,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      controller.quickShortcut.sameCombination(QuickShortcut.platformDefault()),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
