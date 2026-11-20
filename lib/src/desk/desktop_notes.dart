import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/async_gate.dart';
import '../models/sync_models.dart';

import 'desk_models.dart';
import 'desk_repository.dart';

class DesktopNotes extends ChangeNotifier {
  DesktopNotes(this.repository, {MethodChannel? channel})
    : channel = channel ?? const MethodChannel('idreaml_clip/desktop_notes');
  final DeskRepository repository;
  final MethodChannel channel;
  final settings = <DeskKind, DeskSettings>{};
  List<DeskEntry> entries = [];
  String? error;
  int? ignoredClipboardSequence;
  bool _native = false, _disposed = false;
  Future<void> Function(DeskKind, String)? openManager;

  /// 打开 Flutter 快速新增页面；由 [DesktopService] 在 Windows 上接线。
  Future<void> Function(DeskKind kind, {bool hotkey})? openComposer;
  Future<void>? _publishing;
  int _revision = 0;
  final _settingsGate = AsyncGate();

  DeskSettings config(DeskKind kind) => settings[kind] ?? const DeskSettings();
  bool enabled(DeskKind kind) => config(kind).enabled;
  SyncModuleState syncState(DeskKind kind) {
    if (!enabled(kind)) return SyncModuleState.featureDisabled;
    return config(kind).sync
        ? SyncModuleState.participating
        : SyncModuleState.syncDisabled;
  }

  List<DeskEntry> versions(String id) =>
      entries.where((e) => e.id == id).toList();
  List<DeskEntry> items(DeskKind kind) {
    final ids = <String>{};
    final sorted = entries.where((e) => e.kind == kind && !e.deleted).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    final values = sorted.where((e) => ids.add(e.id)).toList();
    // 便签沿用建立时间倒序；待办把已安排开始时间的未完成事项按开始时间
    // 升序前置，其余（含已完成）保持原有顺序，分组不受影响。
    return kind == DeskKind.todo ? _scheduledFirst(values) : values;
  }

  /// 稳定排序：开始时间相同的条目保持原有相对顺序。
  static List<DeskEntry> _scheduledFirst(List<DeskEntry> values) {
    final scheduled = <({int index, DeskEntry entry})>[];
    final rest = <DeskEntry>[];
    for (var index = 0; index < values.length; index++) {
      final entry = values[index];
      if (!entry.done && entry.startAt != null) {
        scheduled.add((index: index, entry: entry));
      } else {
        rest.add(entry);
      }
    }
    scheduled.sort((a, b) {
      final byStart = a.entry.startAt!.compareTo(b.entry.startAt!);
      return byStart != 0 ? byStart : a.index.compareTo(b.index);
    });
    return [...scheduled.map((e) => e.entry), ...rest];
  }

  List<String> conflicts(DeskKind kind) => entries
      .where((e) => e.kind == kind)
      .map((e) => e.id)
      .toSet()
      .where((id) => versions(id).length > 1)
      .toList();

  Future<void> initialize() async {
    for (final kind in DeskKind.values) {
      settings[kind] = DeskSettings.decode(
        await repository.preference('settings.${kind.name}'),
      );
    }
    await reload();
  }

  Future<void> attachNative() async {
    if (!Platform.isWindows) return;
    channel.setMethodCallHandler(_handle);
    _native = true;
    await publish();
  }

  Future<void> reload() async {
    entries = await repository.load();
    if (!_disposed) notifyListeners();
    await publish();
  }

  Future<void> updateSettings(DeskKind kind, Map<String, Object?> changes) =>
      _settingsGate.run(() async {
        final value = config(kind).change(changes);
        await repository.savePreference(
          'settings.${kind.name}',
          jsonEncode(value.toJson()),
        );
        settings[kind] = value;
        if (!_disposed) notifyListeners();
        await publish();
      });

  /// 保存一条便签/待办。时间与提醒为可空的整体覆盖：未传即清空，
  /// 编辑既有条目时调用方需回传原值（[toggle] 已按此处理）。
  Future<void> save(
    DeskKind kind, {
    String? id,
    String title = '',
    required String body,
    bool done = false,
    bool deleted = false,
    String? fontFamily,
    double? fontSize,
    int? textColor,
    int? startAt,
    int? endAt,
    int? remindAt,
    int? remindBeforeMinutes,
    Set<String>? expected,
  }) async {
    if (!enabled(kind)) throw StateError('${kind.label}功能未开启');
    await repository.save(
      kind,
      id: id,
      title: title,
      body: body,
      done: done,
      deleted: deleted,
      fontFamily: fontFamily,
      fontSize: fontSize,
      textColor: textColor,
      startAt: startAt,
      endAt: endAt,
      remindAt: remindAt,
      remindBeforeMinutes: remindBeforeMinutes,
      expected: expected,
    );
    await reload();
  }

