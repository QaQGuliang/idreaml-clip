import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/json_document.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';
import 'package:idreaml_clip/src/ui/json_split_preview.dart';
import 'package:idreaml_clip/src/ui/json_tree_view.dart';

import 'support/json_samples.dart';

void main() {
  Future<void> mount(WidgetTester tester, String content) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: JsonSplitPreview(content: content)),
      ),
    );
    await tester.pumpAndSettle();
  }

  String code(WidgetTester tester) => tester
      .widgetList<Text>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('json-code-'),
        ),
      )
      .map((text) => text.textSpan!.toPlainText())
      .join('\n');

  testWidgets('转义样本显示分层键值，对象数组分别折叠，原文保留', (tester) async {
    await mount(tester, escapedJsonSample);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('json-raw-text')))
          .data,
      escapedJsonSample,
    );
    expect(code(tester), contains('"city": "杭州"'));
    expect(code(tester), contains('"Java"'));
    await tester.tap(find.byTooltip('折叠对象 address'));
    await tester.pumpAndSettle();
    expect(code(tester), isNot(contains('"city"')));
    expect(code(tester), contains('"Java"'));
    expect(code(tester), contains('2 项'));
    await tester.tap(find.byTooltip('折叠数组 tags'));
    await tester.pumpAndSettle();
    expect(code(tester), isNot(contains('"Java"')));
    expect(code(tester), contains('3 项'));
    await tester.tap(find.byTooltip('展开对象 address'));
    await tester.pumpAndSettle();
    expect(code(tester), contains('"city": "杭州"'));
    expect(code(tester), isNot(contains('"Java"')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('全部折叠与展开，折叠时复制仍得到完整格式化 JSON，换条目重置状态', (tester) async {
    await mount(tester, escapedJsonSample);
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
    await tester.tap(find.byTooltip('折叠全部'));
    await tester.pumpAndSettle();
    expect(code(tester), isNot(contains('"address"')));
    await tester.tap(find.byTooltip('复制格式化 JSON'));
    await tester.pumpAndSettle();
    expect(jsonDecode(copied!), parseJsonDocument(escapedJsonSample).value);
    expect(copied, contains('\n  "name"'));
    await tester.tap(find.byTooltip('展开全部'));
    await tester.pumpAndSettle();
    expect(code(tester), contains('"city": "杭州"'));
    await tester.tap(find.byTooltip('折叠全部'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: JsonSplitPreview(content: '{"changed":[true,false]}'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(code(tester), contains('"changed": ['));
    expect(code(tester), contains('false'));
    expect(code(tester), isNot(contains('"name"')));
    expect(find.byType(JsonTreeView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
