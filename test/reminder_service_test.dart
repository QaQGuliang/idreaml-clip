import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/services/reminder_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 记录排定请求，测试可手动触发，避免真实等待。
class _FakeTimer implements ReminderTimer {
  _FakeTimer(this.delay, this.onFire);

  final Duration delay;
  final void Function() onFire;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;

  void fire() {
    if (cancelled) return;
    cancelled = true;
    onFire();
  }
}

class _FakeTimers {
  final List<_FakeTimer> timers = [];

  ReminderTimer create(Duration delay, void Function() onFire) {
    final timer = _FakeTimer(delay, onFire);
    timers.add(timer);
    return timer;
  }

  bool get hasActive => timers.any((timer) => !timer.cancelled);

  _FakeTimer get current => timers.lastWhere((timer) => !timer.cancelled);

  void fireCurrent() => current.fire();
}

class _FakeSink implements ReminderSink {
  final List<ReminderAlert> alerts = [];

  @override
  Future<void> show(ReminderAlert alert) async => alerts.add(alert);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeskRepository repository;
  late DesktopNotes notes;
  late DateTime clock;
  late DateTime base;
  late _FakeTimers timers;
  late _FakeSink sink;
  final services = <ReminderService>[];

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-reminder-');
    repository = DeskRepository(
      deviceId: 'reminder-device',
      testPath: p.join(root.path, 'desktop.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
    notes = DesktopNotes(repository);
    await notes.initialize();
    await notes.updateSettings(DeskKind.todo, {'enabled': true});
    base = DateTime(2026, 1, 1, 8);
    clock = base;
    services.clear();
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    notes.dispose();
    await root.delete(recursive: true);
  });

  /// 相对固定基准时间换算，便于跨“重启”后仍使用同一时间轴。
  DateTime at(int minutes) => base.add(Duration(minutes: minutes));

  ReminderService createService() {
    timers = _FakeTimers();
    sink = _FakeSink();
    final service = ReminderService(
      notes: notes,
      sink: sink,
      store: DeskReminderStateStore(repository),
      now: () => clock,
      timerFactory: timers.create,
    );
    services.add(service);
    return service;
  }

  /// 数据变更触发的重排是异步的，经同一条串行通道再评估一次即可确定完成。
  Future<void> settle(ReminderService service) => service.refresh();

  test('提醒时间按绝对时间或开始前 N 分钟换算，完成与删除不再提醒', () {
    DeskEntry entry({
      int? startAt,
      int? remindAt,
      int? remindBeforeMinutes,
      bool done = false,
      bool deleted = false,
      DeskKind kind = DeskKind.todo,
    }) => DeskEntry(
      id: 'id',
      revision: 'rev',
      kind: kind,
      title: '',
      body: '内容',
      done: done,
      deleted: deleted,
      startAt: startAt,
      remindAt: remindAt,
      remindBeforeMinutes: remindBeforeMinutes,
      created: 1,
      updated: 1,
      clock: const {'device': 1},
    );

    const start = 1767225600000;
    expect(
      todoReminderAt(entry(startAt: start, remindBeforeMinutes: 30)),
      start - 30 * 60000,
    );
    expect(todoReminderAt(entry(remindAt: start + 5000)), start + 5000);
    expect(todoReminderAt(entry(startAt: start)), isNull);
    expect(todoReminderAt(entry(kind: DeskKind.note, remindAt: start)), isNull);
    expect(
      todoReminderAt(entry(remindAt: start, remindBeforeMinutes: 5)),
      isNull,
    );
    expect(todoReminderAt(entry(remindAt: start, done: true)), isNull);
    expect(todoReminderAt(entry(remindAt: start, deleted: true)), isNull);
    // 缺少开始时间时提前提醒无法换算，避免误报。
    expect(todoReminderAt(entry(remindBeforeMinutes: 15)), isNull);
  });

  test('按绝对提醒时间排定，到点弹出一条通知且只弹一次', () async {
    await notes.save(
      DeskKind.todo,
      body: '提交周报',
      remindAt: at(10).millisecondsSinceEpoch,
    );
    final service = createService();
    await service.start();
    expect(sink.alerts, isEmpty);
    expect(timers.hasActive, isTrue);
    expect(timers.current.delay, const Duration(minutes: 10));
    expect(service.scheduledAt, at(10).millisecondsSinceEpoch);

    clock = at(10);
    timers.fireCurrent();
    await settle(service);

    expect(sink.alerts, hasLength(1));
    expect(sink.alerts.single.missed, isFalse);
    expect(sink.alerts.single.body, '提交周报');
    expect(sink.alerts.single.count, 1);
    expect(timers.hasActive, isFalse);

    // 数据变更（标题编辑）与再次评估都不会重复弹出同一提醒。
    final entry = notes.items(DeskKind.todo).single;
    await notes.save(
      DeskKind.todo,
      id: entry.id,
      title: '改过的标题',
      body: '提交周报',
      remindAt: entry.remindAt,
      expected: {entry.revision},
    );
    await settle(service);
    await settle(service);
    expect(sink.alerts, hasLength(1));
    expect(timers.hasActive, isFalse);
  });

  test('提前提醒按开始时间提前排定', () async {
    await notes.save(
      DeskKind.todo,
      body: '开会',
      startAt: at(60).millisecondsSinceEpoch,
      remindBeforeMinutes: 45,
    );
    final service = createService();
    await service.start();
    expect(timers.current.delay, const Duration(minutes: 15));

    clock = at(15);
    timers.fireCurrent();
    await settle(service);
    expect(sink.alerts.single.body, '开会');
  });