  // 勾选完成只改变完成状态，其余字段（含时间与提醒）原样回写。
  Future<void> toggle(DeskEntry entry) => save(
    entry.kind,
    id: entry.id,
    title: entry.title,
    body: entry.body,
    done: !entry.done,
    fontFamily: entry.fontFamily,
    fontSize: entry.fontSize,
    textColor: entry.textColor,
    startAt: entry.startAt,
    endAt: entry.endAt,
    remindAt: entry.remindAt,
    remindBeforeMinutes: entry.remindBeforeMinutes,
    expected: {entry.revision},
  );
  // 删除会把时间与提醒一并回传；仓库对 deleted 版本统一清空字段，
  // 与标题、正文和文字样式的墓碑行为一致。
  Future<void> remove(DeskEntry entry) => save(
    entry.kind,
    id: entry.id,
    body: '',
    deleted: true,
    startAt: entry.startAt,
    endAt: entry.endAt,
    remindAt: entry.remindAt,
    remindBeforeMinutes: entry.remindBeforeMinutes,
    expected: {entry.revision},
  );

  Future<Map<String, dynamic>> draft(DeskKind kind) async {
    final value = await repository.preference('draft.${kind.name}');
    return value == null ? {} : Map<String, dynamic>.from(jsonDecode(value));
  }

  Future<void> storeDraft(
    DeskKind kind,
    String title,
    String body, {
    String? fontFamily,
    double? fontSize,
    int? textColor,
    int? startAt,
    int? endAt,
    int? remindAt,
    int? remindBeforeMinutes,
  }) => repository.savePreference(
    'draft.${kind.name}',
    jsonEncode({
      'title': title,
      'body': body,
      'fontFamily': ?fontFamily,
      'fontSize': ?fontSize,
      'textColor': ?textColor,
      'startAt': ?startAt,
      'endAt': ?endAt,
      'remindAt': ?remindAt,
      'remindBeforeMinutes': ?remindBeforeMinutes,
    }),
  );

  Future<void> compose(DeskKind kind, {bool hotkey = false}) async {
    if (!enabled(kind)) return;
    // 快速新增已改为 Flutter 页面，由桌面服务切换到浮层窗口模式。
    await openComposer?.call(kind, hotkey: hotkey);
  }

  bool get isNative => _native;

  /// 快速新增期间临时把对应桌面轨道置顶，结束后恢复到底层。
  Future<void> setRailRaised(DeskKind kind, bool raised) async {
    if (!_native) return;
    await channel.invokeMethod<void>('railActive', {
      'kind': kind.name,
      'raised': raised,
    });
  }

