import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../data/data_storage.dart';
import '../services/async_gate.dart';
import 'desk_models.dart';

class DeskRepository {
  DeskRepository({
    required this.deviceId,
    this.storage,
    this.testPath,
    this.maxSyncFileBytes = 32 * 1024 * 1024,
    DatabaseFactory? factory,
  }) : _factory = factory ?? databaseFactoryFfi;
  final String deviceId;
  final DataStorage? storage;
  final String? testPath;
  final int maxSyncFileBytes;
  final DatabaseFactory _factory;
  final _gate = AsyncGate();

  Future<T> _access<T>(Future<T> Function(Database) action) {
    Future<T> run() => _gate.run(() async {
      final path =
          testPath ?? p.join(storage!.root.path, 'database', 'desktop.db');
      final db = await _factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE revision (revision TEXT PRIMARY KEY, item TEXT NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE INDEX revision_item ON revision(item, kind)',
            );
            await db.execute(
              'CREATE TABLE preference (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
            );
          },
        ),
      );
      try {
        return await action(db);
      } finally {
        await db.close();
      }
    });
    // Every operation releases its SQLite handle before storage relocation.
    return storage?.access.run(run) ?? run();
  }

  Future<List<DeskEntry>> load() => _access(
    (db) async =>
        (await db.query('revision'))
            .map((r) => DeskEntry.fromJson(jsonDecode(r['data'] as String)))
            .toList(),
  );

  Future<String?> preference(String key) => _access((db) async {
    final rows = await db.query(
      'preference',
      where: 'key = ?',
      whereArgs: [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  });
  Future<void> savePreference(String key, String value) => _access((db) async {
    await db.insert('preference', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<DeskEntry> save(
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
  }) => _access(
    (db) => db.transaction((tx) async {
      if (title.length > 200 ||
          body.length > 20000 ||
          (!deleted && body.trim().isEmpty)) {
        throw const FormatException('请填写内容，标题最多 200 字，正文最多 20000 字');
      }
      if (!validDeskFontFamily(fontFamily) ||
          !validDeskFontSize(fontSize) ||
          !validDeskTextColor(textColor)) {
        throw const FormatException('文字样式无效：字号须为 10–32，颜色须为不透明颜色');
      }
      final itemId = id ?? const Uuid().v4();
      final previous =
          (await tx.query(
                'revision',
                where: 'item = ? AND kind = ?',
                whereArgs: [itemId, kind.name],
              ))
              .map((r) => DeskEntry.fromJson(jsonDecode(r['data'] as String)))
              .toList();
      final current = previous.map((e) => e.revision).toSet();
      if (expected != null &&
          (expected.length != current.length ||
              !expected.containsAll(current))) {
        throw StateError('内容已在其他设备或窗口更新，请重新打开后修改');
      }
      if (previous.length > 1 && expected == null) {
        throw StateError('请先在管理页处理此条内容的同步冲突');
      }
      final clock = <String, int>{};
      for (final entry in previous) {
        for (final e in entry.clock.entries) {
          if (e.value > (clock[e.key] ?? 0)) clock[e.key] = e.value;
        }
      }
      clock[deviceId] = (clock[deviceId] ?? 0) + 1;
      final now = DateTime.now().millisecondsSinceEpoch;
      final value = DeskEntry(
        id: itemId,
        revision: const Uuid().v4(),
        kind: kind,
        title: deleted ? '' : title,
        body: deleted ? '' : body,
        done: done,
        deleted: deleted,
        fontFamily: deleted || fontFamily?.trim().isEmpty != false
            ? null
            : fontFamily!.trim(),
        fontSize: deleted ? null : fontSize,
        textColor: deleted ? null : textColor,
        created: previous.isEmpty ? now : previous.first.created,
        updated: now,
        clock: clock,
      );
      await tx.delete(
        'revision',
        where: 'item = ? AND kind = ?',
        whereArgs: [itemId, kind.name],
      );
      await _insert(tx, value);
      return value;
    }),
  );

  Future<void> _insert(DatabaseExecutor db, DeskEntry entry) async =>
      db.insert('revision', {
        'revision': entry.revision,
        'item': entry.id,
        'kind': entry.kind.name,
        'data': jsonEncode(entry.toJson()),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<int> merge(List<DeskEntry> incoming) => _access(
    (db) => db.transaction((tx) async {
      var changes = 0;
      for (final entry in incoming) {
        final rows = await tx.query(
          'revision',
          where: 'item = ? AND kind = ?',
          whereArgs: [entry.id, entry.kind.name],
        );
        final local = rows
            .map((r) => DeskEntry.fromJson(jsonDecode(r['data'] as String)))
            .toList();
        if (local.any(
          (e) => e.revision == entry.revision || e.supersedes(entry),
        )) {
          continue;
        }
        for (final obsolete in local.where(entry.supersedes)) {
          await tx.delete(
            'revision',
            where: 'revision = ?',
            whereArgs: [obsolete.revision],
          );
        }
        await _insert(tx, entry);
        changes++;
      }
      return changes;
    }),
  );

  Future<int> synchronize(Directory root, Set<DeskKind> kinds) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(deviceId)) {
      throw const FormatException('同步设备标识无效');
    }
    var changed = 0;
    for (final kind in kinds) {
      final folder = Directory(p.join(root.path, 'desktop-v1', kind.name));
      final incoming = <DeskEntry>[];
      if (await folder.exists()) {
        await for (final entity in folder.list(followLinks: false)) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          if (await entity.length() > maxSyncFileBytes) {
            throw const FormatException('便签/待办同步文件超过大小限制');
          }
          final data =
              jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          if (data['version'] != 1 ||
              data['kind'] != kind.name ||
              data['entries'] is! List) {
            throw const FormatException('不支持的便签/待办同步格式');
          }
          for (final raw in data['entries'] as List) {
            final entry = DeskEntry.fromJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (entry.kind != kind) throw const FormatException('同步模块类型不一致');
            incoming.add(entry);
          }
        }
      }
      changed += await merge(incoming);
      final entries = (await load()).where((e) => e.kind == kind).toList()
        ..sort((a, b) => a.revision.compareTo(b.revision));
      await folder.create(recursive: true);
      // Only this device's snapshot is replaced. Other modules and clients'
      // files are never cleaned up. Tombstones remain in snapshots indefinitely.
      final prefix = '{"version":1,"kind":"${kind.name}","entries":[';
      final expected = <String>{};
      var part = 0;
      var rows = <String>[];
      var bytes = utf8.encode(prefix).length + 2;
      Future<void> flush() async {
        final name = part == 0 ? '$deviceId.json' : '$deviceId.$part.json';
        expected.add(name);
        final file = File(p.join(folder.path, name));
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          '$prefix${rows.join(',')}]}',
          flush: true,
        );
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
        part++;
        rows = [];
        bytes = utf8.encode(prefix).length + 2;
      }

      for (final entry in entries) {
        final row = jsonEncode(entry.toJson());
        final length = utf8.encode(row).length;
        if (length + utf8.encode(prefix).length + 2 > maxSyncFileBytes) {
          throw const FormatException('单条便签/待办同步数据过大');
        }
        if (rows.isNotEmpty && bytes + length + 1 > maxSyncFileBytes) {
          await flush();
        }
        bytes += length + (rows.isEmpty ? 0 : 1);
        rows.add(row);
      }
      if (rows.isNotEmpty || part == 0) await flush();
      await for (final file in folder.list(followLinks: false)) {
        if (file is! File) continue;
        final name = p.basename(file.path);
        final parts = name.split('.');
        final own =
            name == '$deviceId.json' ||
            (parts.length == 3 &&
                parts[0] == deviceId &&
                int.tryParse(parts[1]) != null &&
                parts[2] == 'json');
        if (own && !expected.contains(name)) await file.delete();
      }
    }
    return changed;
  }
}
