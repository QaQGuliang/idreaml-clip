import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/clipboard_repository.dart';
import '../models/sync_models.dart';
import 'credential_service.dart';
import 'embedded_git_service.dart';
import 'sync_format_service.dart';

class SyncService extends ChangeNotifier {
  SyncService(
    this._repository,
    this._credentialStore, {
    EmbeddedGitService? git,
    SyncFormatService? format,
    Future<Directory> Function()? supportDirectory,
  }) : _git = git ?? EmbeddedGitService(),
       _format = format ?? SyncFormatService(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _configKey = 'cloud_sync_config';
  final ClipboardRepository _repository;
  final CredentialStore _credentialStore;
  final EmbeddedGitService _git;
  final SyncFormatService _format;
  final Future<Directory> Function() _supportDirectory;
  Timer? _timer;
  Timer? _startupTimer;
  bool _running = false;

  SyncConfig? config;
  CloudSyncStatus status = CloudSyncStatus.idle;
  DateTime? lastSyncedAt;
  String? lastError;
  Future<void> Function()? onSynced;

  Future<void> initialize() async {
    final saved = await _repository.getSetting(_configKey);
    if (saved != null) {
      try {
        config = SyncConfig.decode(saved);
      } catch (_) {
        config = null;
      }
    }
    _schedule();
    if (config?.enabled == true && config?.syncOnStartup == true) {
      _startupTimer = Timer(
        const Duration(seconds: 5),
        () => unawaited(syncNow()),
      );
    }
    notifyListeners();
  }

  Future<void> saveConfig(SyncConfig value, {String? token}) async {
    _validate(value);
    if (token != null && token.trim().isNotEmpty) {
      await _credentialStore.writeToken(token.trim());
    }
    config = value;
    await _repository.setSetting(_configKey, value.encode());
    _schedule();
    notifyListeners();
  }

  Future<void> disconnect() async {
    _timer?.cancel();
    _startupTimer?.cancel();
    config = null;
    status = CloudSyncStatus.idle;
    lastError = null;
    await _credentialStore.deleteToken();
    await _repository.setSetting(_configKey, 'null');
    notifyListeners();
  }

  Future<SyncResult?> syncNow() async {
    final current = config;
    if (_running || current == null || !current.enabled) return null;
    _running = true;
    status = CloudSyncStatus.syncing;
    lastError = null;
    notifyListeners();
    try {
      final token = await _credentialStore.readToken();
      if (token == null || token.isEmpty) {
        throw StateError('尚未保存访问令牌，请重新编辑连接。');
      }
      final root = await _supportDirectory();
      final repository = Directory(
        p.join(
          root.path,
          'idreaml_clip',
          'sync',
          sha256
              .convert(utf8.encode(current.remoteUrl))
              .toString()
              .substring(0, 16),
        ),
      );
      final result = await _git.synchronize<SyncResult>(
        directory: repository,
        config: current,
        token: token,
        reconcile: () async {
          final imported = await _format.readAll(repository);
          final changed = await _repository.mergeSyncData(
            records: imported.records,
            tombstones: imported.tombstones,
            devices: imported.devices,
          );
          final items = await _repository.listForSync();
          final exported = await _format.exportDevice(
            repository: repository,
            deviceId: _repository.deviceId,
            deviceName: _repository.deviceName,
            items: items,
          );
          return SyncResult(imported: changed, exported: exported);
        },
      );
      await _repository.markAllSynced();
      lastSyncedAt = DateTime.now();
      status = CloudSyncStatus.success;
      await onSynced?.call();
      return result;
    } catch (error) {
      status = CloudSyncStatus.error;
      lastError = _sanitize('$error');
      return null;
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final current = config;
    if (current == null || !current.enabled) return;
    _timer = Timer.periodic(
      Duration(minutes: current.intervalMinutes),
      (_) => unawaited(syncNow()),
    );
  }

  void _validate(SyncConfig value) {
    final uri = Uri.tryParse(value.remoteUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('仓库地址必须是有效的 HTTPS URL。');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('仓库地址中不能包含用户名或令牌。');
    }
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(value.branch) ||
        value.branch.contains('..')) {
      throw const FormatException('分支名称无效。');
    }
    if (!const [5, 10, 30].contains(value.intervalMinutes)) {
      throw const FormatException('同步间隔仅支持 5、10 或 30 分钟。');
    }
  }

  String _sanitize(String message) {
    final current = config;
    var result = message.replaceFirst('Bad state: ', '');
    if (current != null && current.username.isNotEmpty) {
      result = result.replaceAll(current.username, '***');
    }
    return result.length > 220 ? '${result.substring(0, 220)}…' : result;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _startupTimer?.cancel();
    super.dispose();
  }
}
