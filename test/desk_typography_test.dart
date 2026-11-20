import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_pages.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desk_typography.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DesktopNotes notes;
  const channel = MethodChannel('idreaml_clip/desk_typography_test');

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    // The editor dialog now includes schedule fields; a taller test surface
    // keeps the full form on screen so taps are not clipped by the dialog.
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1280, 960);
    view.devicePixelRatio = 1.0;
    root = await Directory.systemTemp.createTemp('idreaml-desk-typography-');
    notes = DesktopNotes(
      DeskRepository(
        deviceId: 'typography-test',
        testPath: p.join(root.path, 'desktop.db'),
        factory: databaseFactoryFfiNoIsolate,
      ),
      channel: channel,
    );
    await notes.initialize();
  });
  tearDown(() async {
    notes.dispose();
    await root.delete(recursive: true);
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Widget page(DeskKind kind) => MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: ListenableBuilder(
        listenable: notes,
        builder: (_, _) => DeskPage(notes: notes, kind: kind),
      ),
    ),
  );

  Finder keyed(String value) => find.byKey(ValueKey(value));

  Future<void> waitForChange(
    WidgetTester tester,
    bool Function() changed,
  ) async {
    for (var attempt = 0; attempt < 100 && !changed(); attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(changed(), isTrue);
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    // The editor dialog scrolls; center the target so newly added schedule
    // fields cannot leave typography controls clipped under the edge.
    final elements = target.evaluate();
    if (elements.isNotEmpty) {
      await Scrollable.ensureVisible(
        elements.first,
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> chooseFamily(WidgetTester tester, String label) async {
    await tapVisible(tester, keyed('desk-entry-font-family'));
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> chooseColor(WidgetTester tester, String hex) async {
    await tapVisible(tester, keyed('desk-entry-text-color'));
    final input = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextField),
    );
    await tester.enterText(input, hex);
    await tester.tap(find.text('使用此颜色'));
    await tester.pumpAndSettle();
  }

  Future<void> saveEditor(WidgetTester tester, DeskKind kind) async {
    await tapVisible(tester, keyed('desk-editor-save'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    // New entries also clear their draft after the dialog closes. Finish that
    // database work before advancing the controller-disposal timer.
    await tester.runAsync(() => notes.draft(kind));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  for (final kind in DeskKind.values) {
    testWidgets('${kind.label}新增文字样式可保存，编辑恢复跟随列表后随设置更新', (tester) async {
      await tester.runAsync(
        () => notes.updateSettings(kind, {
          'enabled': true,
          'fontFamily': 'Arial',
          'fontSize': 16.0,
          'textColor': 0xFF374151,
        }),
      );
      await tester.pumpWidget(page(kind));
      await tester.tap(find.text('新建${kind.label}'));
      await waitForChange(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      if (kind == DeskKind.note) {
        await tester.enterText(keyed('desk-editor-title'), '单条文字样式');
      }
      await tester.enterText(keyed('desk-editor-body'), '保存后仍使用我选择的样式');
      await chooseFamily(tester, '宋体');
      await tapVisible(tester, keyed('desk-entry-font-size-enabled'));
      final slider = keyed('desk-entry-font-size');
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      // Exercise the actual slider boundary and editor callbacks.
      await tester.drag(slider, const Offset(1000, 0));
      await tester.pumpAndSettle();
      await chooseColor(tester, '#8E24AA');

      final preview = find.descendant(
        of: keyed('desk-editor-typography-preview'),
        matching: find.text('保存后仍使用我选择的样式'),
      );
      final previewStyle = tester.widget<Text>(preview).style!;
      expect(previewStyle.fontFamily, 'SimSun');
      expect(previewStyle.fontSize, kind == DeskKind.todo ? 33 : 32);
      expect(previewStyle.color, const Color(0xFF8E24AA));
      await saveEditor(tester, kind);

      final created = notes.items(kind).single;
      final persisted = await tester.runAsync(
        () async => (await notes.repository.load()).single,
      );
      expect(persisted!.id, created.id);
      expect(persisted.fontFamily, 'SimSun');
      expect(persisted.fontSize, 32);
      expect(persisted.textColor, 0xFF8E24AA);
      final content = keyed('desk-entry-content-${created.id}');
      expect(tester.widget<Text>(content).style!.fontFamily, 'SimSun');
      expect(
        tester.widget<Text>(content).style!.color,
        const Color(0xFF8E24AA),
      );

      await tapVisible(tester, find.text('编辑'));
      await waitForChange(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      await chooseFamily(tester, '跟随列表');
      await tapVisible(tester, keyed('desk-entry-font-size-enabled'));
      await tapVisible(tester, keyed('desk-entry-text-color-reset'));
      await saveEditor(tester, kind);

      final inherited = notes.items(kind).single;
      expect(inherited.id, created.id);
      expect(inherited.body, created.body);
      expect(inherited.fontFamily, isNull);
      expect(inherited.fontSize, isNull);
      expect(inherited.textColor, isNull);
      expect(tester.widget<Text>(content).style!.fontFamily, 'Arial');
      expect(
        tester.widget<Text>(content).style!.fontSize,
        kind == DeskKind.todo ? 17 : 18,
      );

      await tester.runAsync(
        () => notes.updateSettings(kind, {
          'fontFamily': 'Consolas',
          'fontSize': 20.0,
          'textColor': 0xFF00695C,
        }),
      );
      await tester.pumpAndSettle();
      final inheritedStyle = tester.widget<Text>(content).style!;
      expect(inheritedStyle.fontFamily, 'Consolas');
      expect(inheritedStyle.fontSize, kind == DeskKind.todo ? 21 : 22);
      expect(inheritedStyle.color, const Color(0xFF00695C));
      // Changing module defaults must not rewrite the entry's revision.
      expect(notes.items(kind).single.revision, inherited.revision);
      final restored = await tester.runAsync(
        () async => (await notes.repository.load()).single,
      );
      expect(restored!.fontFamily, isNull);
      expect(restored.fontSize, isNull);
      expect(restored.textColor, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新建便签非取消关闭保留草稿，取消才清空', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {'enabled': true}),
    );
    await tester.pumpWidget(page(DeskKind.note));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建便签'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    await tester.enterText(keyed('desk-editor-body'), '关闭后仍保留的草稿');
    await tester.pump(const Duration(milliseconds: 500));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    final kept = await tester.runAsync(() => notes.draft(DeskKind.note));
    expect(kept!['body'], '关闭后仍保留的草稿');

    await tester.tap(find.text('新建便签'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    expect(
      tester.widget<TextField>(keyed('desk-editor-body')).controller!.text,
      '关闭后仍保留的草稿',
    );
    await tester.tap(find.text('取消'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    final cleared = await tester.runAsync(() => notes.draft(DeskKind.note));
    expect(cleared!['body'], '');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('继承白色文字的列表与全文保留选定字色，并提供可读的局部背景', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {
        'enabled': true,
        'fontFamily': 'Consolas',
        'fontSize': 22.0,
        'textColor': 0xFFFFFFFF,
      });
      await notes.save(DeskKind.note, title: '白色标题', body: '白色正文保持清晰');
    });
    await tester.pumpWidget(page(DeskKind.note));
    final entry = notes.items(DeskKind.note).single;

    void expectReadableWhite(Finder text, double size) {
      final style = tester.widget<Text>(text).style!;
      expect(style.fontFamily, 'Consolas');
      expect(style.fontSize, size);
      expect(style.color, Colors.white);
      final surfaces = tester.widgetList<Container>(
        find.ancestor(of: text, matching: find.byType(Container)),
      );
      // Assert readable contrast without relying on an exact theme swatch or
      // replacing the user's selected white with an automatic text color.
      expect(
        surfaces.any((surface) {
          final decoration = surface.decoration;
          if (decoration is! BoxDecoration || decoration.color == null) {
            return false;
          }
          final background = decoration.color!;
          if (background.a < .95) return false;
          final foregroundLuminance = style.color!.computeLuminance();
          final backgroundLuminance = background.computeLuminance();
          final ratio =
              (math.max(foregroundLuminance, backgroundLuminance) + .05) /
              (math.min(foregroundLuminance, backgroundLuminance) + .05);
          return ratio >= 4.5;
        }),
        isTrue,
      );
    }

    expectReadableWhite(keyed('desk-entry-content-${entry.id}'), 24);
    expectReadableWhite(keyed('desk-entry-body-${entry.id}'), 22);
    expectReadableWhite(keyed('desk-entry-meta-${entry.id}'), 21);
    await tapVisible(tester, find.text('查看全文'));
    expectReadableWhite(keyed('desk-reading-title'), 24);
    expectReadableWhite(keyed('desk-reading-body'), 22);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  Future<void> openEditor(WidgetTester tester, DeskKind kind) async {
    await tester.tap(find.text('新建${kind.label}'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
  }

  Future<void> pickScheduleTime(
    WidgetTester tester,
    String fieldKey,
    String date,
    String hour,
    String minute,
  ) async {
    await tapVisible(tester, keyed(fieldKey));
    await tester.enterText(keyed('desk-time-date'), date);
    await tester.enterText(keyed('desk-time-hour'), hour);
    await tester.enterText(keyed('desk-time-minute'), minute);
    await tester.tap(keyed('desk-time-confirm'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseReminder(WidgetTester tester, String label) async {
    await tapVisible(tester, keyed('desk-schedule-remind'));
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('待办新增可设置时间与提醒，编辑回显，清除后保存为空', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.todo, {'enabled': true}),
    );
    await tester.pumpWidget(page(DeskKind.todo));
    await openEditor(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-editor-body'), '周四前完成方案');
    await pickScheduleTime(
      tester,
      'desk-schedule-start',
      '2099-12-31',
      '08',
      '00',
    );
    await pickScheduleTime(
      tester,
      'desk-schedule-end',
      '2099-12-31',
      '09',
      '30',
    );
    await chooseReminder(tester, '开始前 30 分钟');
    expect(find.text('将在 2099-12-31 07:30 提醒'), findsOneWidget);
    await saveEditor(tester, DeskKind.todo);

    final entry = notes.items(DeskKind.todo).single;
    expect(entry.startAt, DateTime(2099, 12, 31, 8).millisecondsSinceEpoch);
    expect(entry.endAt, DateTime(2099, 12, 31, 9, 30).millisecondsSinceEpoch);
    expect(entry.remindBeforeMinutes, 30);
    expect(entry.remindAt, isNull);

    // 编辑既有条目回显原值，清除开始时间后提前提醒报错，清除全部后保存为空。
    await tapVisible(tester, find.text('编辑'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
    );
    expect(find.text('2099-12-31 08:00'), findsOneWidget);
    expect(find.text('2099-12-31 09:30'), findsOneWidget);
    expect(find.text('将在 2099-12-31 07:30 提醒'), findsOneWidget);
    await tapVisible(tester, keyed('desk-schedule-start-clear'));
    await tapVisible(tester, keyed('desk-editor-save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<Text>(keyed('desk-schedule-remind-error')).data,
      '提前提醒需要先设置开始时间',
    );

    await tapVisible(tester, keyed('desk-schedule-clear'));
    await saveEditor(tester, DeskKind.todo);
    final cleared = notes.items(DeskKind.todo).single;
    expect(cleared.id, entry.id);
    expect(cleared.startAt, isNull);
    expect(cleared.endAt, isNull);
    expect(cleared.remindAt, isNull);
    expect(cleared.remindBeforeMinutes, isNull);
    final stored = await tester.runAsync(
      () async => (await notes.repository.load()).single,
    );
    expect(stored!.startAt, isNull);
    expect(stored.remindBeforeMinutes, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('管理页字段级校验：空内容、结束早于开始与标题超长就近提示', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.todo, {'enabled': true});
      await notes.updateSettings(DeskKind.note, {'enabled': true});
    });
    await tester.pumpWidget(page(DeskKind.todo));
    await openEditor(tester, DeskKind.todo);
    await tapVisible(tester, keyed('desk-editor-save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.widget<Text>(keyed('desk-editor-body-error')).data, '请先填写内容');
    final body = tester.widget<TextField>(keyed('desk-editor-body'));
    expect(
      (body.decoration!.enabledBorder! as OutlineInputBorder).borderSide.color,
      AppColors.danger,
    );
    expect(body.focusNode!.hasFocus, isTrue);

    await tester.enterText(keyed('desk-editor-body'), '结束早于开始');
    await tester.pumpAndSettle();
    expect(keyed('desk-editor-body-error'), findsNothing);
    await pickScheduleTime(
      tester,
      'desk-schedule-start',
      '2099-12-31',
      '10',
      '00',
    );
    await pickScheduleTime(
      tester,
      'desk-schedule-end',
      '2099-12-31',
      '09',
      '00',
    );
    await tapVisible(tester, keyed('desk-editor-save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<Text>(keyed('desk-schedule-end-error')).data,
      '结束时间不能早于开始时间',
    );
    await pickScheduleTime(
      tester,
      'desk-schedule-end',
      '2099-12-31',
      '11',
      '00',
    );
    await saveEditor(tester, DeskKind.todo);
    final todo = notes.items(DeskKind.todo).single;
    expect(todo.startAt, DateTime(2099, 12, 31, 10).millisecondsSinceEpoch);
    expect(todo.endAt, DateTime(2099, 12, 31, 11).millisecondsSinceEpoch);

    // 便签标题超长（旧草稿）时字段级提示并聚焦标题。
    await tester.runAsync(
      () => notes.storeDraft(DeskKind.note, '标' * 130, '超长标题草稿'),
    );
    await tester.pumpWidget(page(DeskKind.note));
    await openEditor(tester, DeskKind.note);
    await tapVisible(tester, keyed('desk-editor-save'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(keyed('desk-editor-title-error')).data,
      '标题最多 120 字，请精简后保存',
    );
    expect(
      tester.widget<TextField>(keyed('desk-editor-title')).focusNode!.hasFocus,
      isTrue,
    );
    await tester.enterText(keyed('desk-editor-title'), '修正后的标题');
    await tester.pumpAndSettle();
    expect(keyed('desk-editor-title-error'), findsNothing);
    await saveEditor(tester, DeskKind.note);
    expect(notes.items(DeskKind.note).single.title, '修正后的标题');
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建待办非取消关闭保留时间与提醒草稿', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.todo, {'enabled': true}),
    );
    await tester.pumpWidget(page(DeskKind.todo));
    await openEditor(tester, DeskKind.todo);
    await tester.enterText(keyed('desk-editor-body'), '保留草稿的待办');
    await pickScheduleTime(
      tester,
      'desk-schedule-start',
      '2099-12-31',
      '08',
      '00',
    );
    await chooseReminder(tester, '开始前 5 分钟');
    await tester.pump(const Duration(milliseconds: 500));
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    final draft = await tester.runAsync(() => notes.draft(DeskKind.todo));
    expect(draft!['startAt'], DateTime(2099, 12, 31, 8).millisecondsSinceEpoch);
    expect(draft['remindBeforeMinutes'], 5);

    await openEditor(tester, DeskKind.todo);
    expect(find.text('2099-12-31 08:00'), findsOneWidget);
    expect(find.text('将在 2099-12-31 07:55 提醒'), findsOneWidget);
    await tapVisible(tester, find.text('取消'));
    await waitForChange(
      tester,
      () => find.byType(AlertDialog).evaluate().isEmpty,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    final cleared = await tester.runAsync(() => notes.draft(DeskKind.todo));
    expect(cleared!.containsKey('startAt'), isFalse);
    expect(cleared.containsKey('remindBeforeMinutes'), isFalse);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('管理页选色器提供统一的 18 色与 HEX 输入', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {'enabled': true}),
    );
    await tester.pumpWidget(page(DeskKind.note));
    await openEditor(tester, DeskKind.note);
    await tester.enterText(keyed('desk-editor-body'), '统一色板');
    await tapVisible(tester, keyed('desk-entry-text-color'));

    expect(deskPaletteSwatches, hasLength(18));
    for (final color in deskPaletteSwatches) {
      expect(
        keyed('desk-color-picker-${deskColorHex(color)}'),
        findsOneWidget,
        reason: deskColorHex(color),
      );
    }
    final swatch = deskPaletteSwatches[8];
    await tester.tap(keyed('desk-color-picker-${deskColorHex(swatch)}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用此颜色'));
    await tester.pumpAndSettle();
    expect(find.text(deskColorHex(swatch)), findsOneWidget);
    await saveEditor(tester, DeskKind.note);
    expect(notes.items(DeskKind.note).single.textColor, swatch);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同步冲突采用版本时回传时间与提醒', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.todo, {'enabled': true}),
    );
    final start = DateTime(2099, 6, 1, 10).millisecondsSinceEpoch;
    final remoteStart = DateTime(2099, 6, 2, 10).millisecondsSinceEpoch;
    final remoteRemind = DateTime(2099, 6, 2, 9, 30).millisecondsSinceEpoch;
    late DeskEntry local;
    await tester.runAsync(() async {
      local = await notes.repository.save(
        DeskKind.todo,
        body: '本地版本',
        startAt: start,
        remindBeforeMinutes: 15,
      );
      final other = DeskRepository(
        deviceId: 'device-b',
        testPath: p.join(root.path, 'device-b.db'),
        factory: databaseFactoryFfiNoIsolate,
      );
      final remote = await other.save(
        DeskKind.todo,
        id: local.id,
        body: '远端版本',
        startAt: remoteStart,
        remindAt: remoteRemind,
      );
      await notes.repository.merge([remote]);
      await notes.reload();
    });
    expect(notes.conflicts(DeskKind.todo), contains(local.id));
    await tester.pumpWidget(page(DeskKind.todo));
    await tapVisible(tester, find.text('处理冲突'));
    expect(find.text('选择要保留的版本'), findsOneWidget);
    final card = find.ancestor(
      of: find.text('远端版本'),
      matching: find.byType(Card),
    );
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('2099-06-02')),
      findsWidgets,
    );
    await tester.tap(find.descendant(of: card, matching: find.text('保留此版本')));
    await waitForChange(tester, () => notes.conflicts(DeskKind.todo).isEmpty);
    final merged = notes.items(DeskKind.todo).single;
    expect(merged.body, '远端版本');
    expect(merged.startAt, remoteStart);
    expect(merged.remindAt, remoteRemind);
    expect(merged.remindBeforeMinutes, isNull);
    expect(tester.takeException(), isNull);
  });
}
