import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/clipboard_item.dart';
import '../models/clipboard_content.dart';
import '../models/sync_models.dart';
import '../services/device_identity.dart';
import 'clipboard_database.dart';
import 'data_storage.dart';

class ClipboardStats {
  const ClipboardStats({required this.history, required this.favorites});

  final int history;
  final int favorites;
}

class ClipboardRepository {
  ClipboardRepository(this._database, {String? Function()? machineIdentity})
    : _uuid = const Uuid(),
      _machineIdentity = machineIdentity ?? readMachineId;

  final ClipboardDatabase _database;
  final Uuid _uuid;
  final String? Function() _machineIdentity;
  String? _deviceId;
  late final String? machineId = validMachineId(_machineIdentity());

  Database get _db => _database.database;
  DataStorage? get storage => _database.storage;
  Future<T> access<T>(Future<T> Function() action) => _database.access(action);
  Future<StorageMoveResult> moveStorage(String path) => _database.moveTo(path);

  Future<StorageMoveResult> adoptStorage(String path) =>
      _database.adoptTo(path);

  // The SQLite binding's UTF-8 decoder removes a leading BOM. Read those
  // values with a prefix so the original clipboard text survives a round trip.
  static const _contentColumns = [
    '*',
    "CASE WHEN type NOT LIKE 'image/%' AND substr(content, 1, 1) = char(65279) "
        "THEN ' ' || content END AS prefixed_content",
  ];

  static Map<String, Object?> _restoreText(Map<String, Object?> row) {
    final prefixed = row['prefixed_content'] as String?;
    return prefixed == null ? row : {...row, 'content': prefixed.substring(1)};
  }

  Future<ClipboardItem> _item(Map<String, Object?> row) async =>
      ClipboardItem.fromMap(
        _restoreText(await _database.images?.hydrate(row) ?? row),
      );

  Future<List<ClipboardItem>> _items(
    List<Map<String, Object?>> rows, {
    bool loadImages = true,
  }) async {
    if (!loadImages) {
      final images = _database.images;
      return rows
          .map((row) {
            final file = images?.fileFor(
              row['type'] as String,
              row['content'] as String,
            );
            return ClipboardItem.fromMap(
              _restoreText(row),
              imagePath: file?.path,
            );
          })
          .toList(growable: false);
    }
    final result = <ClipboardItem>[];
    // A large history must not open thousands of image files simultaneously.
    for (var offset = 0; offset < rows.length; offset += 16) {
      result.addAll(await Future.wait(rows.skip(offset).take(16).map(_item)));
    }
    return result;
  }

  String get deviceId {
    final value = _deviceId;
    if (value == null) throw StateError('Device has not been initialized.');
    return value;
  }

  String? get localDeviceId => _deviceId;

  String get deviceName =>
      Platform.environment['COMPUTERNAME'] ??
      Platform.environment['HOSTNAME'] ??
      '本机';

