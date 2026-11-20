import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_pages.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeskRepository a, b;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-desk-time-');
    a = DeskRepository(
      deviceId: 'device-a',
      testPath: p.join(root.path, 'a.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
    b = DeskRepository(
      deviceId: 'device-b',
      testPath: p.join(root.path, 'b.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  const start = 1767225600000; // 2026-01-01 08:00:00 +08:00
  const end = start + 90 * 60 * 1000;

  test('时间与提醒字段仅在设置后写入 JSON，可往返且容忍未知字段', () async {
    final planned = await a.save(
      DeskKind.todo,
      body: '带起止时间的待办',
      startAt: start,
      endAt: end,
      remindBeforeMinutes: 30,
    );
    final json = planned.toJson();
    expect(json['startAt'], start);
    expect(json['endAt'], end);
    expect(json['remindBeforeMinutes'], 30);
    expect(json.containsKey('remindAt'), isFalse);
    final restored = DeskEntry.fromJson(Map<String, dynamic>.from(json));
    expect(restored.startAt, start);
    expect(restored.endAt, end);
    expect(restored.remindBeforeMinutes, 30);
    expect(restored.remindAt, isNull);

    final absolute = await a.save(
      DeskKind.todo,
      body: '无开始时间的绝对提醒',
      remindAt: start,
    );
    expect(absolute.startAt, isNull);
    expect(absolute.remindAt, start);
    final absoluteJson = absolute.toJson();
    expect(absoluteJson.containsKey('remindBeforeMinutes'), isFalse);
    expect(
      DeskEntry.fromJson({...absoluteJson, 'futureField': true}).remindAt,
      start,
    );

    final plain = await a.save(DeskKind.todo, body: '不安排时间');
    expect(plain.toJson().containsKey('startAt'), isFalse);
    expect(plain.toJson().containsKey('remindAt'), isFalse);
    final legacy = DeskEntry.fromJson(
      Map<String, dynamic>.from(plain.toJson()),
    );
    expect(legacy.startAt, isNull);
    expect(legacy.endAt, isNull);
    expect(legacy.remindAt, isNull);
    expect(legacy.remindBeforeMinutes, isNull);
    final stored = (await a.load()).singleWhere((e) => e.id == plain.id);
    expect(stored.startAt, isNull);
    expect(stored.endAt, isNull);
    expect(stored.remindAt, isNull);
    expect(stored.remindBeforeMinutes, isNull);
  });

  test('仓库与模型共用校验：时间不正、结束早于开始、提醒冲突或越界均拒绝', () async {
    final base = await a.save(DeskKind.todo, body: '基准待办');
    final valid = base.toJson();

    for (final invalid in <Map<String, Object?>>[
      {'startAt': 0},
      {'startAt': -1},
      {'remindAt': 0},
      {'startAt': start, 'endAt': start - 1},
      {'startAt': start, 'remindAt': start, 'remindBeforeMinutes': 5},
      {'remindAt': start, 'remindBeforeMinutes': 5},
      {'remindBeforeMinutes': 5},
      {'startAt': start, 'remindBeforeMinutes': 0},
      {'startAt': start, 'remindBeforeMinutes': 10081},
      {'startAt': 1.5},
      {'remindBeforeMinutes': 5.0},
    ]) {
      expect(
        () => DeskEntry.fromJson({...valid, ...invalid}),
        throwsFormatException,
        reason: '模型应拒绝 $invalid',
      );
    }

    Future<void> rejects(
      String reason,
      Future<Object?> Function() action,
    ) async {
      await expectLater(action(), throwsFormatException, reason: reason);
    }

    await rejects(
      '开始时间为 0',
      () => a.save(DeskKind.todo, body: 'x', startAt: 0),
    );
    await rejects(
      '开始时间为负',
      () => a.save(DeskKind.todo, body: 'x', startAt: -1),
    );
    await rejects(
      '结束早于开始',
      () => a.save(DeskKind.todo, body: 'x', startAt: start, endAt: start - 1),
    );
    await rejects(
      '两种提醒并存',
      () => a.save(
        DeskKind.todo,
        body: 'x',
        startAt: start,
        remindAt: start,
        remindBeforeMinutes: 5,
      ),
    );
    await rejects(
      '提前提醒无开始时间',
      () => a.save(DeskKind.todo, body: 'x', remindBeforeMinutes: 5),
    );
    await rejects(
      '提前提醒为 0',
      () => a.save(
        DeskKind.todo,
        body: 'x',
        startAt: start,
        remindBeforeMinutes: 0,
      ),
    );
    await rejects(
      '提前提醒超过 7 天',
      () => a.save(
        DeskKind.todo,
        body: 'x',
        startAt: start,
        remindBeforeMinutes: 10081,
      ),
    );
    expect((await a.load()).single.revision, base.revision);

    final edge = await a.save(
      DeskKind.todo,
      id: base.id,
      body: base.body,
      startAt: start,
      endAt: start,
      remindBeforeMinutes: deskRemindBeforeMinutesMax,
      expected: {base.revision},
    );
    expect(edge.endAt, start);
    expect(edge.remindBeforeMinutes, 10080);
    expect(deskTitleMaxLength, 120);
  });

  test('勾选完成保留时间与提醒，删除墓碑清空时间字段', () async {
    final notes = DesktopNotes(a);
    addTearDown(notes.dispose);
    await notes.initialize();
    await notes.updateSettings(DeskKind.todo, {'enabled': true});
    await notes.save(
      DeskKind.todo,
      body: '需要提醒的事项',
      startAt: start,
      endAt: end,
      remindBeforeMinutes: 15,
    );
    await notes.toggle(notes.items(DeskKind.todo).single);
    var entry = notes.items(DeskKind.todo).single;
    expect(entry.done, isTrue);
    expect(entry.startAt, start);
    expect(entry.endAt, end);
    expect(entry.remindBeforeMinutes, 15);
    expect(entry.remindAt, isNull);
    await notes.toggle(entry);
    entry = notes.items(DeskKind.todo).single;
    expect(entry.done, isFalse);
    expect(entry.startAt, start);
    expect(entry.remindBeforeMinutes, 15);

    await notes.remove(entry);
    expect(notes.items(DeskKind.todo), isEmpty);
    final tombstone = (await a.load()).single;
    expect(tombstone.deleted, isTrue);
    expect(tombstone.title, isEmpty);
    expect(tombstone.body, isEmpty);
    expect(tombstone.startAt, isNull);
    expect(tombstone.endAt, isNull);
    expect(tombstone.remindAt, isNull);
    expect(tombstone.remindBeforeMinutes, isNull);
    for (final key in ['startAt', 'endAt', 'remindAt', 'remindBeforeMinutes']) {
      expect(tombstone.toJson().containsKey(key), isFalse);
    }
  });

  test('标题保存统一限制 120 字，读取兼容旧版 200 字', () async {
    final title = '标' * deskTitleMaxLength;
    final saved = await a.save(DeskKind.note, title: title, body: '正文');
    expect(saved.title.length, 120);
    await expectLater(
      a.save(DeskKind.note, title: '$title多', body: '正文'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('标题最多 120 字'),
        ),
      ),
    );
    final legacy = DeskEntry.fromJson({
      ...saved.toJson(),
      'title': '标' * deskTitleLegacyMaxLength,
    });
    expect(legacy.title.length, deskTitleLegacyMaxLength);
    expect(
      () => DeskEntry.fromJson({
        ...saved.toJson(),
        'title': '标' * (deskTitleLegacyMaxLength + 1),
      }),
      throwsFormatException,
    );
    expect((await a.load()).single.title.length, 120);
  });

  test('同步归档整条保留时间与提醒，旧数据缺字段仍可读取合并', () async {
    final planned = await a.save(
      DeskKind.todo,
      body: '跨设备提醒事项',
      startAt: start,
      endAt: end,
      remindBeforeMinutes: 5,
    );
    await a.save(DeskKind.todo, body: '没有时间的旧事项');
    final git = Directory(p.join(root.path, 'remote'));
    await a.synchronize(git, {DeskKind.todo});

    final metadata = Directory(p.join(git.path, 'config', 'metadata', 'todos'));
    final archived = (await metadata.list().toList()).whereType<File>();
    final json = await Future.wait(
      archived.map(
        (f) async => jsonDecode(await f.readAsString()) as Map<String, dynamic>,
      ),
    );
    final plannedJson = json.singleWhere((value) => value['id'] == planned.id);
    expect(plannedJson['startAt'], start);
    expect(plannedJson['endAt'], end);
    expect(plannedJson['remindBeforeMinutes'], 5);
    expect(plannedJson.containsKey('remindAt'), isFalse);
    expect(plannedJson.containsKey('body'), isFalse);

    await b.synchronize(git, {DeskKind.todo});
    final incoming = (await b.load()).singleWhere(
      (entry) => entry.id == planned.id,
    );
    expect(incoming.startAt, start);
    expect(incoming.endAt, end);
    expect(incoming.remindBeforeMinutes, 5);
    final legacy = (await b.load()).singleWhere(
      (entry) => entry.id != planned.id,
    );
    expect(legacy.startAt, isNull);
    expect(legacy.remindAt, isNull);
    expect(legacy.remindBeforeMinutes, isNull);

    // 旧版本同步数据（不含时间字段）仍可导入。
    final legacyRoot = Directory(p.join(root.path, 'legacy'));
    final legacyFolder = Directory(
      p.join(legacyRoot.path, 'desktop-v1', 'todo'),
    );
    await legacyFolder.create(recursive: true);
    final older = await b.save(DeskKind.todo, body: '更旧的待办');
    final olderJson = older.toJson()
      ..remove('startAt')
      ..remove('endAt')
      ..remove('remindAt')
      ..remove('remindBeforeMinutes');
    await File(p.join(legacyFolder.path, 'device-old.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'kind': 'todo',
        'entries': [olderJson],
      }),
    );
    final c = DeskRepository(
      deviceId: 'device-c',
      testPath: p.join(root.path, 'c.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
    expect(await c.importLegacy(legacyRoot), 1);
    final imported = (await c.load()).single;
    expect(imported.body, '更旧的待办');
    expect(imported.startAt, isNull);
    expect(imported.remindAt, isNull);
  });

  test('界面字段校验与提醒预览复用同一套时间规则', () {
    expect(validateDeskScheduleFields(DeskSchedule.empty).isEmpty, isTrue);
    expect(
      validateDeskScheduleFields(DeskSchedule(startAt: start, endAt: start - 1))
          .end,
      '结束时间不能早于开始时间',
    );
    expect(
      validateDeskScheduleFields(DeskSchedule(startAt: start, endAt: start))
          .isEmpty,
      isTrue,
    );
    expect(
      validateDeskScheduleFields(const DeskSchedule(remindBeforeMinutes: 15))
          .remind,
      '提前提醒需要先设置开始时间',
    );
    expect(
      validateDeskScheduleFields(
        DeskSchedule(startAt: start, remindAt: start, remindBeforeMinutes: 15),
      ).remind,
      '提醒只能保留一种方式，请清除后重新设置',
    );
    expect(
      validateDeskScheduleFields(
        DeskSchedule(startAt: start, remindBeforeMinutes: 0),
      ).remind,
      '提前提醒须为 1–10080 分钟',
    );
    expect(
      deskScheduleReminderAt(
        DeskSchedule(startAt: start, remindBeforeMinutes: 15),
      ),
      start - 15 * Duration.millisecondsPerMinute,
    );
    expect(deskScheduleReminderAt(const DeskSchedule(remindAt: start)), start);
    expect(deskScheduleReminderAt(DeskSchedule.empty), isNull);
    expect(
      deskReminderPreview(DeskSchedule(startAt: start, remindBeforeMinutes: 5)),
      contains('提醒'),
    );
    expect(parseDeskDate('2026-02-30'), isNull);
    expect(parseDeskDate('2026-2-28'), isNotNull);
    expect(parseDeskDate('2026/02/28'), isNull);
    expect(
      deskScheduleStamp(start),
      matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    );
    expect(
      deskScheduleSummary(
        DeskSchedule(startAt: start, endAt: start, remindBeforeMinutes: 5),
      ),
      contains('提前 5 分钟提醒'),
    );
  });
}
