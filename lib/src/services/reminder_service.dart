import 'dart:async';
import 'dart:convert';

import '../desk/desk_models.dart';
import '../desk/desk_repository.dart';
import '../desk/desktop_notes.dart';
import 'async_gate.dart';

/// 通知标题固定，正文由服务根据待办内容与场景生成。
const String reminderAlertTitle = '待办提醒';

/// 单条通知正文的字符上限，避免超长正文撑爆系统 Toast。
const int reminderBodyMaxLength = 120;

/// 已提醒状态的保留上限；超出后只保留最近的记录。
const int reminderRetention = 500;

/// 待办提醒的实际触发时间（epoch 毫秒）。
///
/// 提前提醒以开始时间为基准换算，绝对提醒直接使用 [DeskEntry.remindAt]；
/// 两者互斥由模型保证，均未设置时返回 null（即不提醒）。
int? todoReminderAt(DeskEntry entry) {
  if (entry.kind != DeskKind.todo || entry.deleted || entry.done) return null;
  final before = entry.remindBeforeMinutes;
  if (before != null) {
    final start = entry.startAt;
    if (start == null) return null;
    return start - before * Duration.millisecondsPerMinute;
  }
  return entry.remindAt;
}

/// 一条待触达的提醒文案。
class ReminderAlert {
  const ReminderAlert({
    required this.body,
    this.title = reminderAlertTitle,
    this.todoId,
    this.missed = false,
    this.count = 1,
  });

  final String title;
  final String body;

  /// 单条提醒对应的待办 id；汇总提醒为 null。
  final String? todoId;

  /// 是否为补发/汇总提醒（应用未运行、休眠或同时到点多条）。
  final bool missed;
  final int count;
}

/// 通知触达通道，生产环境为 Windows Toast；测试可换成假实现。
abstract class ReminderSink {
  Future<void> show(ReminderAlert alert);
}

/// 可注入的定时器句柄，便于单元测试避免真实等待。
abstract class ReminderTimer {
  void cancel();
}

typedef ReminderTimerFactory = ReminderTimer Function(
  Duration delay,
  void Function() onFire,
);

/// “已提醒”状态存储；只在本地保存，不参与同步。
abstract class ReminderStateStore {
  Future<Map<String, int>> load();

  Future<void> save(Map<String, int> fired);
}

/// 复用 [DeskRepository] 的 preference 表保存已提醒状态。
class DeskReminderStateStore implements ReminderStateStore {
  DeskReminderStateStore(this.repository);

  final DeskRepository repository;

  static const String preferenceKey = 'reminder.todo.fired';

  @override
  Future<Map<String, int>> load() async {
    final raw = await repository.preference(preferenceKey);
    if (raw == null || raw.isEmpty) return <String, int>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('提醒状态格式无效');
    final fired = decoded['fired'];
    if (fired is! Map) return <String, int>{};
    final result = <String, int>{};
    for (final entry in fired.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && key.isNotEmpty && value is int) {
        result[key] = value;
      }
    }
    return result;
  }

  @override
  Future<void> save(Map<String, int> fired) => repository.savePreference(
    preferenceKey,
    jsonEncode({'version': 1, 'fired': fired}),
  );
}

ReminderTimer _systemTimer(Duration delay, void Function() onFire) =>
    _SystemTimer(Timer(delay, onFire));

class _SystemTimer implements ReminderTimer {
  _SystemTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

class _PendingReminder {
  _PendingReminder(this.entry, this.triggerAt);

  final DeskEntry entry;
  final int triggerAt;

  String get key => '${entry.id}|$triggerAt';
}

/// 待办提醒调度：按提醒时间触发系统通知，并持久化“已提醒”状态。
///
/// - 只在待办模块开启（[DesktopNotes.enabled]）时调度；
/// - 完成、删除、改时或改提醒后按最新数据重排，已提醒的时间点不会重复弹出；
/// - 启动时把已到点且未提醒的条目汇成一条“已错过”提示，避免逐条轰炸。
class ReminderService {
  ReminderService({
    required this.notes,
    required this.sink,
    required this.store,
    DateTime Function()? now,
    ReminderTimerFactory? timerFactory,
  }) : _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? _systemTimer;

  final DesktopNotes notes;
  final ReminderSink sink;
  final ReminderStateStore store;
  final DateTime Function() _now;
  final ReminderTimerFactory _timerFactory;

  final _gate = AsyncGate();
  final Map<String, int> _fired = {};
  ReminderTimer? _timer;
  int? _scheduledAt;
  bool _started = false, _disposed = false;

  /// 当前已排定的下一次触发时间（epoch 毫秒），无排定时为 null。
  int? get scheduledAt => _scheduledAt;

