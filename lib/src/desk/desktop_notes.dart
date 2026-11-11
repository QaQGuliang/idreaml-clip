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
  Future<void>? _publishing;
  int _revision = 0;
  final _settingsGate = AsyncGate();

  DeskSettings config(DeskKind kind) => settings[kind] ?? const DeskSettings();
  bool enabled(DeskKind kind) => config(kind).enabled;
  List<DeskEntry> versions(String id) =>
      entries.where((e) => e.id == id).toList();
  List<DeskEntry> items(DeskKind kind) {
    final ids = <String>{};
    final sorted = entries.where((e) => e.kind == kind && !e.deleted).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    return sorted.where((e) => ids.add(e.id)).toList();
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
      expected: expected,
    );
    await reload();
  }

  Future<void> toggle(DeskEntry entry) => save(
    entry.kind,
    id: entry.id,
    title: entry.title,
    body: entry.body,
    done: !entry.done,
    fontFamily: entry.fontFamily,
    fontSize: entry.fontSize,
    textColor: entry.textColor,
    expected: {entry.revision},
  );
  Future<void> remove(DeskEntry entry) => save(
    entry.kind,
    id: entry.id,
    body: '',
    deleted: true,
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
  }) => repository.savePreference(
    'draft.${kind.name}',
    jsonEncode({
      'title': title,
      'body': body,
      'fontFamily': ?fontFamily,
      'fontSize': ?fontSize,
      'textColor': ?textColor,
    }),
  );

  Future<void> compose(DeskKind kind, {bool hotkey = false}) async {
    if (!enabled(kind) || !_native) return;
    await channel.invokeMethod<void>('compose', {
      'kind': kind.name,
      'hotkey': hotkey,
      ...await draft(kind),
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
    final kinds = DeskKind.values
        .where((kind) => enabled(kind) && config(kind).sync)
        .toSet();
    if (kinds.isEmpty) return const SyncResult(imported: 0, exported: 0);
    final result = await repository.synchronize(root, kinds);
    await reload();
    return SyncResult(
      imported: result,
      exported: entries.where((e) => kinds.contains(e.kind)).length,
    );
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
