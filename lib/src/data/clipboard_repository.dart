import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/clipboard_item.dart';
import '../models/sync_models.dart';
import 'clipboard_database.dart';

class ClipboardStats {
  const ClipboardStats({required this.history, required this.favorites});

  final int history;
  final int favorites;
}

class ClipboardRepository {
  ClipboardRepository(this._database) : _uuid = const Uuid();

  final ClipboardDatabase _database;
  final Uuid _uuid;
  String? _deviceId;

  Database get _db => _database.database;

  String get deviceId {
    final value = _deviceId;
    if (value == null) throw StateError('Device has not been initialized.');
    return value;
  }

  String get deviceName =>
      Platform.environment['COMPUTERNAME'] ??
      Platform.environment['HOSTNAME'] ??
      '本机';

  Future<String> initializeDevice() async {
    final savedId = await getSetting('device_id');
    final deviceId = savedId ?? _uuid.v4();
    if (savedId == null) await setSetting('device_id', deviceId);
    _deviceId = deviceId;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insert('device', {
      'id': deviceId,
      'name': deviceName,
      'platform': Platform.operatingSystem,
      'created_at': now,
      'last_seen_at': now,
      'is_current': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return deviceId;
  }

  Future<ClipboardItem?> captureText(String content) async {
    if (content.trim().isEmpty) return null;
    final deviceId = _deviceId ?? await initializeDevice();
    final hash = sha256.convert(utf8.encode(content)).toString();
    final now = DateTime.now().millisecondsSinceEpoch;

    return _db.transaction((txn) async {
      final existing = await txn.query(
        'clipboard_item',
        where: 'content_hash = ?',
        whereArgs: [hash],
        limit: 1,
      );
      if (existing.isEmpty) {
        final id = _uuid.v4();
        await txn.insert('clipboard_item', {
          'id': id,
          'type': 'text',
          'content': content,
          'content_hash': hash,
          'created_at': now,
          'updated_at': now,
          'last_used_at': now,
          'copy_count': 1,
          'favorite': 0,
          'deleted': 0,
          'device_id': deviceId,
          'sync_state': 'dirty',
          'source_app': null,
        });
        final rows = await txn.query(
          'clipboard_item',
          where: 'id = ?',
          whereArgs: [id],
        );
        return ClipboardItem.fromMap(rows.single);
      }

      final id = existing.single['id']! as String;
      await txn.rawUpdate(
        '''
        UPDATE clipboard_item
        SET content = ?, updated_at = ?, last_used_at = ?,
            copy_count = copy_count + 1, deleted = 0, sync_state = 'dirty'
        WHERE id = ?
      ''',
        [content, now, now, id],
      );
      final rows = await txn.query(
        'clipboard_item',
        where: 'id = ?',
        whereArgs: [id],
      );
      return ClipboardItem.fromMap(rows.single);
    });
  }

  Future<List<ClipboardItem>> list({
    String query = '',
    bool favoritesOnly = false,
    bool todayOnly = false,
    int? limit,
  }) async {
    final where = <String>['deleted = 0'];
    final args = <Object?>[];
    if (query.trim().isNotEmpty) {
      where.add('instr(lower(content), lower(?)) > 0');
      args.add(query.trim());
    }
    if (favoritesOnly) where.add('favorite = 1');
    if (todayOnly) {
      final now = DateTime.now();
      final start = DateTime(
        now.year,
        now.month,
        now.day,
      ).millisecondsSinceEpoch;
      where.add('last_used_at >= ?');
      args.add(start);
    }
    final rows = await _db.query(
      'clipboard_item',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'last_used_at DESC',
      limit: limit,
    );
    return rows.map(ClipboardItem.fromMap).toList(growable: false);
  }

  Future<void> toggleFavorite(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET favorite = CASE favorite WHEN 1 THEN 0 ELSE 1 END,
          updated_at = ?, sync_state = 'dirty'
      WHERE id = ? AND deleted = 0
    ''',
      [now, id],
    );
  }

  Future<void> markUsed(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET last_used_at = ?, updated_at = ?, copy_count = copy_count + 1,
          sync_state = 'dirty'
      WHERE id = ? AND deleted = 0
    ''',
      [now, now, id],
    );
  }

  Future<void> softDelete(String id) async {
    await _db.update(
      'clipboard_item',
      {
        'deleted': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_state': 'dirty',
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> clearHistory() async {
    await _db.update('clipboard_item', {
      'deleted': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
      'sync_state': 'dirty',
    }, where: 'deleted = 0');
  }

  Future<void> enforceHistoryLimit(int limit) async {
    if (limit <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET deleted = 1, updated_at = ?, sync_state = 'dirty'
      WHERE id IN (
        SELECT id FROM clipboard_item
        WHERE deleted = 0 AND favorite = 0
        ORDER BY last_used_at DESC
        LIMIT -1 OFFSET ?
      )
    ''',
      [now, limit],
    );
  }

  Future<void> cleanupOlderThan(int days) async {
    if (days <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    await _db.update(
      'clipboard_item',
      {
        'deleted': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'sync_state': 'dirty',
      },
      where: 'deleted = 0 AND favorite = 0 AND last_used_at < ?',
      whereArgs: [cutoff],
    );
  }

  Future<ClipboardStats> stats() async {
    final historyRows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM clipboard_item WHERE deleted = 0',
    );
    final favoriteRows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM clipboard_item '
      'WHERE deleted = 0 AND favorite = 1',
    );
    final history = historyRows.single['total']! as int;
    final favorites = favoriteRows.single['total']! as int;
    return ClipboardStats(history: history, favorites: favorites);
  }

  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      'app_setting',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('app_setting', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ClipboardItem>> listForSync() async {
    final rows = await _db.query('clipboard_item', orderBy: 'created_at ASC');
    return rows.map(ClipboardItem.fromMap).toList(growable: false);
  }

  Future<int> mergeSyncData({
    required List<SyncRecord> records,
    required List<SyncTombstone> tombstones,
    List<SyncDevice> devices = const [],
  }) async {
    var changes = 0;
    await _db.transaction((txn) async {
      for (final device in devices) {
        final current = device.id == _deviceId;
        await txn.insert('device', {
          'id': device.id,
          'name': device.name,
          'platform': device.platform,
          'created_at': device.lastSeenAt,
          'last_seen_at': device.lastSeenAt,
          'is_current': current ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final remote in records) {
        final rows = await txn.query(
          'clipboard_item',
          where: 'content_hash = ?',
          whereArgs: [remote.contentHash],
          limit: 1,
        );
        if (rows.isEmpty) {
          await txn.insert('clipboard_item', {
            'id': remote.id,
            'type': remote.type,
            'content': remote.content,
            'content_hash': remote.contentHash,
            'created_at': remote.createdAt,
            'updated_at': remote.updatedAt,
            'last_used_at': remote.lastUsedAt,
            'copy_count': remote.copyCount,
            'favorite': remote.favorite ? 1 : 0,
            'deleted': remote.deleted ? 1 : 0,
            'device_id': remote.deviceId,
            'sync_state': 'clean',
            'source_app': remote.sourceApp,
          });
          changes++;
          continue;
        }

        final local = ClipboardItem.fromMap(rows.single);
        if (remote.updatedAt <= local.updatedAt.millisecondsSinceEpoch) {
          continue;
        }
        await txn.update(
          'clipboard_item',
          {
            'type': remote.type,
            'content': remote.content,
            'created_at':
                remote.createdAt < local.createdAt.millisecondsSinceEpoch
                ? remote.createdAt
                : local.createdAt.millisecondsSinceEpoch,
            'updated_at': remote.updatedAt,
            'last_used_at':
                remote.lastUsedAt > local.lastUsedAt.millisecondsSinceEpoch
                ? remote.lastUsedAt
                : local.lastUsedAt.millisecondsSinceEpoch,
            'copy_count': remote.copyCount > local.copyCount
                ? remote.copyCount
                : local.copyCount,
            'favorite': remote.favorite ? 1 : 0,
            'deleted': remote.deleted ? 1 : 0,
            'device_id': remote.deviceId,
            'sync_state': 'clean',
            'source_app': remote.sourceApp,
          },
          where: 'id = ?',
          whereArgs: [local.id],
        );
        changes++;
      }

      for (final tombstone in tombstones) {
        final rows = await txn.query(
          'clipboard_item',
          where: 'id = ? OR content_hash = ?',
          whereArgs: [tombstone.id, tombstone.contentHash],
          limit: 1,
        );
        if (rows.isEmpty) continue;
        final local = ClipboardItem.fromMap(rows.single);
        if (!local.deleted &&
            tombstone.deletedAt >= local.updatedAt.millisecondsSinceEpoch) {
          await txn.update(
            'clipboard_item',
            {
              'deleted': 1,
              'updated_at': tombstone.deletedAt,
              'sync_state': 'clean',
            },
            where: 'id = ?',
            whereArgs: [local.id],
          );
          changes++;
        }
      }
    });
    return changes;
  }

  Future<void> markAllSynced() async {
    await _db.update('clipboard_item', {
      'sync_state': 'clean',
    }, where: "sync_state != 'clean'");
  }

  Future<List<DeviceInfo>> listDevices() async {
    final rows = await _db.query(
      'device',
      orderBy: 'is_current DESC, last_seen_at DESC',
    );
    return rows
        .map(
          (row) => DeviceInfo(
            id: row['id']! as String,
            name: row['name']! as String,
            platform: row['platform']! as String,
            lastSeenAt: DateTime.fromMillisecondsSinceEpoch(
              row['last_seen_at']! as int,
            ),
            isCurrent: (row['is_current']! as int) == 1,
          ),
        )
        .toList(growable: false);
  }
}
