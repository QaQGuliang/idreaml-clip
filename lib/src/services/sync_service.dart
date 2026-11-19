import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/clipboard_repository.dart';
import '../models/sync_models.dart';
import 'async_gate.dart';
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
    DateTime Function()? now,
  }) : _git = git ?? EmbeddedGitService(),
       _format = format ?? SyncFormatService(),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _now = now ?? DateTime.now;

  static const _configKey = 'cloud_sync_config';
  static const _historyRetention = Duration(days: 7);
  final ClipboardRepository _repository;
  final CredentialStore _credentialStore;
  final EmbeddedGitService _git;
  final SyncFormatService _format;
  final Future<Directory> Function() _supportDirectory;
  final DateTime Function() _now;
  final _historyGate = AsyncGate();
  final _configGate = AsyncGate();
  Timer? _timer;
  Timer? _startupTimer;
  Timer? _historyExpiryTimer;
  bool _running = false;
  bool _changingConnection = false;
  bool _disposed = false;
  bool _historyUnavailable = false;
  List<SyncHistoryEntry> _history = const [];

  List<SyncHistoryEntry> get history => _history;
  bool get historyUnavailable => _historyUnavailable;

  SyncConfig? config;
  CloudSyncStatus status = CloudSyncStatus.idle;
  DateTime? lastSyncedAt;
  SyncResult? lastResult;
  String? lastError;
  Future<void> Function()? onSynced;
  Future<SyncResult> Function(Directory)? syncDesktopNotes;
  Future<int> Function(Directory)? importDesktopNotes;

  Future<void> initialize() async {
    final saved = await _repository.getSetting(_configKey);
    if (saved != null) {
      try {
        config = SyncConfig.decode(saved);
      } catch (_) {
        config = null;
      }
    }
    await _updateHistory();
    if (_disposed) return;
    _schedule();
    if (config?.enabled == true && config?.syncOnStartup == true) {
      _startupTimer = Timer(
        const Duration(seconds: 5),
        () => unawaited(syncNow(trigger: SyncTrigger.startup)),
      );
    }
    notifyListeners();
  }

  Future<void> saveConfig(SyncConfig value, {String? token}) =>
      _changeConnection(() async {
        _validate(value);
        final previous = config;
        final credentialLabel = value.provider == SyncProvider.custom
            ? '密码或访问令牌'
            : '访问令牌';
        final secret = value.provider == SyncProvider.custom
            ? token ?? ''
            : token?.trim() ?? '';
        final replacingCredential = secret.isNotEmpty;
        if (!replacingCredential && !value.sameAccountAs(previous)) {
          throw FormatException('首次连接或更换仓库、账号时，请填写$credentialLabel。');
        }
        final credentialId = replacingCredential
            ? const Uuid().v4()
            : previous?.credentialId;
        final next = value.copyWith(credentialId: credentialId);
        try {
          if (replacingCredential) {
            await _credentialStore.writeToken(secret, id: credentialId);
          }
          await _repository.setSetting(_configKey, next.encode());
        } catch (_) {
          if (replacingCredential) {
            await _removeObsoleteCredential(credentialId);
          }
          rethrow;
        }
        if (!next.sameAccountAs(previous) ||
            previous?.branch != next.branch ||
            previous?.skipCertificateVerification !=
                next.skipCertificateVerification) {
          lastResult = null;
          lastSyncedAt = null;
          lastError = null;
          status = CloudSyncStatus.idle;
        }
        config = next;
        if (replacingCredential && previous != null) {
          await _removeObsoleteCredential(previous.credentialId);
        }
        _schedule();
        notifyListeners();
      });

  Future<void> disconnect() => _changeConnection(() async {
    final previous = config;
    await _repository.setSetting(_configKey, 'null');
    _timer?.cancel();
    _startupTimer?.cancel();
    config = null;
    status = CloudSyncStatus.idle;
    lastError = null;
    lastResult = null;
    lastSyncedAt = null;
    try {
      if (previous != null) {
        await _credentialStore.deleteToken(id: previous.credentialId);
      }
    } finally {
      notifyListeners();
    }
  });

  Future<void> _changeConnection(Future<void> Function() action) =>
      _repository.access(
        () => _configGate.run(() async {
          _changingConnection = true;
          try {
            await action();
          } finally {
            _changingConnection = false;
          }
        }),
      );

  Future<void> _removeObsoleteCredential(String? id) async {
    try {
      await _credentialStore.deleteToken(id: id);
    } catch (_) {
      // Only the credential referenced by the saved configuration is used.
    }
  }

  /// Import from the configured source before replacing it with a new
  /// repository. This path only fetches and does not mark local work uploaded.
  Future<int> importRepository({Directory? checkout}) =>
      _repository.access(() async {
        if (_disposed || _running || _changingConnection) {
          throw StateError('同步正在进行，请稍后再导入。');
        }
        final current = config;
        if (checkout == null && current == null) {
          throw StateError('请先配置旧仓库，或选择已下载的仓库目录。');
        }
        _running = true;
        status = CloudSyncStatus.syncing;
        lastError = null;
        notifyListeners();
        try {
          final Directory source;
          if (checkout != null) {
            source = checkout;
          } else {
            final token = await _configGate.run(
              () => _credentialStore.readToken(id: current!.credentialId),
            );
            if (token == null || token.isEmpty) {
              throw SyncFailure(SyncPhase.credentials, '请填写旧仓库的连接凭据。');
            }
            source = await _worktree(current!, suffix: '-migration');
            await _git.fetchOnly(
              directory: source,
              config: current,
              token: token,
            );
          }
          if (!await _format.isLegacy(source)) {
            throw SyncFailure(SyncPhase.reconcile, '未找到旧版 Idreaml Clip 同步文件。');
          }
          var count = 0;
          await for (final data in _format.readLegacy(source)) {
            count += await _repository.mergeSyncData(
              records: data.records,
              tombstones: data.tombstones,
              devices: data.devices,
            );
          }
          count += await importDesktopNotes?.call(source) ?? 0;
          status = CloudSyncStatus.idle;
          await onSynced?.call();
          return count;
        } catch (error) {
          status = CloudSyncStatus.error;
          lastError = error is SyncFailure
              ? error.description
              : '无法读取旧仓库中的同步文件，请检查目录和文件格式。';
          throw StateError(lastError!);
        } finally {
          _running = false;
          if (!_disposed) notifyListeners();
        }
      });

  Future<Directory> _worktree(SyncConfig current, {String suffix = ''}) async {
    final root =
        _repository.storage?.sync ??
        Directory(
          p.join((await _supportDirectory()).path, 'idreaml_clip', 'sync'),
        );
    final key = sha256
        .convert(utf8.encode('${current.remoteUrl}\n${current.branch}'))
        .toString()
        .substring(0, 16);
    return Directory(
      p.join(root.path, '$key${suffix.isEmpty ? '-v2' : suffix}'),
    );
  }

  Future<SyncResult?> syncNow({
    SyncTrigger trigger = SyncTrigger.manual,
  }) => _repository.access(() async {
    final current = config;
    if (_disposed ||
        _running ||
        _changingConnection ||
        current == null ||
        !current.enabled) {
      return null;
    }
    _running = true;
    status = CloudSyncStatus.syncing;
    lastError = null;
    notifyListeners();
    var phase = SyncPhase.credentials;
    SyncResult? completed;
    String? failure;
    try {
      final token = await _configGate.run(
        () => _credentialStore.readToken(id: current.credentialId),
      );
      if (token == null || token.isEmpty) {
        throw SyncFailure(phase, '尚未保存连接凭据，请重新编辑连接。');
      }
      phase = SyncPhase.reconcile;
      final repository = await _worktree(current);
      // A push retry reconciles again after earlier imports are already saved.
      var clipboardImported = 0;
      var desktopImported = 0;
      var notesImported = 0;
      var todosImported = 0;
      final result = await _git.synchronize<SyncResult>(
        directory: repository,
        config: current,
        token: token,
        reconcile: () async {
          if (await _format.isLegacy(repository)) {
            throw SyncFailure(
              SyncPhase.reconcile,
              '这是旧版同步仓库。请先从“导入旧仓库”合并数据，再连接新的私有仓库。',
            );
          }
          final imported = await _format.readAll(repository);
          final changed = await _repository.mergeSyncData(
            records: imported.records,
            tombstones: imported.tombstones,
            devices: imported.devices,
          );
          clipboardImported += changed;
          final items = await _repository.listForSync(loadImages: false);
          final exported = await _format.exportDevice(
            repository: repository,
            deviceId: _repository.deviceId,
            deviceName: _repository.deviceName,
            machineId: _repository.machineId,
            devices: await _repository.listSyncDevices(),
            items: items,
          );
          final desktopChanges = await syncDesktopNotes?.call(repository);
          desktopImported += desktopChanges?.imported ?? 0;
          notesImported += desktopChanges?.notes?.imported ?? 0;
          todosImported += desktopChanges?.todos?.imported ?? 0;
          return SyncResult(
            imported: clipboardImported + desktopImported,
            exported: exported + (desktopChanges?.exported ?? 0),
            clipboard: SyncModuleResult(
              imported: clipboardImported,
              exported: exported,
            ),
            notes: SyncModuleResult(
              state:
                  desktopChanges?.notes?.state ?? SyncModuleState.unavailable,
              imported: notesImported,
              exported: desktopChanges?.notes?.exported ?? 0,
            ),
            todos: SyncModuleResult(
              state:
                  desktopChanges?.todos?.state ?? SyncModuleState.unavailable,
              imported: todosImported,
              exported: desktopChanges?.todos?.exported ?? 0,
            ),
          );
        },
      );
      phase = SyncPhase.finalize;
      await _repository.markAllSynced();
      await onSynced?.call();
      completed = result;
      return result;
    } catch (error) {
      failure = error is SyncFailure
          ? error.description
          : SyncFailure(phase, switch (phase) {
              SyncPhase.credentials => '无法读取已保存的连接凭据，请重新编辑连接。',
              SyncPhase.finalize => '远端上传已完成，请重新打开应用检查本机同步状态。',
              _ => '请检查本机数据目录和网络连接后重试。',
            }).description;
      return null;
    } finally {
      final finishedAt = _now();
      await _updateHistory(
        SyncHistoryEntry(
          completedAt: finishedAt,
          trigger: trigger,
          succeeded: completed != null,
          details: completed?.description ?? failure!,
        ),
      );
      final active = config;
      if (current.sameAccountAs(active) &&
          active?.branch == current.branch &&
          active?.skipCertificateVerification ==
              current.skipCertificateVerification) {
        status = completed == null
            ? CloudSyncStatus.error
            : CloudSyncStatus.success;
        lastError = failure;
        if (completed != null) {
          lastSyncedAt = finishedAt;
          lastResult = completed;
        }
      }
      _running = false;
      if (!_disposed) notifyListeners();
    }
  });

  Future<void> _updateHistory([SyncHistoryEntry? entry]) => _repository.access(
    () => _historyGate.run(() async {
      try {
        final now = _now();
        _history = List.unmodifiable(
          await _repository.updateSyncHistory(
            cutoff: now.subtract(_historyRetention),
            entry: entry,
          ),
        );
        _historyUnavailable = false;
      } catch (_) {
        // The log is independent of a completed transfer's result.
        _historyUnavailable = true;
        final cutoff = _now().subtract(_historyRetention);
        _history = List.unmodifiable([
          ?entry,
          ..._history.where((record) => record.completedAt.isAfter(cutoff)),
        ]);
      }
      _historyExpiryTimer?.cancel();
      if (!_disposed && _history.isNotEmpty) {
        final expiry = _history.last.completedAt.add(_historyRetention);
        _historyExpiryTimer = Timer(expiry.difference(_now()), () async {
          await _updateHistory();
          if (!_disposed) notifyListeners();
        });
      }
    }),
  );

  void _schedule() {
    _timer?.cancel();
    final current = config;
    if (current == null || !current.enabled) return;
    _timer = Timer.periodic(
      Duration(minutes: current.intervalMinutes),
      (_) => unawaited(syncNow(trigger: SyncTrigger.scheduled)),
    );
  }

  void _validate(SyncConfig value) {
    final uri = Uri.tryParse(value.remoteUrl);
    final isSelfHosted = value.provider == SyncProvider.custom;
    final allowedSchemes = isSelfHosted
        ? const ['http', 'https']
        : const ['https'];
    if (uri == null ||
        !allowedSchemes.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw FormatException(
        isSelfHosted ? '请填写有效的 HTTP 或 HTTPS 克隆地址。' : '请填写有效的 HTTPS 克隆地址。',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException('请在单独的字段填写用户名和凭据。');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const FormatException('请填写不带查询参数或片段的克隆地址。');
    }
    if (isSelfHosted && value.username.trim().isEmpty) {
      throw const FormatException('请填写自托管仓库的 Git 用户名。');
    }
    if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(value.branch) ||
        value.branch.contains('..')) {
      throw const FormatException('分支名称无效。');
    }
    if (!const [5, 10, 30].contains(value.intervalMinutes)) {
      throw const FormatException('同步间隔仅支持 5、10 或 30 分钟。');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _startupTimer?.cancel();
    _historyExpiryTimer?.cancel();
    super.dispose();
  }
}