  Future<String> initializeDevice() => access(() async {
    final settings = await getSettings(['device_id', 'device_machine_id']);
    final savedId = settings['device_id'];
    final previousMachine = settings['device_machine_id'];
    final copied =
        previousMachine != null &&
        machineId != null &&
        previousMachine != machineId;
    final deviceId = copied ? _uuid.v4() : savedId ?? _uuid.v4();
    if (deviceId != savedId) await setSetting('device_id', deviceId);
    if (machineId != null && previousMachine != machineId) {
      await setSetting('device_machine_id', machineId!);
    }
    _deviceId = deviceId;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      await txn.update('device', {'is_current': 0}, where: 'is_current = 1');
      await _mergeDevice(
        txn,
        SyncDevice(
          id: deviceId,
          name: deviceName,
          platform: Platform.operatingSystem,
          lastSeenAt: now,
          machineId: machineId,
        ),
      );
    });
    return deviceId;
  });

  Future<ClipboardItem?> captureText(String content) =>
      capture(ClipboardContent.text(content));

  Future<ClipboardItem?> capture(ClipboardContent payload) => _capture(payload);

  Future<ClipboardItem?> captureScreenshot(
    String operationId,
    ClipboardContent payload,
  ) => _capture(payload, operationId: operationId);

  Future<void> releaseScreenshotReceipt(String operationId) => access(
    () => _db.delete(
      'screenshot_commit',
      where: 'operation_id = ?',
      whereArgs: [operationId],
    ),
  );

  Future<ClipboardItem?> _capture(
    ClipboardContent payload, {
    String? operationId,
  }) => access(() async {
    if (payload.content.trim().isEmpty) return null;
    final hash = payload.hash;
    final content =
        await _database.images?.persist(payload, hash: hash) ?? payload.content;
    final deviceId = _deviceId ?? await initializeDevice();
    final now = DateTime.now().millisecondsSinceEpoch;
    ClipboardItem captured(Map<String, Object?> row) =>
        ClipboardItem.fromMap({...row, 'content': payload.content});

    return _db.transaction((txn) async {
      if (operationId != null) {
        final receipts = await txn.query(
          'screenshot_commit',
          where: 'operation_id = ?',
          whereArgs: [operationId],
        );
        if (receipts.isNotEmpty) {
          if (receipts.single['content_hash'] != hash) {
            throw StateError('截图提交内容与已完成结果不一致');
          }
          final rows = await txn.query(
            'clipboard_item',
            where: 'id = ?',
            whereArgs: [receipts.single['item_id']],
          );
          return rows.isEmpty ? null : captured(rows.single);
        }
      }
      Future<void> receipt(String id) async {
        if (operationId == null) return;
        await txn.insert('screenshot_commit', {
          'operation_id': operationId,
          'content_hash': hash,
          'item_id': id,
          'created_at': now,
        });
      }

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
          'type': payload.type,
          'content': content,
          'content_hash': hash,
          'created_at': now,
          'updated_at': now,
          'last_used_at': now,
          'copy_count': 1,
          'favorite': 0,
          'deleted': 0,
          'history_changed_at': now,
          'device_id': deviceId,
          'sync_state': 'dirty',
          'source_app': null,
        });
        final rows = await txn.query(
          'clipboard_item',
          where: 'id = ?',
          whereArgs: [id],
        );
        await receipt(id);
        return captured(rows.single);
      }

      final id = existing.single['id']! as String;
      await txn.rawUpdate(
        '''
        UPDATE clipboard_item
        SET content = ?, type = ?, created_at = CASE WHEN created_at = 0
            THEN ? ELSE created_at END, updated_at = ?, last_used_at = ?,
            copy_count = copy_count + 1,
            history_changed_at = CASE WHEN deleted = 1
              THEN max(?, history_changed_at + 1) ELSE history_changed_at END,
            deleted = 0, sync_state = 'dirty'
        WHERE id = ?
      ''',
        [content, payload.type, now, now, now, now, id],
      );
      final rows = await txn.query(
        'clipboard_item',
        where: 'id = ?',
        whereArgs: [id],
      );
      await receipt(id);
      return captured(rows.single);
    });
  });

  static (List<String>, List<Object?>) _listFilter({
    bool favoritesOnly = false,
    bool todayOnly = false,
  }) {
    final where = <String>[favoritesOnly ? 'favorite = 1' : 'deleted = 0'];
    final args = <Object?>[];
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
    return (where, args);
  }

  static final _whitespace = RegExp(r'\s+');

  static bool _matchesQuery(ClipboardItem item, String query) {
    final lower = query.toLowerCase();
    if (item.isImage) {
      final typeQuery = lower == 'jpg' ? 'jpeg' : lower;
      return item.type.toLowerCase().contains(typeQuery) || query == '图片';
    }
    return item.content
        .replaceAll(_whitespace, ' ')
        .toLowerCase()
        .contains(lower);
  }

  Future<int> count({
    String query = '',
    bool favoritesOnly = false,
    bool todayOnly = false,
  }) => access(() async {
    final (where, args) = _listFilter(
      favoritesOnly: favoritesOnly,
      todayOnly: todayOnly,
    );
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS c FROM clipboard_item WHERE ${where.join(' AND ')}',
        args,
      );
      return (rows.first['c'] as int?) ?? 0;
    }
    final rows = await _db.query(
      'clipboard_item',
      columns: _contentColumns,
      where: where.join(' AND '),
      whereArgs: args,
    );
    return (await _items(
      rows,
      loadImages: false,
    )).where((item) => _matchesQuery(item, trimmed)).length;
  });

  Future<List<ClipboardItem>> list({
    String query = '',
    bool favoritesOnly = false,
    bool todayOnly = false,
    int? limit,
    int offset = 0,
    bool loadImages = true,
  }) => access(() async {
    final (where, args) = _listFilter(
      favoritesOnly: favoritesOnly,
      todayOnly: todayOnly,
    );
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      final rows = await _db.query(
        'clipboard_item',
        columns: _contentColumns,
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'last_used_at DESC, rowid ASC',
        limit: limit ?? (offset == 0 ? null : -1),
        offset: offset == 0 ? null : offset,
      );
      return _items(rows, loadImages: loadImages);
    }
    // Whitespace-normalized matching cannot run in SQL; filter in Dart so
    // phrases spanning line breaks still match, then paginate the result.
    final rows = await _db.query(
      'clipboard_item',
      columns: _contentColumns,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'last_used_at DESC, rowid ASC',
    );
    final matched = (await _items(
      rows,
      loadImages: loadImages,
    )).where((item) => _matchesQuery(item, trimmed)).toList();
    return matched.skip(offset).take(limit ?? matched.length).toList();
  });

  Future<ClipboardContent> readPayload(ClipboardItem item) => access(() async {
    if (item.imagePath == null) return item.payload;
    // Resolve against the current storage root, even if this row was selected
    // immediately before a storage move.
    final file = _database.images!.fileFor(item.type, item.content)!;
    return ClipboardContent.image(await file.readAsBytes(), item.type);
  });

  Future<void> toggleFavorite(String id) => access(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET favorite = CASE favorite WHEN 1 THEN 0 ELSE 1 END,
          favorite_changed_at = max(?, favorite_changed_at + 1),
          updated_at = ?, sync_state = 'dirty'
      WHERE id = ? AND (deleted = 0 OR favorite = 1)
    ''',
      [now, now, id],
    );
  });

  Future<void> markUsed(String id) => access(() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET last_used_at = ?, updated_at = ?, copy_count = copy_count + 1,
          sync_state = 'dirty'
      WHERE id = ? AND (deleted = 0 OR favorite = 1)
    ''',
      [now, now, id],
    );
  });

  Future<void> softDelete(String id) =>
      _deleteHistory('deleted = 0 AND id = ?', [id]);

  Future<void> clearHistory() => _deleteHistory('deleted = 0');

  Future<void> _deleteHistory(String where, [List<Object?> args = const []]) =>
      access(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        await _db.rawUpdate(
          'UPDATE clipboard_item SET deleted = 1, updated_at = ?, '
          "history_changed_at = max(?, history_changed_at + 1), sync_state = 'dirty' "
          'WHERE $where',
          [now, now, ...args],
        );
      });

  Future<void> enforceHistoryLimit(int limit) => access(() async {
    if (limit <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawUpdate(
      '''
      UPDATE clipboard_item
      SET deleted = 1, updated_at = ?,
          history_changed_at = max(?, history_changed_at + 1), sync_state = 'dirty'
      WHERE id IN (
        SELECT id FROM clipboard_item
        WHERE deleted = 0 AND favorite = 0
        ORDER BY last_used_at DESC
        LIMIT -1 OFFSET ?
      )
    ''',
      [now, now, limit],
    );
  });

  Future<void> cleanupOlderThan(int days) async {
    if (days <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    await _deleteHistory('deleted = 0 AND favorite = 0 AND last_used_at < ?', [
      cutoff,
    ]);
  }

  Future<ClipboardStats> stats() => access(() async {
    final historyRows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM clipboard_item WHERE deleted = 0',
    );
    final favoriteRows = await _db.rawQuery(
      'SELECT COUNT(*) AS total FROM clipboard_item '
      'WHERE favorite = 1',
    );
    final history = historyRows.single['total']! as int;
    final favorites = favoriteRows.single['total']! as int;
    return ClipboardStats(history: history, favorites: favorites);
  });

  Future<String?> getSetting(String key) => access(() async {
    final rows = await _database.settings.query(
      'app_setting',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  });

  Future<Map<String, String>> getSettings(List<String> keys) =>
      access(() async {
        final rows = await _database.settings.query(
          'app_setting',
          columns: ['key', 'value'],
          where: 'key IN (${List.filled(keys.length, '?').join(',')})',
          whereArgs: keys,
        );
        return {
          for (final row in rows) row['key'] as String: row['value'] as String,
        };
      });

  Future<void> setSetting(String key, String value) => access(() async {
    await _database.settings.insert('app_setting', {
      'key': key,
      'value': value,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<List<SyncHistoryEntry>> updateSyncHistory({
    required DateTime cutoff,
    SyncHistoryEntry? entry,
  }) => access(() async {
    final rows = await _database.settings.transaction((txn) async {
      if (entry != null) {
        await txn.insert('sync_history', {
          'completed_at': entry.completedAt.millisecondsSinceEpoch,
          'trigger': entry.trigger.name,
          'succeeded': entry.succeeded ? 1 : 0,
          'details': entry.details,
        });
      }
      await txn.delete(
        'sync_history',
        where: 'completed_at <= ?',
        whereArgs: [cutoff.millisecondsSinceEpoch],
      );
      return txn.query('sync_history', orderBy: 'completed_at DESC, id DESC');
    });
    return [
      for (final row in rows)
        SyncHistoryEntry(
          completedAt: DateTime.fromMillisecondsSinceEpoch(
            row['completed_at']! as int,
          ),
          trigger: SyncTrigger.values.byName(row['trigger']! as String),
          succeeded: row['succeeded'] == 1,
          details: row['details']! as String,
        ),
    ];
  });

  Future<List<ClipboardItem>> listForSync({bool loadImages = true}) =>
      access(() async {
        final rows = await _db.query(
          'clipboard_item',
          columns: _contentColumns,
          orderBy: 'created_at ASC',
        );
        return _items(rows, loadImages: loadImages);
      });

  Future<int> mergeSyncData({
    required List<SyncRecord> records,
    required List<SyncTombstone> tombstones,
    List<SyncDevice> devices = const [],
  }) => access(() async {
    var changes = 0;
    await _db.transaction((txn) async {
      for (final device in devices) {
        await _mergeDevice(txn, device);
      }
      for (final remote in records) {
        if (await _mergeRecord(txn, remote)) changes++;
      }

      for (final tombstone in tombstones) {
        final local = await _findByHash(txn, tombstone.contentHash);
        if (local != null &&
            tombstone.deletedAt < (local['history_changed_at']! as int)) {
          continue;
        }
        if (local != null &&
            local['deleted'] == 1 &&
            local['history_changed_at'] == tombstone.deletedAt) {
          continue;
        }
        if (local == null) {
          await txn.insert('clipboard_item', {
            'id': tombstone.id,
            'type': 'text',
            'content': '',
            'content_hash': tombstone.contentHash,
            'created_at': 0,
            'updated_at': tombstone.deletedAt,
            'last_used_at': 0,
            'deleted': 1,
            'history_changed_at': tombstone.deletedAt,
            'device_id': tombstone.deviceId,
            'sync_state': 'clean',
          });
        } else {
          await txn.update(
            'clipboard_item',
            {
              'deleted': 1,
              'history_changed_at': tombstone.deletedAt,
              'updated_at': max(
                local['updated_at']! as int,
                tombstone.deletedAt,
              ),
            },
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
        changes++;
      }
    });
    return changes;
  });

  Future<void> markAllSynced() => access(() async {
    await _db.update('clipboard_item', {
      'sync_state': 'clean',
    }, where: "sync_state != 'clean'");
  });

  Future<Map<String, Object?>?> _findByHash(
    DatabaseExecutor db,
    String hash,
  ) async {
    final rows = await db.query(
      'clipboard_item',
      columns: _contentColumns,
      where: 'content_hash = ?',
      whereArgs: [hash],
      limit: 1,
    );
    return rows.isEmpty ? null : _restoreText(rows.single);
  }

  Future<bool> _mergeRecord(DatabaseExecutor db, SyncRecord remote) async {
    final local = await _findByHash(db, remote.contentHash);
    final priorHistory = local?['history_changed_at'] as int? ?? 0;
    final priorFavorite = local?['favorite_changed_at'] as int? ?? 0;
    final priorDeleted = local?['deleted'] == 1;
    final priorStar = local?['favorite'] == 1;
    final historyTime =
        remote.historyChangedAt ??
        (remote.deleted ? remote.updatedAt : remote.lastUsedAt);
    final favoriteTime = remote.favoriteChangedAt ?? (remote.favorite ? 1 : 0);
    final takeHistory =
        historyTime > priorHistory ||
        (historyTime == priorHistory && remote.deleted);
    // Old snapshots cannot distinguish copying from canceling a favorite.
    // An explicit v2 state always takes precedence over an ambiguous v1 flag.
    final takeFavorite =
        favoriteTime > priorFavorite ||
        (favoriteTime == priorFavorite && favoriteTime > 0 && !remote.favorite);
    final deleted = takeHistory || local == null
        ? remote.deleted
        : priorDeleted;
    final favorite = takeFavorite || local == null
        ? remote.favorite
        : priorStar;
    final priorUpdated = local?['updated_at'] as int? ?? 0;
    final remoteNewer = local == null || remote.updatedAt > priorUpdated;
    final created = local?['created_at'] as int? ?? 0;
    final images = _database.images;
    final localContent = local?['content'] as String? ?? '';
    final localImage = images?.fileFor(
      local?['type'] as String? ?? 'text',
      localContent,
    );
    final needsPayload =
        remote.content.isNotEmpty || remote.payloadPath != null;
    var content = localContent;
    if (needsPayload &&
        (content.isEmpty ||
            (localImage != null && !await localImage.exists()))) {
      final source = remote.payloadPath;
      if (source != null &&
          remote.type.startsWith('image/') &&
          images != null) {
        content = await images.persistFile(
          File(source),
          remote.type,
          remote.contentHash,
        );
      } else {
        final isImage = remote.type.startsWith('image/');
        final payload = ClipboardContent(
          type: remote.type,
          content: source == null
              ? remote.content
              : isImage
              ? base64Encode(await File(source).readAsBytes())
              : await _readOriginalText(File(source)),
        );
        content =
            await images?.persist(payload, hash: remote.contentHash) ??
            payload.content;
      }
    }
    final values = <String, Object?>{
      'type': needsPayload || local == null ? remote.type : local['type'],
      'content': content,
      'created_at': created == 0
          ? remote.createdAt
          : remote.createdAt == 0
          ? created
          : min(created, remote.createdAt),
      'updated_at': max(priorUpdated, remote.updatedAt),
      'last_used_at': max(
        local?['last_used_at'] as int? ?? 0,
        remote.lastUsedAt,
      ),
      'copy_count': max(local?['copy_count'] as int? ?? 0, remote.copyCount),
      'favorite': favorite ? 1 : 0,
      'deleted': deleted ? 1 : 0,
      'history_changed_at': takeHistory || local == null
          ? historyTime
          : priorHistory,
      'favorite_changed_at': takeFavorite || local == null
          ? favoriteTime
          : priorFavorite,
      'device_id': remoteNewer ? remote.deviceId : local['device_id'],
      'source_app': remoteNewer ? remote.sourceApp : local['source_app'],
    };
    if (local == null) {
      await db.insert('clipboard_item', {
        ...values,
        'id': remote.id,
        'content_hash': remote.contentHash,
        'sync_state': 'clean',
      });
    } else {
      values.removeWhere((key, value) => local[key] == value);
      if (values.isEmpty) return false;
      await db.update(
        'clipboard_item',
        values,
        where: 'id = ?',
        whereArgs: [local['id']],
      );
    }
    return true;
  }

  static Future<String> _readOriginalText(File file) async {
    final bytes = await file.readAsBytes();
    final text = utf8.decode(bytes);
    // The UTF-8 decoder drops an initial BOM, which can be clipboard content.
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return '\ufeff$text';
    }
    return text;
  }

  Future<void> _mergeDevice(DatabaseExecutor db, SyncDevice device) async {
    final local = (await db.query(
      'device',
      where: 'id = ?',
      whereArgs: [device.id],
    )).firstOrNull;
    final current = device.id == _deviceId;
    final newest =
        local == null || device.lastSeenAt >= (local['last_seen_at']! as int);
    await db.insert('device', {
      'id': device.id,
      'name': newest ? device.name : local['name'],
      'platform': newest ? device.platform : local['platform'],
      'created_at': local?['created_at'] ?? device.lastSeenAt,
      'last_seen_at': max(
        device.lastSeenAt,
        local?['last_seen_at'] as int? ?? 0,
      ),
      'machine_id': current
          ? machineId ?? validMachineId(local?['machine_id'] as String?)
          : validMachineId(device.machineId) ??
                validMachineId(local?['machine_id'] as String?),
      'is_current': current ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<DeviceInfo>> listDevices() => access(() async {
    final rows = await _db.query(
      'device',
      orderBy: 'last_seen_at DESC, id ASC',
    );
    final groups = <String, DeviceInfo>{};
    for (final row in rows) {
      final id = row['id']! as String;
      final machine = validMachineId(row['machine_id'] as String?);
      final key = machine == null ? 'installation:$id' : 'machine:$machine';
      final prior = groups[key];
      final isCurrent = id == _deviceId;
      groups[key] = DeviceInfo(
        id: prior?.id ?? id,
        name: prior?.name ?? row['name']! as String,
        platform: prior?.platform ?? row['platform']! as String,
        lastSeenAt:
            prior?.lastSeenAt ??
            DateTime.fromMillisecondsSinceEpoch(row['last_seen_at']! as int),
        isCurrent: isCurrent || (prior?.isCurrent ?? false),
        machineId: machine,
      );
    }
    return [
      ...groups.values.where((entry) => entry.isCurrent),
      ...groups.values.where((entry) => !entry.isCurrent),
    ];
  });

  Future<List<SyncDevice>> listSyncDevices() => access(() async {
    final rows = await _db.query('device');
    return rows.map(SyncDevice.fromJson).toList();
  });
}
