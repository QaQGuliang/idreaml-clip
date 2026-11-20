import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_management_list.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DeskEntry entry(
    String id, {
    DeskKind kind = DeskKind.todo,
    int created = 0,
    bool done = false,
    int? startAt,
    int? endAt,
    int? remindAt,
    int? remindBeforeMinutes,
  }) => DeskEntry(
    id: id,
    revision: 'revision-$id',
    kind: kind,
    title: '',
    body: '事项 $id',
    done: done,
    startAt: startAt,
    endAt: endAt,
    remindAt: remindAt,
    remindBeforeMinutes: remindBeforeMinutes,
    created: created,
    updated: created,
    clock: const {'device': 1},
  );

  DesktopNotes host(List<DeskEntry> values, {MethodChannel? channel}) {
    final notes = DesktopNotes(
      DeskRepository(deviceId: 'schedule-test'),
      channel: channel,
    );
    notes.entries = values;
    for (final kind in DeskKind.values) {
      notes.settings[kind] = const DeskSettings(enabled: true);
    }
    return notes;
  }

  group('待办排序', () {
    test('有开始时间的未完成待办按开始时间升序在前，其余保持原顺序', () {
      final notes = host([
        entry('late', created: 300, startAt: 3000),
        entry('none', created: 200),
        entry('early', created: 100, startAt: 1000),
        entry('done', created: 400, done: true, startAt: 500),
        entry('note', kind: DeskKind.note, created: 500),
      ]);
      expect(notes.items(DeskKind.todo).map((e) => e.id), [
        'early',
        'late',
        'done',
        'none',
      ]);
      // 便签顺序不受影响。
      expect(notes.items(DeskKind.note).map((e) => e.id), ['note']);
      notes.dispose();
    });

    test('开始时间相同的条目保持原有相对顺序', () {
      final notes = host([
        entry('older', created: 100, startAt: 5000),
        entry('newer', created: 300, startAt: 5000),
        entry('plain', created: 200),
      ]);
      expect(notes.items(DeskKind.todo).map((e) => e.id), [
        'newer',
        'older',
        'plain',
      ]);
      notes.dispose();
    });

    test('已完成待办与无时间待办都留在原分组顺序中', () {
      final notes = host([
        entry('scheduled', created: 50, startAt: 9000),
        entry('done-1', created: 400, done: true),
        entry('done-2', created: 300, done: true),
        entry('plain-1', created: 200),
        entry('plain-2', created: 100),
      ]);
      expect(notes.items(DeskKind.todo).map((e) => e.id), [
        'scheduled',
        'done-1',
        'done-2',
        'plain-1',
        'plain-2',
      ]);
      notes.dispose();
    });
  });

  test('发布给原生的待办 rows 保留时间字段并按开始时间排序', () async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel('test/desk_schedule_publish');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final notes = host([
      entry('late', created: 300, startAt: 3000, endAt: 4000),
      entry('plain', created: 200),
      entry('early', created: 100, startAt: 1000, remindBeforeMinutes: 15),
      entry('done', created: 400, done: true, startAt: 500),
    ], channel: channel);
    await notes.attachNative();
    final config =
        calls.lastWhere((call) => call.method == 'configure').arguments as Map;
    final rows = (config['todo']['rows'] as List).cast<Map>();
    expect(rows.map((row) => row['id']), ['early', 'late', 'plain']);
    expect(rows[0]['startAt'], 1000);
    expect(rows[0]['remindBeforeMinutes'], 15);
    expect(rows[1]['endAt'], 4000);
    expect(rows[2].containsKey('startAt'), isFalse);
    notes.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('时间文案', () {
    final now = DateTime(2026, 11, 21, 8, 30);

    test('今天与明天使用相对前缀，其他日期用月/日', () {
      final today = DateTime(2026, 11, 21, 9);
      expect(
        deskScheduleLabel(
          entry('a', startAt: today.millisecondsSinceEpoch),
          now: now,
        ),
        '今天 09:00',
      );
      expect(
        deskScheduleLabel(
          entry('b', startAt: DateTime(2026, 11, 22, 9).millisecondsSinceEpoch),
          now: now,
        ),
        '明天 09:00',
      );
      expect(
        deskScheduleLabel(
          entry(
            'c',
            startAt: DateTime(2026, 11, 25, 7, 5).millisecondsSinceEpoch,
          ),
          now: now,
        ),
        '11/25 07:05',
      );
      expect(
        deskScheduleLabel(
          entry(
            'd',
            startAt: DateTime(2027, 1, 5, 7, 5).millisecondsSinceEpoch,
          ),
          now: now,
        ),
        '2027/1/5 07:05',
      );
    });

    test('同一天区间合并为一条，跨天显示两端日期，只有结束时间用"截止"', () {
      expect(
        deskScheduleLabel(
          entry(
            'a',
            startAt: DateTime(2026, 11, 21, 9).millisecondsSinceEpoch,
            endAt: DateTime(2026, 11, 21, 10, 30).millisecondsSinceEpoch,
          ),
          now: now,
        ),
        '今天 09:00–10:30',
      );
      expect(
        deskScheduleLabel(
          entry(
            'b',
            startAt: DateTime(2026, 11, 21, 22).millisecondsSinceEpoch,
            endAt: DateTime(2026, 11, 22, 8).millisecondsSinceEpoch,
          ),
          now: now,
        ),
        '今天 22:00 – 明天 08:00',
      );
      expect(
        deskScheduleLabel(
          entry('c', endAt: DateTime(2026, 11, 22, 18).millisecondsSinceEpoch),
          now: now,
        ),
        '截止 明天 18:00',
      );
      expect(deskScheduleLabel(entry('d'), now: now), isNull);
    });

    test('未完成待办按结束时间（无则开始时间）判定逾期', () {
      final past = now.subtract(const Duration(minutes: 5));
      final future = now.add(const Duration(minutes: 5));
      expect(
        deskTodoOverdue(
          entry(
            'a',
            startAt: past.millisecondsSinceEpoch,
            endAt: past.millisecondsSinceEpoch,
          ),
          now: now,
        ),
        isTrue,
      );
      expect(
        deskTodoOverdue(
          entry('b', startAt: past.millisecondsSinceEpoch),
          now: now,
        ),
        isTrue,
      );
      expect(
        deskTodoOverdue(
          entry('c', endAt: future.millisecondsSinceEpoch),
          now: now,
        ),
        isFalse,
      );
      expect(
        deskTodoOverdue(
          entry('d', done: true, endAt: past.millisecondsSinceEpoch),
          now: now,
        ),
        isFalse,
      );
      expect(deskTodoOverdue(entry('e'), now: now), isFalse);
      expect(
        deskTodoReminded(entry('f', remindBeforeMinutes: 10, startAt: 1)),
        isTrue,
      );
      expect(deskTodoReminded(entry('g')), isFalse);
    });
  });

  group('管理页列表', () {
    Widget list(DesktopNotes notes, DeskKind kind) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: DeskManagementList(
          notes: notes,
          kind: kind,
          onCreate: () {},
          onEdit: (_) {},
          onDelete: (_) {},
          onResolve: (_) {},
        ),
      ),
    );

    testWidgets('展示时间徽标，逾期用警示色并标注，有提醒显示铃铛', (tester) async {
      final now = DateTime.now();
      final notes = host([
        entry(
          'upcoming',
          created: 400,
          startAt: now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
          endAt: now.add(const Duration(hours: 3)).millisecondsSinceEpoch,
        ),
        entry(
          'overdue',
          created: 300,
          startAt: now
              .subtract(const Duration(minutes: 20))
              .millisecondsSinceEpoch,
          remindBeforeMinutes: 10,
        ),
        entry('plain', created: 200),
        entry('note', kind: DeskKind.note, created: 100, startAt: 1),
      ]);
      await tester.pumpWidget(list(notes, DeskKind.todo));

      expect(
        find.byKey(const ValueKey('desk-entry-schedule-upcoming')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('desk-entry-overdue-upcoming')),
        findsNothing,
      );
      final upcoming = tester.widget<Text>(
        find.byKey(const ValueKey('desk-entry-schedule-upcoming')),
      );
      expect(upcoming.style!.color, AppColors.muted);
      expect(upcoming.data, contains(':'));

      final overdue = tester.widget<Text>(
        find.byKey(const ValueKey('desk-entry-schedule-overdue')),
      );
      expect(overdue.style!.color, AppColors.danger);
      expect(
        find.byKey(const ValueKey('desk-entry-overdue-overdue')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('desk-entry-overdue-overdue')),
            )
            .style!
            .color,
        AppColors.danger,
      );
      expect(
        find.byKey(const ValueKey('desk-entry-reminder-overdue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('desk-entry-reminder-upcoming')),
        findsNothing,
      );
      // 没有时间的待办不显示时间行。
      expect(
        find.byKey(const ValueKey('desk-entry-schedule-plain')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // 便签列表即使带时间字段也不显示时间行。
      await tester.pumpWidget(list(notes, DeskKind.note));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desk-entry-schedule-note')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      notes.dispose();
    });
  });
}