  /// 启动调度：读取已提醒状态，补发错过汇总，再排定下一条提醒。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    notes.addListener(_onNotesChanged);
    await _gate.run(() async {
      _fired
        ..clear()
        ..addAll(await _loadFired());
      await _flush(catchUp: true);
    });
  }

  /// 立即按当前时钟重新评估一次（与定时器、数据变更走同一条串行通道）。
  Future<void> refresh() => _gate.run(() => _flush(catchUp: false));

  void _onNotesChanged() {
    if (_disposed) return;
    unawaited(_gate.run(() => _flush(catchUp: false)));
  }

  Future<Map<String, int>> _loadFired() async {
    try {
      return await store.load();
    } catch (_) {
      // 状态损坏时按“从未提醒”处理，宁可多提醒一次也不能漏提醒。
      return <String, int>{};
    }
  }

  Future<void> _flush({required bool catchUp}) async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _scheduledAt = null;

    final nowMs = _now().millisecondsSinceEpoch;
    final pending = _pending();
    final due = <_PendingReminder>[];
    _PendingReminder? next;
    for (final reminder in pending) {
      if (_fired.containsKey(reminder.key)) continue;
      if (reminder.triggerAt <= nowMs) {
        due.add(reminder);
      } else if (next == null || reminder.triggerAt < next.triggerAt) {
        next = reminder;
      }
    }

    if (due.isNotEmpty) {
      for (final reminder in due) {
        _fired[reminder.key] = nowMs;
      }
      _prune();
      await _save();
      await _emitAlert(due, catchUp: catchUp);
    }

    if (next != null && !_disposed) {
      final delay = next.triggerAt - _now().millisecondsSinceEpoch;
      _scheduledAt = next.triggerAt;
      _timer = _timerFactory(Duration(milliseconds: delay < 0 ? 0 : delay), () {
        _timer = null;
        _scheduledAt = null;
        unawaited(_gate.run(() => _flush(catchUp: false)));
      });
    }
  }

  List<_PendingReminder> _pending() {
    if (!notes.enabled(DeskKind.todo)) return const [];
    final result = <_PendingReminder>[];
    for (final entry in notes.items(DeskKind.todo)) {
      final triggerAt = todoReminderAt(entry);
      if (triggerAt == null) continue;
      result.add(_PendingReminder(entry, triggerAt));
    }
    return result;
  }

  Future<void> _emitAlert(
    List<_PendingReminder> due, {
    required bool catchUp,
  }) async {
    if (catchUp) {
      await _emit(
        ReminderAlert(
          body: '有 ${due.length} 条待办提醒已错过',
          missed: true,
          count: due.length,
        ),
      );
      return;
    }
    if (due.length == 1) {
      final reminder = due.single;
      await _emit(
        ReminderAlert(
          body: _alertText(reminder.entry),
          todoId: reminder.entry.id,
        ),
      );
      return;
    }
    // 休眠唤醒或同一分钟到点多条时合并成一条，避免逐条轰炸。
    await _emit(
      ReminderAlert(
        body: '有 ${due.length} 条待办提醒已到时间',
        missed: true,
        count: due.length,
      ),
    );
  }

  Future<void> _emit(ReminderAlert alert) async {
    try {
      await sink.show(alert);
    } catch (_) {
      // 通知失败不能影响待办数据与后续调度。
    }
  }

  String _alertText(DeskEntry entry) {
    final title = entry.title.trim();
    if (title.isNotEmpty) return _clip(title);
    for (final line in entry.body.split('\n')) {
      final text = line.trim();
      if (text.isNotEmpty) return _clip(text);
    }
    return '待办提醒';
  }

  static String _clip(String value) => value.length <= reminderBodyMaxLength
      ? value
      : '${value.substring(0, reminderBodyMaxLength)}…';

  /// 丢弃已不存在的条目，并按时间保留最近的记录。
  void _prune() {
    final ids = notes.entries
        .where((entry) => entry.kind == DeskKind.todo)
        .map((entry) => entry.id)
        .toSet();
    _fired.removeWhere((key, _) {
      final separator = key.indexOf('|');
      if (separator <= 0) return true;
      return !ids.contains(key.substring(0, separator));
    });
    if (_fired.length <= reminderRetention) return;
    final recent = _fired.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final kept = {
      for (final entry in recent.take(reminderRetention))
        entry.key: entry.value,
    };
    _fired
      ..clear()
      ..addAll(kept);
  }

  Future<void> _save() async {
    try {
      await store.save(Map<String, int>.of(_fired));
    } catch (_) {
      // 写入失败时仍完成本轮提醒，下次启动最多重复一次。
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    notes.removeListener(_onNotesChanged);
    _timer?.cancel();
    _timer = null;
    _scheduledAt = null;
  }
}
