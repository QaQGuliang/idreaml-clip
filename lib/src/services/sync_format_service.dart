import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../models/clipboard_item.dart';
import '../models/sync_models.dart';
import 'sync_archive.dart';

class SyncImportData {
  const SyncImportData({
    this.records = const [],
    this.tombstones = const [],
    this.devices = const [],
  });
  final List<SyncRecord> records;
  final List<SyncTombstone> tombstones;
  final List<SyncDevice> devices;
}

class SyncFormatService {
  SyncFormatService({this.maxFileBytes = 64 * 1024 * 1024});

  final int maxFileBytes;
  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _devicePattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  static String _extension(String type) => switch (type) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    'image/bmp' => 'bmp',
    _ => type.startsWith('image/') ? 'bin' : 'txt',
  };

  static String _historyPath(String hash, int createdAt, String extension) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      createdAt,
      isUtc: true,
    ).add(const Duration(hours: 8));
    String pad(int value) => value.toString().padLeft(2, '0');
    final day = '${date.year}-${pad(date.month)}-${pad(date.day)}';
    final time = '${pad(date.hour)}${pad(date.minute)}${pad(date.second)}';
    return 'history/$day/$time-$hash.$extension';
  }

  static String _metadata(String hash) =>
      'config/metadata/clipboard/$hash.json';

  Future<bool> isLegacy(Directory repository) async {
    final archive = SyncArchive(repository);
    if (await (await archive.file('config/format.json')).exists()) return false;
    for (final directory in [
      'records',
      'tombstones',
      'desktop-v1',
      'devices',
    ]) {
      if (await Directory((await archive.file(directory)).path).exists()) {
        return true;
      }
    }
    return await (await archive.file('schema.json')).exists();
  }

  Future<int> exportDevice({
    required Directory repository,
    required String deviceId,
    required String deviceName,
    required List<ClipboardItem> items,
    List<SyncDevice> devices = const [],
    String? machineId,
  }) => Isolate.run(() async {
    final archive = SyncArchive(repository);
    await _checkFormat(archive);
    const attributes =
        '/history/** -text\n/favorites/** -text\n/notes/** -text\n/todos/** -text\n';
    final attributesFile = await archive.file('.gitattributes');
    final existingAttributes = await attributesFile.exists()
        ? await attributesFile.readAsString()
        : '';
    if (!existingAttributes.endsWith(attributes)) {
      await archive.writeText(
        '.gitattributes',
        existingAttributes.isEmpty
            ? attributes
            : '${existingAttributes.trimRight()}\n$attributes',
      );
    }
    await archive.writeJson('config/format.json', {
      'name': 'idreaml-clip-sync',
      'schema_version': SyncArchive.version,
      'history_time_zone': 'Asia/Shanghai',
    });
    final profiles = {
      for (final device in devices) device.id: device,
      deviceId: SyncDevice(
        id: deviceId,
        name: deviceName,
        platform: Platform.operatingSystem,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
        machineId:
            machineId ??
            devices
                .where((device) => device.id == deviceId)
                .firstOrNull
                ?.machineId,
      ),
    };
    for (final profile in profiles.values) {
      if (!_devicePattern.hasMatch(profile.id)) {
        throw const FormatException('同步设备标识无效');
      }
      await archive.writeJson(
        'config/devices/${profile.id}.json',
        profile.toJson(),
      );
    }

    for (final item in items) {
      final hash = item.contentHash;
      if (!_hashPattern.hasMatch(hash)) {
        throw const FormatException('同步内容标识无效');
      }
      final meta = _metadata(hash);
      final metadata = await archive.file(meta);
      final ext = _extension(item.type);
      final history = _historyPath(
        hash,
        item.createdAt.millisecondsSinceEpoch,
        ext,
      );
      final favorite = 'favorites/$hash.$ext';
      if (await metadata.exists()) {
        final previous = await archive.readJson(metadata);
        final oldExt = _extension(previous['type'] as String);
        final oldHistory = _historyPath(
          hash,
          previous['created_at'] as int,
          oldExt,
        );
        if (oldHistory != history || item.deleted) {
          await archive.remove(oldHistory);
        }
        if (oldExt != ext) await archive.remove('favorites/$hash.$oldExt');
      }
      if (item.deleted) await archive.remove(history);
      if (!item.favorite) await archive.remove(favorite);
      if (!item.deleted || item.favorite) {
        final source = item.imagePath == null ? null : File(item.imagePath!);
        if (source != null && !await source.exists()) {
          throw SyncFailure(SyncPhase.reconcile, '无法读取本机图片，请检查数据目录。');
        }
        final bytes = item.isImage && source == null
            ? item.payload.imageBytes
            : null;
        for (final destination in [
          if (!item.deleted) history,
          if (item.favorite) favorite,
        ]) {
          if (source != null) {
            if (await source.length() > maxFileBytes) _tooLarge();
            await archive.copy(destination, source);
          } else if (bytes != null) {
            if (bytes.length > maxFileBytes) _tooLarge();
            await archive.writeBytes(destination, bytes);
          } else {
            final textBytes = utf8.encode(item.content);
            if (textBytes.length > maxFileBytes) _tooLarge();
            await archive.writeBytes(destination, textBytes);
          }
        }
      }
      final record = SyncRecord.fromItem(item).toJson()..remove('content');
      record['id'] = 'clip-$hash';
      record['schema_version'] = SyncArchive.version;
      await archive.writeJson(meta, record);
    }
    return items.length;
  });

  Future<SyncImportData> readAll(Directory repository) => Isolate.run(() async {
    final archive = SyncArchive(repository);
    await _checkFormat(archive);
    final records = <SyncRecord>[];
    final devices = <SyncDevice>[];
    for (final file in await archive.jsonFiles('config/metadata/clipboard')) {
      final json = await archive.readJson(file);
      final hash = json['content_hash'] as String;
      if (!_hashPattern.hasMatch(hash) ||
          p.basename(file.path) != '$hash.json' ||
          json['schema_version'] != SyncArchive.version ||
          json['history_changed_at'] is! int ||
          json['favorite_changed_at'] is! int) {
        throw const FormatException('剪切板同步元数据无效');
      }
      final type = json['type'] as String;
      final extension = _extension(type);
      String? source;
      for (final relative in [
        if (json['deleted'] != true)
          _historyPath(hash, json['created_at'] as int, extension),
        if (json['favorite'] == true) 'favorites/$hash.$extension',
      ]) {
        final payload = await archive.file(relative);
        if (!await payload.exists()) {
          throw const FormatException('仓库中的剪切板内容文件缺失');
        }
        if (await payload.length() > maxFileBytes) _tooLarge();
        final digest = await sha256.bind(_hashInput(payload, type)).single;
        if (digest.toString() != hash) {
          throw const FormatException('仓库中的剪切板内容与元数据不一致');
        }
        source ??= payload.path;
      }
      records.add(
        SyncRecord.fromJson({
          ...json,
          'id': 'clip-$hash',
          'content': '',
        }, payloadPath: source),
      );
    }
    for (final file in await archive.jsonFiles('config/devices')) {
      final json = await archive.readJson(file);
      final device = SyncDevice.fromJson(json);
      if (!_devicePattern.hasMatch(device.id) ||
          p.basename(file.path) != '${device.id}.json') {
        throw const FormatException('同步设备标识无效');
      }
      devices.add(device);
    }
    return SyncImportData(records: records, devices: devices);
  });

  // Match ClipboardContent.hash without keeping a whole image in memory.
  static Stream<List<int>> _hashInput(File file, String type) async* {
    if (type.startsWith('image/')) {
      yield utf8.encode('$type\u0000');
      yield* file.openRead().transform(base64.encoder).transform(utf8.encoder);
    } else {
      yield* file.openRead();
    }
  }

  Stream<SyncImportData> readLegacy(Directory repository) async* {
    final archive = SyncArchive(repository);
    final schema = await archive.file('schema.json');
    if (await schema.exists() &&
        (await archive.readJson(schema))['schema_version'] != 1) {
      throw const FormatException('不支持的旧仓库格式');
    }
    for (final folder in ['records', 'tombstones']) {
      final directory = Directory((await archive.file(folder)).path);
      if (!await directory.exists()) continue;
      await for (final file in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is! File || !file.path.endsWith('.jsonl')) continue;
        if (await file.length() > maxFileBytes) _tooLarge();
        final records = <SyncRecord>[];
        final tombstones = <SyncTombstone>[];
        await for (final line
            in file
                .openRead()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (line.trim().isEmpty) continue;
          final json = jsonDecode(line) as Map<String, dynamic>;
          if (folder == 'records') {
            records.add(SyncRecord.fromJson(json));
          } else {
            tombstones.add(SyncTombstone.fromJson(json));
          }
        }
        yield SyncImportData(records: records, tombstones: tombstones);
      }
    }
    final devices = <SyncDevice>[];
    for (final file in await archive.jsonFiles('devices')) {
      devices.add(SyncDevice.fromJson(await archive.readJson(file)));
    }
    if (devices.isNotEmpty) yield SyncImportData(devices: devices);
  }

  Future<void> _checkFormat(SyncArchive archive) async {
    final format = await archive.file('config/format.json');
    if (!await format.exists()) return;
    final value = await archive.readJson(format);
    if (value['name'] != 'idreaml-clip-sync' ||
        value['schema_version'] != SyncArchive.version ||
        value['history_time_zone'] != 'Asia/Shanghai') {
      throw SyncFailure(SyncPhase.reconcile, '仓库同步格式不受当前版本支持。');
    }
  }

  static Never _tooLarge() =>
      throw SyncFailure(SyncPhase.reconcile, '同步内容文件超过大小限制。');
}
