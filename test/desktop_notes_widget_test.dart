import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_pages.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DesktopNotes notes;
  const channel = MethodChannel('idreaml_clip/desktop_notes_widget_test');
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'monitors') {
            return [
              {
                'id': 'display-main',
                'label': '测试主显示器',
                'primary': true,
                'left': 0,
                'top': 0,
                'width': 1920,
                'height': 1080,
              },
            ];
          }
          return null;
        });
    root = await Directory.systemTemp.createTemp('idreaml-desk-widget-');
    notes = DesktopNotes(
      DeskRepository(
        deviceId: 'widget-test',
        testPath: p.join(root.path, 'desktop.db'),
        factory: databaseFactoryFfiNoIsolate,
      ),
      channel: channel,
    );
    await notes.initialize();
  });
  tearDown(() async {
    notes.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  Widget page(DeskKind kind, {String? selectedId, int request = 0}) =>
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: notes,
            builder: (_, _) => DeskPage(
              notes: notes,
              kind: kind,
              selectedId: selectedId,
              viewRequest: request,
            ),
          ),
        ),
      );

  Widget settingsPage() => MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: DeskSettingsPage(notes: notes)),
  );

  Finder settingSwitch(String label) => find.descendant(
    of: find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    ),
    matching: find.byType(Switch),
  );

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> waitForChange(
    WidgetTester tester,
    bool Function() changed,
  ) async {
    for (var attempt = 0; attempt < 100 && !changed(); attempt++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(changed(), isTrue);
    await tester.pumpAndSettle();
  }

  testWidgets('功能关闭时不能在管理页新增，重新开启后保留内容', (tester) async {
    await tester.pumpWidget(page(DeskKind.note));
    expect(find.text('便签尚未开启，请到设置中开启'), findsOneWidget);
    expect(find.text('新建便签'), findsNothing);
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {'enabled': true});
      await notes.save(DeskKind.note, body: '原有内容');
    });
    await tester.pumpAndSettle();
    expect(find.text('新建便签'), findsOneWidget);
    expect(find.text('原有内容'), findsOneWidget);
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {'enabled': false}),
    );
    await tester.pumpAndSettle();
    expect(find.text('原有内容'), findsNothing);
    expect(notes.items(DeskKind.note).single.body, '原有内容');
  });

  testWidgets('勾选待办后从待完成移出，在已完成页面可以恢复', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.todo, {'enabled': true});
      await notes.save(DeskKind.todo, body: '完成并恢复此事项');
    });
    await tester.pumpWidget(page(DeskKind.todo));
    Future<void> toggleAndWait(bool done) async {
      await tester.tap(find.byType(Checkbox));
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump();
        if (notes.items(DeskKind.todo).single.done == done) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(notes.items(DeskKind.todo).single.done, done);
      await tester.pumpAndSettle();
    }

    await toggleAndWait(true);
    expect(find.text('完成并恢复此事项'), findsNothing);
    await tester.tap(find.text('已完成'));
    await tester.pumpAndSettle();
    expect(find.text('完成并恢复此事项'), findsOneWidget);
    await toggleAndWait(false);
    expect(find.text('完成并恢复此事项'), findsNothing);
    await tester.tap(find.text('待完成'));
    await tester.pumpAndSettle();
    expect(find.text('完成并恢复此事项'), findsOneWidget);
  });

  testWidgets('桌面同一卡片可重复打开全文，关闭阅读不会编辑内容', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {'enabled': true});
      await notes.save(DeskKind.note, title: '阅读全文', body: '完整内容');
    });
    final id = notes.items(DeskKind.note).single.id;
    await tester.pumpWidget(page(DeskKind.note, selectedId: id, request: 1));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(page(DeskKind.note, selectedId: id, request: 2));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(notes.items(DeskKind.note).single.body, '完整内容');
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('管理列表可搜索标题与正文，清空后查看完整内容', (tester) async {
    final longBody = List.generate(
      12,
      (index) => '第 ${index + 1} 行：需要完整保留的正文。',
    ).join('\n');
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {'enabled': true});
      await notes.save(DeskKind.note, title: '设计方案', body: longBody);
      await notes.save(DeskKind.note, title: '下周计划', body: '整理桌面主题的参考资料');
    });
    await tester.pumpWidget(page(DeskKind.note));
    final search = find.byType(TextField);
    await tester.enterText(search, '设计');
    await tester.pumpAndSettle();
    expect(find.text('设计方案'), findsOneWidget);
    expect(find.text('下周计划'), findsNothing);
    expect(find.text('找到 1 项'), findsOneWidget);

    await tester.enterText(search, '参考资料');
    await tester.pumpAndSettle();
    expect(find.text('设计方案'), findsNothing);
    expect(find.text('下周计划'), findsOneWidget);

    await tester.enterText(search, '没有任何条目包含此关键词');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的内容'), findsOneWidget);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.text('2 条便签'), findsOneWidget);
    expect(find.text('设计方案'), findsOneWidget);
    expect(find.text('下周计划'), findsOneWidget);

    final targetIndex = notes
        .items(DeskKind.note)
        .indexWhere((entry) => entry.title == '设计方案');
    await tester.tap(find.text('查看全文').at(targetIndex));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(longBody),
      ),
      findsOneWidget,
    );
    expect(notes.items(DeskKind.note), hasLength(2));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  for (final kind in DeskKind.values) {
    testWidgets('${kind.label}管理页在 360×700 下可搜索和阅读且无溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final body = List.filled(15, '一段较长的内容，用来检查窄窗口中的自动换行与完整阅读。').join('\n');
      await tester.runAsync(() async {
        await notes.updateSettings(kind, {'enabled': true});
        await notes.save(
          kind,
          title: kind == DeskKind.note ? '较长的便签标题需要在窄窗口中正确换行' : '',
          body: body,
        );
      });
      await tester.pumpWidget(page(kind));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('新建${kind.label}'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '自动换行');
      await tester.pumpAndSettle();
      expect(find.text('找到 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看全文'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置页签分别显示便签和待办的启用状态与展示位置', (tester) async {
    await tester.runAsync(() async {
      await notes.updateSettings(DeskKind.note, {'enabled': true});
      await notes.updateSettings(DeskKind.todo, {'enabled': false});
    });
    await tester.pumpWidget(settingsPage());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(settingSwitch('启用便签')).value, isTrue);
    expect(find.text('默认位于桌面左侧，避开任务栏'), findsOneWidget);
    expect(settingSwitch('启用待办'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('desk-settings-tab-todo')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(settingSwitch('启用待办')).value, isFalse);
    expect(find.text('默认位于桌面右上角，使用任务栏之外的可用高度'), findsOneWidget);
    expect(settingSwitch('启用便签'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('desk-settings-tab-note')));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(settingSwitch('启用便签')).value, isTrue);
    expect(notes.enabled(DeskKind.todo), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭模块后设置控件不可用，重新启用保留已持久化的外观和区域', (tester) async {
    await tester.runAsync(
      () => notes.updateSettings(DeskKind.note, {
        'enabled': true,
        'sync': true,
        'monitor': 'display-main',
        'x': 12.0,
        'y': 34.0,
        'width': 300.0,
        'height': 600.0,
        'color': 0xFF526887,
        'color2': 0xFFD8D0F8,
        'gradient': 'radial',
        'transparent': true,
        'opacity': .42,
      }),
    );
    final saved = notes.config(DeskKind.note).toJson();
    await tester.pumpWidget(settingsPage());
    await tester.pumpAndSettle();
    await tester.tap(settingSwitch('启用便签'));
    await waitForChange(tester, () => !notes.enabled(DeskKind.note));
    expect(notes.config(DeskKind.note).toJson(), {...saved, 'enabled': false});
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('desk-monitor-note-display-main-1')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('desk-select-region-note')),
          )
          .onPressed,
      isNull,
    );

    final colorField = find.byKey(
      const ValueKey('desk-color-note-color-${0xFF526887}'),
    );
    await reveal(tester, colorField);
    expect(tester.widget<TextFormField>(colorField).enabled, isFalse);
    expect(tester.widget<Switch>(settingSwitch('使用渐变')).onChanged, isNull);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('desk-gradient-note-radial')),
          )
          .onChanged,
      isNull,
    );
    await reveal(tester, settingSwitch('透明背景'));
    expect(tester.widget<Switch>(settingSwitch('透明背景')).onChanged, isNull);
    await reveal(tester, find.byKey(const ValueKey('desk-opacity-note')));
    expect(
      tester
          .widget<Slider>(find.byKey(const ValueKey('desk-opacity-note')))
          .onChanged,
      isNull,
    );
    await reveal(tester, settingSwitch('同步便签'));
    expect(tester.widget<Switch>(settingSwitch('同步便签')).onChanged, isNull);
    await tester.runAsync(() async {
      final restored = DesktopNotes(notes.repository, channel: channel);
      await restored.initialize();
      expect(restored.config(DeskKind.note).toJson(), {
        ...saved,
        'enabled': false,
      });
      restored.dispose();
    });

    await tester.scrollUntilVisible(
      settingSwitch('启用便签'),
      -250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(settingSwitch('启用便签'));
    await waitForChange(tester, () => notes.enabled(DeskKind.note));
    expect(notes.config(DeskKind.note).toJson(), saved);
    await reveal(tester, colorField);
    expect(tester.widget<TextFormField>(colorField).enabled, isTrue);
    expect(tester.widget<Switch>(settingSwitch('使用渐变')).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final kind in DeskKind.values) {
    testWidgets('${kind.label}设置在 360×700 下可访问全部分区且无溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => notes.updateSettings(kind, {
          'enabled': true,
          'gradient': 'radial',
          'transparent': true,
          'opacity': .35,
        }),
      );
      await tester.pumpWidget(settingsPage());
      await tester.pumpAndSettle();
      if (kind == DeskKind.todo) {
        await tester.tap(find.byKey(const ValueKey('desk-settings-tab-todo')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Switch>(settingSwitch('启用${kind.label}')).value,
        isTrue,
      );
      await reveal(tester, find.byTooltip('选择背景颜色'));
      await tester.tap(find.byTooltip('选择背景颜色'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      for (final label in [
        '渐变方式',
        '透明度',
        '桌面效果预览',
        kind == DeskKind.note ? '单按 F3 新增便签' : '双按 F3 新增待办',
        '同步${kind.label}',
      ]) {
        await reveal(tester, find.text(label));
        expect(find.text(label), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(
        tester.widget<Switch>(settingSwitch('同步${kind.label}')).onChanged,
        isNotNull,
      );
    });
  }

  for (final kind in DeskKind.values) {
    testWidgets('${kind.label}透明度到 100% 保留无边框毛玻璃和清晰文字，关闭透明可持久化', (
      tester,
    ) async {
      const background = 0xFFD8D0F8;
      await tester.runAsync(
        () => notes.updateSettings(kind, {
          'enabled': true,
          'transparent': true,
          'opacity': .35,
          'color': background,
          'gradient': 'none',
        }),
      );
      await tester.pumpWidget(settingsPage());
      await tester.pumpAndSettle();
      if (kind == DeskKind.todo) {
        await tester.tap(find.byKey(const ValueKey('desk-settings-tab-todo')));
        await tester.pumpAndSettle();
      }

      final slider = find.byKey(ValueKey('desk-opacity-${kind.name}'));
      await reveal(tester, slider);
      // Drag through the end of the track to exercise the actual 100% control
      // boundary and its persistence callback, rather than setting the model.
      await tester.drag(slider, const Offset(1000, 0));
      await waitForChange(tester, () => notes.config(kind).opacity == 0);
      expect(tester.widget<Slider>(slider).value, 1);
      expect(find.text('100%'), findsOneWidget);

      final card = find.byKey(ValueKey('desk-preview-card-${kind.name}'));
      final backdrop = find.byKey(ValueKey('desk-glass-backdrop-${kind.name}'));
      await reveal(tester, card);
      expect(find.descendant(of: backdrop, matching: card), findsOneWidget);
      expect(tester.widget<BackdropFilter>(backdrop).enabled, isTrue);
      final glassDecoration =
          tester.widget<Container>(card).decoration! as BoxDecoration;
      expect(glassDecoration.border, isNull);
      expect(glassDecoration.color!.a, greaterThan(0));
      expect(glassDecoration.color!.a, lessThan(1));
      final copy = tester
          .widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          )
          .toList();
      expect(copy.length, kind == DeskKind.note ? 3 : 2);
      for (final text in copy) {
        expect(text.style?.color?.a, 1, reason: '${text.data} 不应随背景透明或出现半透明描边');
        expect(text.style?.shadows, isNull);
      }
      expect(
        find.descendant(of: card, matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      await tester.runAsync(() async {
        final restored = DesktopNotes(notes.repository, channel: channel);
        await restored.initialize();
        expect(restored.config(kind).transparent, isTrue);
        expect(restored.config(kind).opacity, 0);
        restored.dispose();
      });

      // The switch stays separate from the stored tint level: turning glass
      // off makes the chosen colour solid, and does not reset the slider.
      await tester.scrollUntilVisible(
        settingSwitch('透明背景'),
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(settingSwitch('透明背景'));
      await waitForChange(tester, () => !notes.config(kind).transparent);
      await reveal(tester, card);
      expect(backdrop, findsNothing);
      final solidDecoration =
          tester.widget<Container>(card).decoration! as BoxDecoration;
      expect(solidDecoration.color!.toARGB32(), background);
      expect(solidDecoration.border, isNull);
      expect(notes.config(kind).opacity, 0);
      await tester.runAsync(() async {
        final restored = DesktopNotes(notes.repository, channel: channel);
        await restored.initialize();
        expect(restored.config(kind).transparent, isFalse);
        expect(restored.config(kind).opacity, 0);
        expect(restored.config(kind).color, background);
        restored.dispose();
      });
      expect(tester.takeException(), isNull);
    });
  }
}