  Future<List<Map<String, dynamic>>> monitors() async =>
      (await channel.invokeListMethod<dynamic>('monitors') ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  Future<void> selectRegion(DeskKind kind) async {
    final result = await channel.invokeMapMethod<String, dynamic>(
      'selectRegion',
      {'kind': kind.name, 'monitor': config(kind).monitor},
    );
    if (result != null) await updateSettings(kind, result);
  }

  Future<void> suspend(bool value) async {
    if (_native) await channel.invokeMethod<void>('suspend', value);
  }

  Future<void> editing(bool value) async {
    if (_native) await channel.invokeMethod<void>('editing', value);
  }

  Future<bool> ignoresClipboard(int? sequence) async {
    if (sequence == null || !_native) return false;
    if (sequence == ignoredClipboardSequence) return true;
    return await channel.invokeMethod<bool>('ignoreClipboard', sequence) ??
        false;
  }

  Future<SyncResult> synchronize(Directory root) async {
    // Keep the reported scope consistent if settings change during I/O.
    final states = {for (final kind in DeskKind.values) kind: syncState(kind)};
    final imported = <DeskKind, int>{};
    final exported = <DeskKind, int>{};
    for (final kind in DeskKind.values) {
      if (states[kind] == SyncModuleState.participating) {
        imported[kind] = await repository.synchronize(root, {
          kind,
        }, onExported: (count) => exported[kind] = count);
      }
    }
    if (imported.isNotEmpty) await reload();
    SyncModuleResult resultFor(DeskKind kind) => SyncModuleResult(
      state: states[kind]!,
      imported: imported[kind] ?? 0,
      exported: exported[kind] ?? 0,
    );
    final notes = resultFor(DeskKind.note);
    final todos = resultFor(DeskKind.todo);
    return SyncResult(
      imported: notes.imported + todos.imported,
      exported: notes.exported + todos.exported,
      notes: notes,
      todos: todos,
    );
  }

  Future<int> importLegacy(Directory root) async {
    final imported = await repository.importLegacy(root);
    if (imported > 0) await reload();
    return imported;
  }

  Future<void> publish() async {
    _revision++;
    if (!_native || _disposed) return;
    if (_publishing != null) return _publishing;
    _publishing = _publishLoop();
    try {
      await _publishing;
    } finally {
      _publishing = null;
    }
  }

  Future<void> _publishLoop() async {
    int sent;
    do {
      sent = _revision;
      try {
        final result = await channel.invokeMethod<String>('configure', {
          for (final kind in DeskKind.values)
            kind.name: {
              ...config(kind).toJson(),
              'doneCount': kind == DeskKind.todo
                  ? items(kind).where((e) => e.done).length
                  : 0,
              'rows': items(kind)
                  .where((e) => !e.done || kind == DeskKind.note)
                  .map(
                    (e) => {
                      ...e.toJson(),
                      'conflict': versions(e.id).length > 1,
                    },
                  )
                  .toList(),
            },
        });
        if (error != result) {
          error = result;
          if (!_disposed) notifyListeners();
        }
      } catch (e) {
        error = '桌面列表更新失败：$e';
        if (!_disposed) notifyListeners();
      }
    } while (sent != _revision && !_disposed);
  }

  Future<Object?> _handle(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'suppressClipboard') {
      ignoredClipboardSequence = call.arguments as int;
      return null;
    }
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final kind = DeskKind.values.byName(args['kind'] as String? ?? 'note');
    switch (call.method) {
      case 'hotkey':
        await compose(kind, hotkey: true);
      case 'save':
        await save(
          kind,
          title: args['title'] as String? ?? '',
          body: args['body'] as String? ?? '',
          fontFamily: args['fontFamily'] as String?,
          fontSize: (args['fontSize'] as num?)?.toDouble(),
          textColor: args['textColor'] as int?,
          startAt: _channelStamp(args['startAt']),
          endAt: _channelStamp(args['endAt']),
          remindAt: _channelStamp(args['remindAt']),
          remindBeforeMinutes: _channelMinutes(args['remindBeforeMinutes']),
        );
        await storeDraft(kind, '', '');
      case 'draft':
        await storeDraft(
          kind,
          args['title'] as String? ?? '',
          args['body'] as String? ?? '',
          fontFamily: args['fontFamily'] as String?,
          fontSize: (args['fontSize'] as num?)?.toDouble(),
          textColor: args['textColor'] as int?,
          startAt: _channelStamp(args['startAt']),
          endAt: _channelStamp(args['endAt']),
          remindAt: _channelStamp(args['remindAt']),
          remindBeforeMinutes: _channelMinutes(args['remindBeforeMinutes']),
        );
      case 'cancel':
        await storeDraft(kind, '', '');
      case 'toggle':
        final id = args['id'] as String;
        final values = versions(id);
        if (enabled(kind) &&
            values.length == 1 &&
            !values.single.deleted &&
            !values.single.done) {
          await toggle(values.single);
        }
      case 'view':
        if (enabled(kind)) {
          await openManager?.call(kind, args['id'] as String? ?? '');
        }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_native) {
      channel.setMethodCallHandler(null);
      channel.invokeMethod<void>('shutdown');
    }
    super.dispose();
  }
}

/// 原生通道可能来自旧版窗口或未来版本：只接收合法的毫秒时间戳与分钟数，
/// 其余视为未设置，避免脏数据进入草稿或仓库。
int? _channelStamp(Object? value) =>
    value is int && validDeskTimestamp(value) ? value : null;

int? _channelMinutes(Object? value) =>
    value is int && value >= 1 && value <= deskRemindBeforeMinutesMax
    ? value
    : null;
