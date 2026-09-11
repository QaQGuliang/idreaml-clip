import 'dart:convert';

import 'clipboard_item.dart';

enum SyncProvider { gitee, github, gitlab, custom }

enum CloudSyncStatus { idle, syncing, success, error }

class SyncConfig {
  const SyncConfig({
    required this.provider,
    required this.remoteUrl,
    required this.username,
    this.branch = 'main',
    this.enabled = true,
    this.syncOnStartup = true,
    this.intervalMinutes = 10,
  });

  final SyncProvider provider;
  final String remoteUrl;
  final String username;
  final String branch;
  final bool enabled;
  final bool syncOnStartup;
  final int intervalMinutes;

  SyncConfig copyWith({
    SyncProvider? provider,
    String? remoteUrl,
    String? username,
    String? branch,
    bool? enabled,
    bool? syncOnStartup,
    int? intervalMinutes,
  }) => SyncConfig(
    provider: provider ?? this.provider,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    username: username ?? this.username,
    branch: branch ?? this.branch,
    enabled: enabled ?? this.enabled,
    syncOnStartup: syncOnStartup ?? this.syncOnStartup,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
  );

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'remote_url': remoteUrl,
    'username': username,
    'branch': branch,
    'enabled': enabled,
    'sync_on_startup': syncOnStartup,
    'interval_minutes': intervalMinutes,
  };

  String encode() => jsonEncode(toJson());

  factory SyncConfig.decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    return SyncConfig(
      provider: SyncProvider.values.firstWhere(
        (item) => item.name == json['provider'],
        orElse: () => SyncProvider.custom,
      ),
      remoteUrl: json['remote_url'] as String? ?? '',
      username: json['username'] as String? ?? '',
      branch: json['branch'] as String? ?? 'main',
      enabled: json['enabled'] as bool? ?? true,
      syncOnStartup: json['sync_on_startup'] as bool? ?? true,
      intervalMinutes: json['interval_minutes'] as int? ?? 10,
    );
  }
}

class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.type,
    required this.content,
    required this.contentHash,
    required this.createdAt,
    required this.updatedAt,
    required this.lastUsedAt,
    required this.copyCount,
    required this.favorite,
    required this.deleted,
    required this.deviceId,
    this.sourceApp,
  });

  final String id;
  final String type;
  final String content;
  final String contentHash;
  final int createdAt;
  final int updatedAt;
  final int lastUsedAt;
  final int copyCount;
  final bool favorite;
  final bool deleted;
  final String deviceId;
  final String? sourceApp;

  factory SyncRecord.fromItem(ClipboardItem item) => SyncRecord(
    id: item.id,
    type: item.type,
    content: item.content,
    contentHash: item.contentHash,
    createdAt: item.createdAt.millisecondsSinceEpoch,
    updatedAt: item.updatedAt.millisecondsSinceEpoch,
    lastUsedAt: item.lastUsedAt.millisecondsSinceEpoch,
    copyCount: item.copyCount,
    favorite: item.favorite,
    deleted: item.deleted,
    deviceId: item.deviceId,
    sourceApp: item.sourceApp,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'type': type,
    'content': content,
    'content_hash': contentHash,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'last_used_at': lastUsedAt,
    'copy_count': copyCount,
    'favorite': favorite,
    'deleted': deleted,
    'device_id': deviceId,
    if (sourceApp != null) 'source_app': sourceApp,
  };

  factory SyncRecord.fromJson(Map<String, dynamic> json) => SyncRecord(
    id: json['id'] as String,
    type: json['type'] as String? ?? 'text',
    content: json['content'] as String,
    contentHash: json['content_hash'] as String,
    createdAt: json['created_at'] as int,
    updatedAt: json['updated_at'] as int,
    lastUsedAt: json['last_used_at'] as int,
    copyCount: json['copy_count'] as int? ?? 1,
    favorite: json['favorite'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
    deviceId: json['device_id'] as String,
    sourceApp: json['source_app'] as String?,
  );
}

class SyncTombstone {
  const SyncTombstone({
    required this.id,
    required this.contentHash,
    required this.deletedAt,
    required this.deviceId,
  });

  final String id;
  final String contentHash;
  final int deletedAt;
  final String deviceId;

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'id': id,
    'content_hash': contentHash,
    'deleted_at': deletedAt,
    'device_id': deviceId,
  };

  factory SyncTombstone.fromJson(Map<String, dynamic> json) => SyncTombstone(
    id: json['id'] as String,
    contentHash: json['content_hash'] as String,
    deletedAt: json['deleted_at'] as int,
    deviceId: json['device_id'] as String,
  );
}

class SyncResult {
  const SyncResult({required this.imported, required this.exported});
  final int imported;
  final int exported;
}

class SyncDevice {
  const SyncDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String platform;
  final int lastSeenAt;

  factory SyncDevice.fromJson(Map<String, dynamic> json) => SyncDevice(
    id: json['id'] as String,
    name: json['name'] as String? ?? '未知设备',
    platform: json['platform'] as String? ?? 'unknown',
    lastSeenAt: json['last_seen_at'] as int? ?? 0,
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.lastSeenAt,
    required this.isCurrent,
  });

  final String id;
  final String name;
  final String platform;
  final DateTime lastSeenAt;
  final bool isCurrent;
}
