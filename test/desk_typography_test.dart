import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_pages.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
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
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
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
}
