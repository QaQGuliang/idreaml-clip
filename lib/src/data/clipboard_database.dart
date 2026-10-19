import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/clipboard_content.dart';
import 'data_storage.dart';
import 'image_store.dart';

class ClipboardDatabase {
  ClipboardDatabase({this.storage});

  ClipboardDatabase.withFactory(this._factory, {this.storage});

  DataStorage? storage;
  DatabaseFactory? _factory;
  Database? _database;
  Database? _settings;
  Database get settings => _settings ?? database;
  ImageStore? get images => storage == null ? null : ImageStore(storage!);

  Future<T> access<T>(Future<T> Function() action) =>
      storage?.access.run(action) ?? action();

  Database get database {
    final value = _database;
    if (value == null) throw StateError('Database has not been opened.');
    return value;
  }

  Future<void> open({String? path}) async {
    sqfliteFfiInit();
    _factory ??= databaseFactoryFfi;
    if (path == null && storage == null) {
      storage = DataStorage();
      await storage!.initialize();
    }
    final databasePath = path ?? storage!.databasePath;
    _database = await _factory!.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA journal_mode = WAL');
        },
        onCreate: _createSchema,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) await _createScreenshotReceipts(db);
        },
      ),
    );
    if (storage != null) {
      try {
        _settings = await _factory!.openDatabase(
          storage!.settingsPath,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => db.execute('''
              CREATE TABLE app_setting (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL
              )
            '''),
          ),
        );
        for (final db in [database, settings]) {
          final check = await db.rawQuery('PRAGMA quick_check');
          if (check.length != 1 || check.single.values.single != 'ok') {
            throw const StorageException('数据库校验失败，原数据已保留。');
          }
        }
        await _separateLegacyData();
      } catch (_) {
        await close();
        rethrow;
      }
    }
  }

  Future<StorageMoveResult> moveTo(String path) {
    final current = storage;
    if (current == null) throw StateError('No managed storage');
    return current.moveTo(path, close: close, open: () => open());
  }

  Future<void> _separateLegacyData() async {
    final legacySettings = await database.query('app_setting');
    await settings.transaction((txn) async {
      for (final row in legacySettings) {
        await txn.insert(
          'app_setting',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
    await database.delete('app_setting');
    // Flush each image before replacing its inline contents with a relative
    // reference. An interrupted upgrade is safe to resume on the next launch.
    final rows = await database.query(
      'clipboard_item',
      where: "type LIKE 'image/%' AND content NOT LIKE ?",
      whereArgs: ['${ImageStore.prefix}%'],
    );
    for (final row in rows) {
      final value = await images!.persist(
        ClipboardContent(
          type: row['type'] as String,
          content: row['content'] as String,
        ),
      );
      await database.update(
        'clipboard_item',
        {'content': value},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  Future<void> _createSchema(Database db, int version) async {
    await _createScreenshotReceipts(db);
    await db.execute('''
      CREATE TABLE clipboard_item (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL DEFAULT 'text',
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        last_used_at INTEGER NOT NULL,
        copy_count INTEGER NOT NULL DEFAULT 1,
        favorite INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        device_id TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'dirty',
        source_app TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX clipboard_item_visible_idx '
      'ON clipboard_item(deleted, last_used_at DESC)',
    );
    await db.execute(
      'CREATE INDEX clipboard_item_favorite_idx '
      'ON clipboard_item(favorite, deleted, last_used_at DESC)',
    );
    await db.execute('''
      CREATE TABLE app_setting (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE device (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        platform TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL,
        is_current INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  Future<void> close() async {
    await _settings?.close();
    _settings = null;
    await _database?.close();
    _database = null;
  }

  Future<void> _createScreenshotReceipts(Database db) => db.execute('''
    CREATE TABLE screenshot_commit (
      operation_id TEXT PRIMARY KEY,
      content_hash TEXT NOT NULL,
      item_id TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');
}
