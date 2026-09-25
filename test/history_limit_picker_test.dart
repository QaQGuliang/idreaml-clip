import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';

import 'support/clipboard_test_support.dart';

class _Repository extends MemoryClipboardRepository {
  final appliedLimits = <int>[];

  @override
  Future<void> enforceHistoryLimit(int limit) async => appliedLimits.add(limit);
}

void main() {
  late _Repository repository;
  late AppController controller;
  final picker = find.byKey(const ValueKey('history-limit-picker'));
  final input = find.byKey(const ValueKey('custom-history-limit'));

  setUp(() async {
    repository = _Repository();
    controller = testController(repository);
    await controller.setPage(AppPage.settings);
  });
  tearDown(() => controller.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: RecordingDesktopService(controller),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCustom(WidgetTester tester) async {
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…').last);
    await tester.pumpAndSettle();
  }

  testWidgets('预设数量继续可用，自定义数量保存后显示并可再次编辑', (tester) async {
    await mount(tester);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5,000 条').last);
    await tester.pumpAndSettle();
    expect(controller.historyLimit, 5000);
    await openCustom(tester);
    await tester.enterText(input, '12345');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('自定义历史保存数量'), findsNothing);
    expect(controller.historyLimit, 12345);
    expect(repository.settings['history_limit'], '12345');
    expect(repository.appliedLimits, [5000, 12345]);
    expect(find.text('12,345 条（自定义）').hitTestable(), findsOneWidget);
    await openCustom(tester);
    expect(tester.widget<TextFormField>(input).controller!.text, '12345');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.historyLimit, 12345);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空白、零、负数、小数和非数字不会保存，取消保留原值', (tester) async {
    await mount(tester);
    await openCustom(tester);
    for (final value in ['', '0', '-5', '1.5', 'abc']) {
      await tester.enterText(input, value);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请输入大于 0 的整数'), findsOneWidget);
      expect(controller.historyLimit, 10000);
      expect(repository.appliedLimits, isEmpty);
    }
    await tester.enterText(input, '2500');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.historyLimit, 10000);
    expect(repository.settings.containsKey('history_limit'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败保留输入和原设置，恢复后可以重试', (tester) async {
    await mount(tester);
    await openCustom(tester);
    await tester.enterText(input, '7500');
    repository.failSettingWrite = true;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(controller.historyLimit, 10000);
    expect(tester.widget<TextFormField>(input).controller!.text, '7500');
    repository.failSettingWrite = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.historyLimit, 7500);
    expect(repository.settings['history_limit'], '7500');
    expect(tester.takeException(), isNull);
  });
}
