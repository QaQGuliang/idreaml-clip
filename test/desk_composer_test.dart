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
      Size(410, kind == DeskKind.note ? 496 : 470),
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

  Future<void> openSchedule(WidgetTester tester) async {
    await tester.tap(keyed('desk-composer-schedule'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Future<void> pickDateTime(
    WidgetTester tester,
    String fieldKey,
    String date,
    String hour,
    String minute,
  ) async {
    await tester.tap(keyed(fieldKey));
    await tester.pumpAndSettle();
    await tester.enterText(keyed('desk-time-date'), date);
    await tester.enterText(keyed('desk-time-hour'), hour);
    await tester.enterText(keyed('desk-time-minute'), minute);
    await tester.tap(keyed('desk-time-confirm'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseReminder(WidgetTester tester, String label) async {
    await tester.tap(keyed('desk-schedule-remind'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('待办设置开始时间与提前提醒，保存时携带四个字段', (tester) async {
    final start = DateTime(2099, 12, 31, 8);
    await pumpComposer(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-composer-body'), '带提醒的待办');
    await openSchedule(tester);
    await pickDateTime(tester, 'desk-schedule-start', '2099-12-31', '08', '00');
    await chooseReminder(tester, '开始前 15 分钟');
    expect(find.text('将在 2099-12-31 07:45 提醒'), findsOneWidget);
    await tester.tap(keyed('desk-composer-schedule-save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('开始 2099-12-31 08:00'), findsOneWidget);

    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    final saved = notes.items(DeskKind.todo).single;
    expect(saved.startAt, start.millisecondsSinceEpoch);
    expect(saved.remindBeforeMinutes, 15);
    expect(saved.endAt, isNull);
    expect(saved.remindAt, isNull);
    final cleared = await tester.runAsync(() => notes.draft(DeskKind.todo));
    for (final key in ['startAt', 'endAt', 'remindAt', 'remindBeforeMinutes']) {
      expect(cleared!.containsKey(key), isFalse, reason: key);
    }
  });

  testWidgets('关闭窗口保留的草稿携带时间与提醒，重新打开可恢复', (tester) async {
    final start = DateTime(2099, 12, 31, 8);
    await pumpComposer(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-composer-body'), '带时间的草稿');
    await openSchedule(tester);
    await pickDateTime(tester, 'desk-schedule-start', '2099-12-31', '08', '00');
    await chooseReminder(tester, '开始前 15 分钟');
    await tester.tap(keyed('desk-composer-schedule-save'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(tester, () => finished.isNotEmpty);
    expect(finished.single, DeskComposerResult.dismissed);
    final draft = await tester.runAsync(() => notes.draft(DeskKind.todo));
    expect(draft!['body'], '带时间的草稿');
    expect(draft['startAt'], start.millisecondsSinceEpoch);
    expect(draft['remindBeforeMinutes'], 15);

    finished.clear();
    await pumpComposer(tester, DeskKind.todo, draft: draft);
    expect(find.textContaining('开始 2099-12-31 08:00'), findsOneWidget);
    expect(find.textContaining('提前 15 分钟提醒'), findsOneWidget);

    // 清除入口同时清理草稿字段。
    await tester.tap(keyed('desk-composer-schedule-clear'));
    await tester.pumpAndSettle();
    expect(find.text('时间与提醒：未设置'), findsOneWidget);
    await tester.tap(keyed('desk-composer-cancel'));
    await waitFor(tester, () => finished.isNotEmpty);
    final cleared = await tester.runAsync(() => notes.draft(DeskKind.todo));
    for (final key in ['startAt', 'endAt', 'remindAt', 'remindBeforeMinutes']) {
      expect(cleared!.containsKey(key), isFalse, reason: key);
    }
  });

  testWidgets('结束早于开始在对话框内报错，修正后可完成，入口可清除', (tester) async {
    await pumpComposer(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-composer-body'), '结束早于开始');
    await openSchedule(tester);
    await pickDateTime(tester, 'desk-schedule-start', '2099-12-31', '10', '00');
    await pickDateTime(tester, 'desk-schedule-end', '2099-12-31', '09', '00');
    await tester.tap(keyed('desk-composer-schedule-save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<Text>(keyed('desk-schedule-end-error')).data,
      '结束时间不能早于开始时间',
    );

    await pickDateTime(tester, 'desk-schedule-end', '2099-12-31', '11', '00');
    await tester.tap(keyed('desk-composer-schedule-save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('结束 2099-12-31 11:00'), findsOneWidget);

    await tester.tap(keyed('desk-composer-schedule-clear'));
    await tester.pumpAndSettle();
    expect(find.text('时间与提醒：未设置'), findsOneWidget);

    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    final saved = notes.items(DeskKind.todo).single;
    expect(saved.startAt, isNull);
    expect(saved.endAt, isNull);
    expect(saved.remindAt, isNull);
    expect(saved.remindBeforeMinutes, isNull);
  });

  testWidgets('草稿恢复时间与提醒，直接保存时写回原值', (tester) async {
    final start = DateTime(2099, 5, 1, 9, 30);
    final remind = DateTime(2099, 5, 1, 9, 0);
    await pumpComposer(
      tester,
      DeskKind.todo,
      draft: {
        'body': '草稿里的提醒',
        'startAt': start.millisecondsSinceEpoch,
        'endAt': start.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        'remindAt': remind.millisecondsSinceEpoch,
      },
    );
    expect(find.textContaining('开始 2099-05-01 09:30'), findsOneWidget);
    expect(find.textContaining('2099-05-01 09:00 提醒'), findsOneWidget);

    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    final saved = notes.items(DeskKind.todo).single;
    expect(saved.startAt, start.millisecondsSinceEpoch);
    expect(
      saved.endAt,
      start.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    );
    expect(saved.remindAt, remind.millisecondsSinceEpoch);
    expect(saved.remindBeforeMinutes, isNull);
  });

  testWidgets('草稿里的提前提醒缺少开始时间时字段级报错并聚焦入口', (tester) async {
    await pumpComposer(
      tester,
      DeskKind.todo,
      draft: {'body': '缺少开始时间', 'remindBeforeMinutes': 30},
    );
    expect(
      tester.widget<Text>(keyed('desk-composer-schedule-error')).data,
      '提前提醒需要先设置开始时间',
    );
    await tester.tap(keyed('desk-composer-save'));
    await tester.pumpAndSettle();
    expect(finished, isEmpty);
    expect(
      tester
          .widget<OutlinedButton>(keyed('desk-composer-schedule'))
          .focusNode!
          .hasFocus,
      isTrue,
    );

    // 补上开始时间后错误即时清除，并可保存。
    await openSchedule(tester);
    await pickDateTime(tester, 'desk-schedule-start', '2099-12-31', '08', '00');
    await tester.tap(keyed('desk-composer-schedule-save'));
    await tester.pumpAndSettle();
    expect(keyed('desk-composer-schedule-error'), findsNothing);
    await tester.tap(keyed('desk-composer-save'));
    await waitFor(tester, () => finished.isNotEmpty);
    final saved = notes.items(DeskKind.todo).single;
    expect(saved.startAt, DateTime(2099, 12, 31, 8).millisecondsSinceEpoch);
    expect(saved.remindBeforeMinutes, 30);
  });

  testWidgets('内联色板与整体色板一致，18 色均可选择', (tester) async {
    await pumpComposer(tester, DeskKind.note);
    await tester.enterText(keyed('desk-composer-body'), '统一色板');
    await tester.tap(keyed('desk-composer-color'));
    await tester.pumpAndSettle();

    expect(keyed('desk-composer-palette'), findsOneWidget);
    expect(deskPaletteSwatches, hasLength(18));
    for (final color in deskPaletteSwatches) {
      expect(
        keyed('desk-composer-color-${deskColorHex(color)}'),
        findsOneWidget,
        reason: deskColorHex(color),
      );
    }
    // 与旧版 7 色不同的浅色块也能直接选择。
    final custom = deskPaletteSwatches[5];
    await tester.tap(keyed('desk-composer-color-${deskColorHex(custom)}'));
    await tester.pumpAndSettle();
    expect(find.text('文字颜色：${deskColorHex(custom)}'), findsOneWidget);
  });
}
