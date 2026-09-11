import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/clipboard_item.dart';
import '../models/sync_models.dart';

class SyncImportData {
  const SyncImportData({
    required this.records,
    required this.tombstones,
    required this.devices,
  });
  final List<SyncRecord> records;
  final List<SyncTombstone> tombstones;
  final List<SyncDevice> devices;
}

class SyncFormatService {
  static const _maxFileBytes = 10 * 1024 * 1024;

  Future<int> exportDevice({
    required Directory repository,
    required String deviceId,
    required String deviceName,
    required List<ClipboardItem> items,
  }) async {
    await _writeJson(File(p.join(repository.path, 'schema.json')), {
      'name': 'idreaml-clip-sync',
      'schema_version': 1,
      'format': 'jsonl',
    });
    await _writeJson(
      File(p.join(repository.path, 'devices', '$deviceId.json')),
      {
        'schema_version': 1,
        'id': deviceId,
        'name': deviceName,
        'platform': Platform.operatingSystem,
        'last_seen_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
    );

    final recordDirectory = Directory(
      p.join(repository.path, 'records', deviceId),
    );
    await recordDirectory.create(recursive: true);
    final groups = <String, List<SyncRecord>>{};
    for (final item in items.where((item) => !item.deleted)) {
      final date = item.createdAt.toUtc();
      final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(month, () => []).add(SyncRecord.fromItem(item));
    }
    for (final old in recordDirectory.listSync().whereType<File>()) {
      if (p.extension(old.path) == '.jsonl' &&
          !groups.containsKey(p.basenameWithoutExtension(old.path))) {
        await old.delete();
      }
    }
    for (final entry in groups.entries) {
      entry.value.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      await _writeJsonLines(
        File(p.join(recordDirectory.path, '${entry.key}.jsonl')),
        entry.value.map((item) => item.toJson()),
      );
    }

    final tombstones = items
        .where((item) => item.deleted)
        .map(
          (item) => SyncTombstone(
            id: item.id,
            contentHash: item.contentHash,
            deletedAt: item.updatedAt.millisecondsSinceEpoch,
            deviceId: deviceId,
          ).toJson(),
        );
    await _writeJsonLines(
      File(p.join(repository.path, 'tombstones', deviceId, 'events.jsonl')),
      tombstones,
    );
    return items.length;
  }

  Future<SyncImportData> readAll(Directory repository) async {
    final records = <SyncRecord>[];
    final tombstones = <SyncTombstone>[];
    final devices = <SyncDevice>[];
    final recordsRoot = Directory(p.join(repository.path, 'records'));
    final tombstonesRoot = Directory(p.join(repository.path, 'tombstones'));
    final devicesRoot = Directory(p.join(repository.path, 'devices'));
    if (recordsRoot.existsSync()) {
      for (final file
          in recordsRoot.listSync(recursive: true).whereType<File>()) {
        if (p.extension(file.path) != '.jsonl') continue;
        for (final json in await _readJsonLines(file)) {
          records.add(SyncRecord.fromJson(json));
        }
      }
    }
    if (tombstonesRoot.existsSync()) {
      for (final file
          in tombstonesRoot.listSync(recursive: true).whereType<File>()) {
        if (p.extension(file.path) != '.jsonl') continue;
        for (final json in await _readJsonLines(file)) {
          tombstones.add(SyncTombstone.fromJson(json));
        }
      }
    }
    if (devicesRoot.existsSync()) {
      for (final file in devicesRoot.listSync().whereType<File>()) {
        if (p.extension(file.path) != '.json' ||
            await file.length() > _maxFileBytes) {
          continue;
        }
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic>) {
          devices.add(SyncDevice.fromJson(value));
        }
      }
    }
    return SyncImportData(
      records: records,
      tombstones: tombstones,
      devices: devices,
    );
  }

  Future<List<Map<String, dynamic>>> _readJsonLines(File file) async {
    if (await file.length() > _maxFileBytes) {
      throw const FormatException('同步文件超过 10 MB 安全限制');
    }
    final result = <Map<String, dynamic>>[];
    final lines = file
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('同步记录必须是 JSON 对象');
      }
      result.add(value);
    }
    return result;
  }

  Future<void> _writeJson(File file, Map<String, Object?> value) => _writeText(
    file,
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );

  Future<void> _writeJsonLines(
    File file,
    Iterable<Map<String, Object?>> values,
  ) => _writeText(file, '${values.map(jsonEncode).join('\n')}\n');

  Future<void> _writeText(File file, String value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    if (file.existsSync()) await file.delete();
    await temporary.rename(file.path);
  }
}
