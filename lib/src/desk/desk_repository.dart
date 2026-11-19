import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../data/data_storage.dart';
import '../services/async_gate.dart';
import '../services/sync_archive.dart';
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

  static String _folder(DeskKind kind) =>
      kind == DeskKind.note ? 'notes' : 'todos';

  Future<int> importLegacy(Directory root) async {
    final archive = SyncArchive(root);
    final entries = <DeskEntry>[];
    for (final kind in DeskKind.values) {
      for (final file in await archive.jsonFiles('desktop-v1/${kind.name}')) {
        final data = await archive.readJson(file, limit: maxSyncFileBytes);
        if (data['version'] != 1 ||
            data['kind'] != kind.name ||
            data['entries'] is! List) {
          throw const FormatException('不支持的旧便签或待办同步格式');
        }
        for (final raw in data['entries'] as List) {
          final entry = DeskEntry.fromJson(
            Map<String, dynamic>.from(raw as Map),
          );
          if (entry.kind != kind) throw const FormatException('同步模块类型不一致');
          entries.add(entry);
        }
      }
    }
    return merge(entries);
  }

  Future<int> synchronize(
    Directory root,
    Set<DeskKind> kinds, {
    void Function(int)? onExported,
  }) async {
    final archive = SyncArchive(root);
    var changed = 0;
    var exported = 0;
    for (final kind in kinds) {
      final folder = _folder(kind);
      final metaFolder = 'config/metadata/$folder';
      final incoming = <DeskEntry>[];
      final previousBodies = <String>{};
      final previousMetadata = <String>{};
      for (final file in await archive.jsonFiles(metaFolder)) {
        final json = await archive.readJson(file, limit: maxSyncFileBytes);
        final revision = json['revision'] as String;
        final id = json['id'] as String;
        final key = _entryKey(id, revision);
        if (json['schema_version'] != SyncArchive.version ||
            json['kind'] != kind.name ||
            p.basename(file.path) != '$key.json') {
          throw const FormatException('便签或待办同步元数据无效');
        }
        final deleted = json['deleted'] == true;
        final bodyPath = '$folder/$key.md';
        final body = deleted
            ? ''
            : await _readBody(archive, bodyPath, json, kind);
        incoming.add(DeskEntry.fromJson({...json, 'body': body}));
        if (!deleted) previousBodies.add(bodyPath);
        previousMetadata.add('$metaFolder/$key.json');
      }
      changed += await merge(incoming);
      final entries = (await load()).where((entry) => entry.kind == kind);
      for (final entry in entries) {
        final key = _entryKey(entry.id, entry.revision);
        final json = entry.toJson()..remove('body');
        json['schema_version'] = SyncArchive.version;
        if (!entry.deleted) {
          final bodyPath = '$folder/$key.md';
          final markdown =
              '${_bodyPrefix(kind, entry.title, entry.done)}${entry.body}';
          if (utf8.encode(markdown).length > maxSyncFileBytes) {
            throw const FormatException('单条便签或待办超过同步大小限制');
          }
          await archive.writeText(bodyPath, markdown);
          previousBodies.remove(bodyPath);
        }
        final metaPath = '$metaFolder/$key.json';
        await archive.writeJson(metaPath, json);
        previousMetadata.remove(metaPath);
        exported++;
      }
      for (final obsolete in [...previousBodies, ...previousMetadata]) {
        await archive.remove(obsolete);
      }
    }
    onExported?.call(exported);
    return changed;
  }

  // Revision suffixes keep both readable versions available until a user
  // resolves concurrent edits. Obsolete revisions are removed from the tip.
  static String _entryKey(String id, String revision) {
    final safe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    if (!safe.hasMatch(id) || !safe.hasMatch(revision)) {
      throw const FormatException('便签或待办同步标识无效');
    }
    return '${sha256.convert(utf8.encode(id))}-$revision';
  }

  static String _bodyPrefix(DeskKind kind, String title, bool done) =>
      kind == DeskKind.todo
      ? '- [${done ? 'x' : ' '}] '
      : title.isEmpty
      ? ''
      : '# $title\n\n';

  Future<String> _readBody(
    SyncArchive archive,
    String path,
    Map<String, dynamic> json,
    DeskKind kind,
  ) async {
    final file = await archive.file(path);
    if (!await file.exists() || await file.length() > maxSyncFileBytes) {
      throw const FormatException('便签或待办正文缺失或超过大小限制');
    }
    final text = await file.readAsString();
    final prefix = _bodyPrefix(
      kind,
      json['title'] as String,
      json['done'] == true,
    );
    if (!text.startsWith(prefix)) throw const FormatException('便签或待办正文格式无效');
    return text.substring(prefix.length);
  }
}