  test('完成、删除、修改提醒时间后取消或重排对应提醒', () async {
    await notes.save(
      DeskKind.todo,
      body: '交报表',
      remindAt: at(30).millisecondsSinceEpoch,
    );
    final entry = notes.items(DeskKind.todo).single;
    final service = createService();
    await service.start();
    expect(timers.current.delay, const Duration(minutes: 30));

    await notes.toggle(entry);
    await settle(service);
    expect(timers.hasActive, isFalse, reason: '完成后不再提醒');
    expect(sink.alerts, isEmpty);

    await notes.toggle(notes.items(DeskKind.todo).single);
    await settle(service);
    expect(timers.hasActive, isTrue, reason: '取消完成恢复提醒');
    expect(timers.current.delay, const Duration(minutes: 30));

    final current = notes.items(DeskKind.todo).single;
    await notes.save(
      DeskKind.todo,
      id: current.id,
      body: '交报表',
      remindAt: at(50).millisecondsSinceEpoch,
      expected: {current.revision},
    );
    await settle(service);
    expect(timers.current.delay, const Duration(minutes: 50), reason: '改时后重排');
    expect(sink.alerts, isEmpty);

    await notes.remove(notes.items(DeskKind.todo).single);
    await settle(service);
    expect(timers.hasActive, isFalse, reason: '删除后取消');
    expect(sink.alerts, isEmpty);
  });

  test('重启后恢复未到点提醒，已提醒的时间点跨重启不重复弹出', () async {
    await notes.save(
      DeskKind.todo,
      body: '喝水',
      remindAt: at(10).millisecondsSinceEpoch,
    );
    final first = createService();
    await first.start();
    expect(timers.current.delay, const Duration(minutes: 10));

    clock = at(10);
    timers.fireCurrent();
    await settle(first);
    expect(sink.alerts, hasLength(1));
    first.dispose();

    clock = at(12);
    final restarted = createService();
    await restarted.start();
    expect(sink.alerts, isEmpty, reason: '已提醒的条目不重复弹出');
    expect(timers.hasActive, isFalse);

    // 未到点的提醒在重启后按剩余时间重新排定。
    await notes.save(
      DeskKind.todo,
      body: '写日报',
      remindAt: at(70).millisecondsSinceEpoch,
    );
    await settle(restarted);
    expect(sink.alerts, isEmpty);
    expect(timers.current.delay, const Duration(minutes: 58));
  });

  test('启动时把错过的提醒汇总成一条，已完成的不计入', () async {
    await notes.save(
      DeskKind.todo,
      body: '错过一',
      remindAt: at(-180).millisecondsSinceEpoch,
    );
    await notes.save(
      DeskKind.todo,
      body: '错过二',
      remindAt: at(-120).millisecondsSinceEpoch,
    );
    await notes.save(
      DeskKind.todo,
      body: '错过三',
      remindAt: at(-60).millisecondsSinceEpoch,
    );
    await notes.save(
      DeskKind.todo,
      body: '启动前已完成',
      done: true,
      remindAt: at(-90).millisecondsSinceEpoch,
    );
    await notes.save(
      DeskKind.todo,
      body: '还没到点',
      remindAt: at(30).millisecondsSinceEpoch,
    );
    final service = createService();
    await service.start();

    expect(sink.alerts, hasLength(1), reason: '不逐条轰炸');
    final alert = sink.alerts.single;
    expect(alert.missed, isTrue);
    expect(alert.count, 3);
    expect(alert.body, '有 3 条待办提醒已错过');
    expect(alert.todoId, isNull);
    expect(timers.current.delay, const Duration(minutes: 30));

    // 补发同样写入已提醒状态，重启后不再重复汇总。
    service.dispose();
    final restarted = createService();
    await restarted.start();
    expect(sink.alerts, isEmpty);
  });

  test('待办模块关闭时不调度也不提醒', () async {
    await notes.save(
      DeskKind.todo,
      body: '关模块后不提醒',
      remindAt: at(-30).millisecondsSinceEpoch,
    );
    await notes.updateSettings(DeskKind.todo, {'enabled': false});
    final service = createService();
    await service.start();
    expect(notes.enabled(DeskKind.todo), isFalse);
    expect(sink.alerts, isEmpty);
    expect(timers.hasActive, isFalse);
  });

  test('运行中关闭待办模块会取消已排定的提醒', () async {
    await notes.save(
      DeskKind.todo,
      body: '待会儿提醒',
      remindAt: at(20).millisecondsSinceEpoch,
    );
    final service = createService();
    await service.start();
    expect(timers.current.delay, const Duration(minutes: 20));

    await notes.updateSettings(DeskKind.todo, {'enabled': false});
    await settle(service);
    expect(timers.hasActive, isFalse);
    expect(sink.alerts, isEmpty);
  });

  test('已提醒状态保存在本地 preference 中，可跨实例读取', () async {
    final store = DeskReminderStateStore(repository);
    expect(await store.load(), isEmpty);
    await store.save({
      'todo-1|1767225600000': 1767225600000,
      'todo-2|1767225660000': 1767225660000,
    });
    final reopened = DeskReminderStateStore(repository);
    expect(await reopened.load(), {
      'todo-1|1767225600000': 1767225600000,
      'todo-2|1767225660000': 1767225660000,
    });
  });
}
