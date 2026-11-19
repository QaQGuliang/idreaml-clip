import 'dart:convert';

import 'clipboard_item.dart';

enum SyncProvider { gitee, github, gitlab, custom }

enum CloudSyncStatus { idle, syncing, success, error }

enum SyncTrigger {
  manual('手动同步'),
  startup('启动同步'),
  scheduled('定时同步');

  const SyncTrigger(this.label);
  final String label;
}

enum SyncPhase {
  credentials('读取连接凭证'),
  fetch('拉取远端数据'),
  reconcile('合并和生成同步数据'),
  push('上传到远端'),
  finalize('更新本机同步状态');

  const SyncPhase(this.label);
  final String label;
}

class SyncFailure extends StateError {
  SyncFailure(this.phase, super.message);

  final SyncPhase phase;
  String get description => '${phase.label}失败 · $message';
}

class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.completedAt,
    required this.trigger,
    required this.succeeded,
    required this.details,
  });

  final DateTime completedAt;
  final SyncTrigger trigger;
  final bool succeeded;
  final String details;
}

class SyncConfig {
  const SyncConfig({
    required this.provider,
    required this.remoteUrl,
    required this.username,
    this.branch = 'main',
    this.enabled = true,
    this.syncOnStartup = true,
    this.intervalMinutes = 10,
    this.credentialId,
    this.certificateExceptionUrl,
  });

  final SyncProvider provider;
  final String remoteUrl;
  final String username;
  final String branch;
  final bool enabled;
  final bool syncOnStartup;
  final int intervalMinutes;
  final String? credentialId;
  final String? certificateExceptionUrl;

  bool get skipCertificateVerification {
    if (provider != SyncProvider.custom ||
        certificateExceptionUrl != remoteUrl) {
      return false;
    }
    final url = Uri.tryParse(remoteUrl);
    return url != null && url.scheme == 'https' && url.host.isNotEmpty;
  }

  bool sameAccountAs(SyncConfig? other) =>
      provider == other?.provider &&
      remoteUrl == other?.remoteUrl &&
      username == other?.username;

  SyncConfig copyWith({
    SyncProvider? provider,
    String? remoteUrl,
    String? username,
    String? branch,
    bool? enabled,
    bool? syncOnStartup,
    int? intervalMinutes,
    String? credentialId,
  }) => SyncConfig(
    provider: provider ?? this.provider,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    username: username ?? this.username,
    branch: branch ?? this.branch,
    enabled: enabled ?? this.enabled,
    syncOnStartup: syncOnStartup ?? this.syncOnStartup,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    credentialId: credentialId ?? this.credentialId,
    certificateExceptionUrl: certificateExceptionUrl,
  );

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'remote_url': remoteUrl,
    'username': username,
    'branch': branch,
    'enabled': enabled,
    'sync_on_startup': syncOnStartup,
    'interval_minutes': intervalMinutes,
    if (credentialId != null) 'credential_id': credentialId,
    if (skipCertificateVerification) 'certificate_exception_url': remoteUrl,
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
      credentialId: json['credential_id'] as String?,
      certificateExceptionUrl: json['certificate_exception_url'] as String?,
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
    this.historyChangedAt,
    this.favoriteChangedAt,
    this.payloadPath,
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
  final int? historyChangedAt;
  final int? favoriteChangedAt;
  final String? payloadPath;

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
    historyChangedAt: item.historyChangedAt,
    favoriteChangedAt: item.favoriteChangedAt,
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
    if (historyChangedAt != null) 'history_changed_at': historyChangedAt,
    if (favoriteChangedAt != null) 'favorite_changed_at': favoriteChangedAt,
    'device_id': deviceId,
    if (sourceApp != null) 'source_app': sourceApp,
  };

  factory SyncRecord.fromJson(
    Map<String, dynamic> json, {
    String? payloadPath,
  }) => SyncRecord(
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
    historyChangedAt: json['history_changed_at'] as int?,
    favoriteChangedAt: json['favorite_changed_at'] as int?,
    payloadPath: payloadPath,
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

enum SyncModuleState {
  participating('参与同步'),
  featureDisabled('功能未开启'),
  syncDisabled('同步已关闭'),
  unavailable('本机不支持');

  const SyncModuleState(this.label);
  final String label;
}

class SyncModuleResult {
  const SyncModuleResult({
    this.state = SyncModuleState.participating,
    this.imported = 0,
    this.exported = 0,
  });
  final SyncModuleState state;
  final int imported;
  final int exported;

  String get description => state == SyncModuleState.participating
      ? '导入 $imported 项，导出快照 $exported 项'
      : imported > 0
      ? '${state.label}，本次已导入 $imported 项'
      : state.label;
}

class SyncResult {
  const SyncResult({
    required this.imported,
    required this.exported,
    this.clipboard,
    this.notes,
    this.todos,
  });
  final int imported;
  final int exported;
  final SyncModuleResult? clipboard;
  final SyncModuleResult? notes;
  final SyncModuleResult? todos;

  String get description {
    final modules = {'剪切板': clipboard, '便签': notes, '待办': todos};
    if (modules.values.every((result) => result == null)) {
      return '导入 $imported 项，导出快照 $exported 项';
    }
    return [
      for (final module in modules.entries)
        if (module.value != null)
          '${module.key} · ${module.value!.description}',
    ].join('\n');
  }
}

class SyncDevice {
  const SyncDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.lastSeenAt,
    this.machineId,
  });

  final String id;
  final String name;
  final String platform;
  final int lastSeenAt;
  final String? machineId;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'last_seen_at': lastSeenAt,
    if (machineId != null) 'machine_id': machineId,
  };

  factory SyncDevice.fromJson(Map<String, dynamic> json) => SyncDevice(
    id: json['id'] as String,
    name: json['name'] as String? ?? '未知设备',
    platform: json['platform'] as String? ?? 'unknown',
    lastSeenAt: json['last_seen_at'] as int? ?? 0,
    machineId: json['machine_id'] as String?,
  );
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.lastSeenAt,
    required this.isCurrent,
    this.machineId,
  });

  final String id;
  final String name;
  final String platform;
  final DateTime lastSeenAt;
  final bool isCurrent;
  final String? machineId;

  String? get shortMachineId {
    final value = machineId;
    if (value == null) return null;
    final short = value.substring(0, 12).toUpperCase();
    return '${short.substring(0, 4)}-${short.substring(4, 8)}-${short.substring(8)}';
  }
}
