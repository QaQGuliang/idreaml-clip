import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ClipboardDatabase {
  ClipboardDatabase();

  ClipboardDatabase.withFactory(this._factory);

  DatabaseFactory? _factory;
  Database? _database;

  Database get database {
    final value = _database;
    if (value == null) throw StateError('Database has not been opened.');
    return value;
  }

  Future<void> open({String? path}) async {
    sqfliteFfiInit();
    _factory ??= databaseFactoryFfi;
    final databasePath = path ?? await _defaultPath();
    _database = await _factory!.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA journal_mode = WAL');
        },
        onCreate: _createSchema,
      ),
    );
  }

  Future<String> _defaultPath() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}idreaml_clip${Platform.pathSeparator}database',
    );
    await directory.create(recursive: true);
    return '${directory.path}${Platform.pathSeparator}clipboard.db';
  }

  Future<void> _createSchema(Database db, int version) async {
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

  Future<void> close() async => _database?.close();
}
