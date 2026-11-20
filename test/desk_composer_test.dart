import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desk_typography.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';
import 'package:idreaml_clip/src/ui/desk_composer.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DesktopNotes notes;
  late List<DeskComposerResult> finished;
  DeskComposerDismiss? dismiss;
  var session = 0;
  const channel = MethodChannel('idreaml_clip/desk_composer_test');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-desk-composer-');
    notes = DesktopNotes(
      DeskRepository(
        deviceId: 'composer-test',
        testPath: p.join(root.path, 'desktop.db'),
        factory: databaseFactoryFfiNoIsolate,
      ),
      channel: channel,
    );
    await notes.initialize();
    for (final kind in DeskKind.values) {
      await notes.updateSettings(kind, {'enabled': true});
    }
    finished = [];
    dismiss = null;
  });
  tearDown(() async {
    notes.dispose();
    await root.delete(recursive: true);
  });

  Finder keyed(String value) => find.byKey(ValueKey(value));

  /// 让排队的草稿写入在真实事件循环里完成，避免残留数据库锁阻塞后续用例。
  Future<void> flush(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }

  Future<void> pumpComposer(
    WidgetTester tester,
    DeskKind kind, {
    Map<String, dynamic> draft = const {},
  }) async {
    // 上一个用例可能留有排队中的草稿写入，先让它完成再开启新窗口。
    await flush(tester);
    // 与桌面服务的快速新增窗口尺寸保持一致。
    await tester.binding.setSurfaceSize(
      Size(410, kind == DeskKind.note ? 496 : 414),
    );
    addTearDown(() async {
      await flush(tester);
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: DeskComposer(
          // 每次打开都是新的会话状态（与桌面服务的 composerSession 一致）。
          key: ValueKey('desk-composer-${session++}'),
          notes: notes,
          kind: kind,
          draft: draft,
          onFinish: (result) async => finished.add(result),
          onDismissReady: (value) => dismiss = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 100 && !done(); attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  TextField bodyField(WidgetTester tester) =>
      tester.widget<TextField>(keyed('desk-composer-body'));

  TextField titleField(WidgetTester tester) =>
      tester.widget<TextField>(keyed('desk-composer-title'));

  Color borderColor(TextField field) =>
      (field.decoration!.enabledBorder! as OutlineInputBorder).borderSide.color;

  testWidgets('便签快速新增恢复草稿，标题与内容继承文字样式', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {
        'enabled': true,
        'fontFamily': 'Arial',
        'fontSize': 20.0,
        'textColor': 0xFF526887,
      }),
    );
    await pumpComposer(
      tester,
      DeskKind.note,
      draft: const {
        'title': '草稿标题',
        'body': '草稿内容',
        'fontFamily': 'KaiTi',
        'fontSize': 18.0,
        'textColor': 0xFFE35A6B,
      },
    );

    expect(find.text('快速记录'), findsOneWidget);
    expect(keyed('desk-composer-heading'), findsOneWidget);
    expect(find.text('新建便签'), findsOneWidget);
    expect(titleField(tester).controller!.text, '草稿标题');
    expect(bodyField(tester).controller!.text, '草稿内容');
    expect(find.text('文字颜色：#E35A6B'), findsOneWidget);
    final style = bodyField(tester).style!;
    expect(style.fontFamily, 'KaiTi');
    expect(style.fontSize, 18);
    expect(style.color, const Color(0xFFE35A6B));
    // 草稿没有覆盖项时继承模块默认样式。
    expect(titleField(tester).maxLength, deskTitleMaxLength);
    expect(tester.takeException(), isNull);
  });

  testWidgets('待办快速新增只有内容字段，默认样式跟随列表', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.todo, {
        'enabled': true,
        'fontFamily': 'Consolas',
        'fontSize': 14.0,
      }),
    );
    await pumpComposer(tester, DeskKind.todo);
    expect(find.text('新建待办'), findsOneWidget);
    expect(keyed('desk-composer-title'), findsNothing);
    expect(find.text('事项内容'), findsOneWidget);
    expect(find.text('文字颜色：跟随列表'), findsOneWidget);
    final style = bodyField(tester).style!;
    expect(style.fontFamily, 'Consolas');
    expect(style.fontSize, 14);
    expect(style.color, AppColors.text);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内容为空时按字段提示并聚焦，重新输入后清除', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '   \n ');
    await tester.tap(keyed('desk-composer-save'));
    await tester.pumpAndSettle();

    expect(finished, isEmpty);
    expect(
      tester.widget<Text>(keyed('desk-composer-body-error')).data,
      '请先填写内容',
    );
    expect(borderColor(bodyField(tester)), AppColors.danger);
    expect(bodyField(tester).focusNode!.hasFocus, isTrue);

    await tester.enterText(keyed('desk-composer-body'), '补上内容');
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-body-error'), findsNothing);
    expect(borderColor(bodyField(tester)), AppColors.line);
  });

  testWidgets('历史草稿标题超长给出字段提示，修正后可保存', (tester) async {
    final legacy = '标' * (deskTitleMaxLength + 30);
    await pumpComposer(
      tester,
      DeskKind.note,
      draft: {'title': legacy, 'body': '超长标题草稿'},
    );
    expect(
      tester.widget<Text>(keyed('desk-composer-title-error')).data,
      '标题最多 120 字，请精简后保存',
    );
    expect(borderColor(titleField(tester)), AppColors.danger);
    expect(titleField(tester).maxLength, deskTitleMaxLength);

    // 输入框本身限制 120 字，重新输入即清除提示。
    await tester.enterText(keyed('desk-composer-title'), '修正后的标题');
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-title-error'), findsNothing);
    await tester.enterText(keyed('desk-composer-body'), '正文');
    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.saved);
    expect(notes.items(DeskKind.note).single.title, '修正后的标题');
  });

  testWidgets('预设色块、跟随列表与自定义选色都可写回条目', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '换一个颜色');

    await tester.tap(keyed('desk-composer-color'));
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-palette'), findsOneWidget);
    // 预设色块带色值示例。
    expect(find.byTooltip('紫色 ${deskColorHex(0xFF6C57E5)}'), findsOneWidget);
    await tester.tap(keyed('desk-composer-color-#6C57E5'));
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-palette'), findsNothing);
    expect(find.text('文字颜色：#6C57E5'), findsOneWidget);

    await tester.tap(keyed('desk-composer-color'));
    await tester.pumpAndSettle();
    await tester.tap(keyed('desk-composer-color-follow'));
    await tester.pumpAndSettle();
    expect(find.text('文字颜色：跟随列表'), findsOneWidget);

    // 自定义颜色复用管理页的 18 色 + HEX 选色对话框。
    await tester.tap(keyed('desk-composer-color'));
    await tester.pumpAndSettle();
    await tester.tap(keyed('desk-composer-color-custom'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.text('选择文字颜色'), findsOneWidget);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      '#8E24AA',
    );
    await tester.tap(find.text('使用此颜色'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('文字颜色：#8E24AA'), findsOneWidget);

    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.saved);
    final saved = notes.items(DeskKind.note).single;
    expect(saved.body, '换一个颜色');
    expect(saved.textColor, 0xFF8E24AA);
  });

  testWidgets('保存成功后写入条目、清理草稿并结束会话', (tester) async {
    await pumpComposer(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-composer-body'), '完成的待办');
    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.saved);
    expect(notes.items(DeskKind.todo).single.body, '完成的待办');
    final draft = await tester.runAsync(() => notes.draft(DeskKind.todo));
    expect(draft!['body'], '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存失败保留窗口并显示原因', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '保存会失败');
    // 模块在会话中途被关闭，仓库拒绝写入。
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {'enabled': false}),
    );
    await tester.tap(keyed('desk-composer-save'));
    await tester.pumpAndSettle();

    expect(finished, isEmpty);
    expect(keyed('desk-composer-body'), findsOneWidget);
    expect(
      tester.widget<Text>(keyed('desk-composer-save-error')).data,
      contains('保存失败，请重试'),
    );
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('取消清空草稿，Esc 与关闭按钮保留草稿', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '取消的内容');
    await tester.tap(keyed('desk-composer-cancel'));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.cancelled);
    expect(
      (await tester.runAsync(() => notes.draft(DeskKind.note)))!['body'],
      '',
    );

    finished.clear();
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), 'Esc 保留的内容');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.dismissed);
    expect(
      (await tester.runAsync(() => notes.draft(DeskKind.note)))!['body'],
      'Esc 保留的内容',
    );

    finished.clear();
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '关闭保留的内容');
    await tester.tap(keyed('desk-composer-close'));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.dismissed);
    expect(
      (await tester.runAsync(() => notes.draft(DeskKind.note)))!['body'],
      '关闭保留的内容',
    );
  });

  testWidgets('调色板打开时 Esc 只收起调色板，不关闭窗口', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.tap(keyed('desk-composer-color'));
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-palette'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-palette'), findsNothing);
    expect(finished, isEmpty);
    expect(keyed('desk-composer-body'), findsOneWidget);
  });

  testWidgets('Ctrl+Enter 直接保存', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '快捷键保存');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.saved);
    expect(notes.items(DeskKind.note).single.body, '快捷键保存');
  });

  testWidgets('失焦退出入口保存草稿并结束会话', (tester) async {
    await pumpComposer(tester, DeskKind.todo);
    expect(dismiss, isNotNull);
    await tester.enterText(keyed('desk-composer-body'), '离开窗口的草稿');
    await tester.runAsync(() => dismiss!(clearDraft: false));
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.dismissed);
    expect(
      (await tester.runAsync(() => notes.draft(DeskKind.todo)))!['body'],
      '离开窗口的草稿',
    );
  });
}
